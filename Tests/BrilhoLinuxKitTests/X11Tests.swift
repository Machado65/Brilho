// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore
@testable import BrilhoLinuxKit
import Foundation
import Testing

/// Against a real X server (Xvfb in CI): only where there's a DISPLAY and the X11 tools.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DISPLAY"] != nil && FileManager.default.fileExists(atPath: "/usr/bin/xprop")))
struct X11 {
    func run(_ program: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func theAppInFrontAndTheIdleTime() throws {
        let session = try #require(X11Session())
        // A window of a known class, made the active one as a window manager would
        let message = Process()
        message.executableURL = URL(fileURLWithPath: "/usr/bin/xmessage")
        message.arguments = ["-name", "brilho-test", "Brilho"]
        message.standardOutput = FileHandle.nullDevice
        message.standardError = FileHandle.nullDevice
        try message.run()
        defer { message.terminate() }
        var window = ""
        for _ in 0..<50 where window.isEmpty {
            usleep(100_000)
            window = run("/usr/bin/xwininfo", ["-name", "brilho-test"]).components(separatedBy: "\n")
                .first { $0.contains("Window id:") }?.components(separatedBy: " ").first { $0.hasPrefix("0x") } ?? ""
        }
        try #require(!window.isEmpty)
        _ = run("/usr/bin/xprop", ["-root", "-f", "_NET_ACTIVE_WINDOW", "32x", "-set", "_NET_ACTIVE_WINDOW", window])
        #expect(session.activeApp() == "Xmessage")
        #expect(session.idleTime().map { $0 >= 0 } ?? true)
    }

    @Test func theWhiteIsWarmedAndPutBack() throws {
        let session = try #require(X11Session())
        guard session.canSetWhite, let before = session.currentRamps() else { return } // a server without gamma ramps
        session.setWhite(3500)
        session.setWhite(3500) // again: from what was there before, not from what Brilho set
        let warm = try #require(session.currentRamps())
        let middle = warm[0].count / 2
        #expect(warm[2][middle] < warm[1][middle] && warm[1][middle] < warm[0][middle]) // less blue than green than red
        #expect(warm[0].last == 65535) // red full: scaled once, not twice
        func summary(_ ramps: [[UInt16]]?) -> String {
            (ramps ?? []).map { "\($0.count): \(Array($0.prefix(3))) ... \($0.last ?? 0)" }.joined(separator: " | ")
        }
        print("ramps before \(summary(before)); warm \(summary(warm))")
        session.reset()
        print("ramps after reset \(summary(session.currentRamps()))")
        // As they were; a server that had none (zeros, as Xvfb's) gets linear ones
        let linear = before.map { ramp in ramp.indices.map { UInt16(Double($0) / Double(ramp.count - 1) * 65535) } }
        #expect(session.currentRamps() == (before.allSatisfy { ($0.max() ?? 0) > 1000 } ? before : linear))
    }
}
