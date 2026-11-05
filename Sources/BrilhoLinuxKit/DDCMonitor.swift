// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore
import BrilhoEngine
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// One I2C bus, /dev/i2c-N, as DDC/CI uses it: the display at address 0x37,
/// messages from the host at 0x51. Each exchange holds a lock on the device, so
/// ddcutil or another Brilho never talk over it.
public protocol DDCBus: AnyObject {
    /// A request, then a reply of `reply` bytes (none for a set); nil if it failed.
    func exchange(_ message: [UInt8], reply: Int) -> [UInt8]?
}

public final class I2CBus: DDCBus {
    public let path: String

    public init(_ path: String) { self.path = path }

    public func exchange(_ message: [UInt8], reply: Int) -> [UInt8]? {
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        guard ioctl(fd, 0x0703, CInt(0x37)) >= 0 else { return nil } // I2C_SLAVE
        var data = [UInt8(0x51)] + message
        guard write(fd, &data, data.count) == data.count else { return nil }
        // Displays need a moment, after a request before its reply and after a set before the next message
        usleep(reply > 0 ? 40_000 : 50_000)
        guard reply > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: reply)
        guard read(fd, &buffer, reply) == reply else { return nil }
        return buffer
    }
}

/// An external monitor over DDC/CI. Each exchange takes tens of milliseconds,
/// so they go through a queue of their own, and the values Brilho works with
/// are the last set or read; writes are coalesced, so a ramp only sends its
/// latest step.
public final class DDCMonitor: Screen {
    public let key: String
    public let name: String
    public let builtin = false
    public let mode = "ddc"
    public let systemDims = false
    public var guess: Levels { .ddcGuess }
    public let resolution = 0.01
    public let stepInterval = 0.1
    public let bus: DDCBus
    private let queue: DispatchQueue
    private let respond: (@escaping () -> Void) -> Void
    // On the responding queue (the main one), like everything Brilho's loop touches
    private var brightnessState: (value: Int, max: Int)?
    private var contrastState: (value: Int, max: Int)?
    private var latest: [UInt8: Int] = [:]
    private var sending = false
    private var writes = 0

    /// `respond` puts results back where Brilho's loop runs: the main queue, or straight away in the tests.
    public init(key: String, name: String, bus: DDCBus, respond: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.key = key
        self.name = name
        self.bus = bus
        self.respond = respond
        queue = DispatchQueue(label: "brilho.ddc.\(key)")
        refresh()
    }

    public var brightness: Double? { brightnessState.map { Double($0.value) / Double(max($0.max, 1)) } }

    /// Sent on its way: whether it took is only known when it's next read.
    @discardableResult public func setBrightness(_ setting: Double) -> Bool {
        let top = brightnessState?.max ?? 100
        let value = Int((min(max(setting, 0), 1) * Double(top)).rounded())
        guard value != brightnessState?.value else { return true }
        brightnessState = (value, top)
        write(0x10, value)
        return true
    }

    public var contrast: (value: Int, max: Int)? { contrastState }

    public func setContrast(_ value: Int) {
        guard let state = contrastState, value != state.value else { return }
        contrastState = (min(max(value, 0), state.max), state.max)
        write(0x12, contrastState!.value)
    }

    /// Reads brightness and contrast again; a reply that comes back after Brilho
    /// has set something since is stale, and dropped.
    public func refresh() {
        let asked = writes
        queue.async {
            let brightness = self.get(0x10), contrast = self.get(0x12)
            self.respond {
                guard self.writes == asked else { return }
                if let brightness, brightness.max > 0 { self.brightnessState = brightness }
                if let contrast, contrast.max > 0 { self.contrastState = contrast }
            }
        }
    }

    /// Waits for every exchange asked for so far, and the ones they lead to,
    /// running what comes back with `pump` (the tests' stand-in for the main queue).
    func drain(pump: () -> Void) {
        for _ in 0..<50 {
            queue.sync {}
            pump()
            if !sending {
                queue.sync {}
                pump()
                return
            }
        }
    }

    private func write(_ control: UInt8, _ value: Int) {
        writes += 1
        latest[control] = value
        guard !sending else { return }
        sending = true
        sendLatest()
    }

    private func sendLatest() {
        guard let (control, value) = latest.first else {
            sending = false
            return
        }
        latest[control] = nil
        queue.async {
            _ = self.bus.exchange(DDCMessage.set(control, value), reply: 0)
            self.respond { self.sendLatest() }
        }
    }

    private func get(_ control: UInt8) -> (value: Int, max: Int)? {
        for _ in 0..<3 {
            if let reply = bus.exchange(DDCMessage.get(control), reply: 11), let value = DDCMessage.reply(reply, for: control) {
                return value
            }
        }
        return nil
    }

    /// The monitors connected now, from the kernel's DRM connectors: each
    /// connected one but the laptop's own panel, named and keyed by its EDID,
    /// with the I2C bus its DDC goes over. What's in the way is logged once.
    public static func find(_ paths: Paths = .current, existing: [String: DDCMonitor] = [:],
                            log: (String) -> Void = { _ in }) -> [DDCMonitor] {
        let base = paths.sys + "/class/drm"
        var found: [DDCMonitor] = []
        for connector in File.list(base) where connector.range(of: #"^card[0-9]+-"#, options: .regularExpression) != nil {
            let port = String(connector.split(separator: "-", maxSplits: 1)[1])
            guard !["eDP", "LVDS", "DSI"].contains(where: { port.hasPrefix($0) }) else { continue } // the laptop's own panel
            let dir = base + "/" + connector
            guard File.text(dir + "/status") == "connected", let bytes = File.bytes(dir + "/edid"), let edid = EDID(bytes) else { continue }
            if let monitor = existing[edid.key] {
                found.append(monitor)
                continue
            }
            // Its DDC bus: the connector's ddc link (Intel, AMD, nouveau), or a DP AUX channel's i2c-N inside it
            guard let bus = File.link(dir + "/ddc").map({ URL(fileURLWithPath: $0).lastPathComponent })
                ?? File.list(dir).first(where: { $0.hasPrefix("i2c-") }) else {
                log("\(edid.name ?? port): no DDC bus found for it")
                continue
            }
            let device = paths.dev + "/" + bus
            guard File.exists(device) else {
                log("\(edid.name ?? port): no \(device); load the i2c-dev module (sudo modprobe i2c-dev)")
                continue
            }
            guard File.accessible(device, R_OK | W_OK) else {
                log("\(edid.name ?? port): no access to \(device); add yourself to its group (ls -l \(device)) and log in again")
                continue
            }
            found.append(DDCMonitor(key: edid.key, name: edid.name ?? port, bus: I2CBus(device)))
        }
        return found
    }
}
