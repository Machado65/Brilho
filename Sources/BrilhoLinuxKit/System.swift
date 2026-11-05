// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Where the devices are: / normally, a made-up tree in the tests.
public struct Paths: Sendable {
    public var sys: String
    public var dev: String

    public init(sys: String = "/sys", dev: String = "/dev") {
        self.sys = sys
        self.dev = dev
    }

    /// From BRILHO_SYS and BRILHO_DEV when set, for trying Brilho on a made-up machine.
    public static var current: Paths {
        let environment = ProcessInfo.processInfo.environment
        return Paths(sys: environment["BRILHO_SYS"] ?? "/sys", dev: environment["BRILHO_DEV"] ?? "/dev")
    }
}

/// Reading and writing sysfs's small files.
enum File {
    static func text(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func number(_ path: String) -> Double? { text(path).flatMap { Double($0) } }
    static func bytes(_ path: String) -> [UInt8]? { FileManager.default.contents(atPath: path).map { Array($0) } }
    static func list(_ path: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted() }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    static func link(_ path: String) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: path) }
    static func accessible(_ path: String, _ mode: Int32) -> Bool { access(path, mode) == 0 }

    /// In place, as sysfs wants (no temporary file and rename), opened as the
    /// shell's `echo 5 > brightness` does.
    @discardableResult static func write(_ text: String, to path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_TRUNC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { posixWrite(fd, $0.baseAddress, $0.count) } == bytes.count
    }
}

/// Other programs Brilho asks things of (busctl, gsettings): run by name from the
/// PATH, given two seconds, their output returned; nil if they failed.
public struct Runner: Sendable {
    public var run: @Sendable (_ program: String, _ arguments: [String]) -> String?

    public init(run: @escaping @Sendable (String, [String]) -> String?) { self.run = run }

    public static let system = Runner { program, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date() + 2
        while process.isRunning, Date() < deadline { usleep(5000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}

/// write(2), which File's own write would otherwise hide.
func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Glibc)
    Glibc.write(fd, buffer, count)
    #else
    Darwin.write(fd, buffer, count)
    #endif
}

/// A shared library's function, when the library and the function are there.
func symbol<T>(_ library: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T? {
    guard let library, let found = dlsym(library, name) else { return nil }
    return unsafeBitCast(found, to: T.self)
}
