// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore
import BrilhoEngine
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// An ambient light sensor in the kernel's IIO subsystem, as most laptops with
/// one have it (HID sensor hubs, ACPI, Chromebooks' EC): lux from its
/// illuminance channel, processed, or raw with its scale and offset.
public final class IIOLight: AmbientLight {
    public let device: String
    public let name: String
    private static let channels = ["in_illuminance", "in_illuminance0"]

    public static func find(_ paths: Paths = .current) -> IIOLight? {
        let base = paths.sys + "/bus/iio/devices"
        for entry in File.list(base) where entry.hasPrefix("iio:device") {
            let device = base + "/" + entry
            if channels.contains(where: { File.exists("\(device)/\($0)_input") || File.exists("\(device)/\($0)_raw") }) {
                return IIOLight(device)
            }
        }
        return nil
    }

    init(_ device: String) {
        self.device = device
        name = File.text(device + "/name") ?? "light sensor"
    }

    public func lux() -> Double? {
        for channel in Self.channels {
            if let input = File.number("\(device)/\(channel)_input") { return Self.valid(input) }
            if let raw = File.number("\(device)/\(channel)_raw") {
                let scale = File.number("\(device)/\(channel)_scale") ?? 1
                let offset = File.number("\(device)/\(channel)_offset") ?? 0
                return Self.valid((raw + offset) * scale)
            }
        }
        return nil
    }

    private static func valid(_ lux: Double) -> Double? { lux.isFinite && lux >= 0 ? lux : nil }
}

/// A laptop's own panel, through /sys/class/backlight: written directly where
/// the user may (a udev rule, the video group), else through systemd-logind,
/// which lets the session's user set their own panel without root.
public final class Backlight: Screen {
    public let key = "builtin"
    public let name = "Built-in display"
    public let builtin = true
    public let mode = "builtin"
    public let systemDims = true
    public let device: String
    public let maxRaw: Int
    public let writable: Bool
    private let runner: Runner

    /// A laptop panel until it's told: about 3 to 350 nits, linear in the raw value, as PWM dimming is.
    public static let panelGuess = Levels(points: stride(from: 0.0, through: 1, by: 0.05).map {
        Level(setting: $0, nits: 3 + 347 * $0)
    }, calibrated: false)

    public var guess: Levels { Self.panelGuess }
    public var resolution: Double { 1 / Double(maxRaw) }
    public var stepInterval: TimeInterval { writable ? 0.05 : 0.25 }

    /// The one systemd would pick: firmware (ACPI) first, then platform, then raw (the GPU's own).
    public static func find(_ paths: Paths = .current, runner: Runner = .system) -> Backlight? {
        let base = paths.sys + "/class/backlight"
        let rank = ["firmware": 0, "platform": 1, "raw": 2]
        let devices = File.list(base).map { base + "/" + $0 }.filter { (File.number($0 + "/max_brightness") ?? 0) > 0 }
        guard let device = devices.min(by: {
            (rank[File.text($0 + "/type") ?? ""] ?? 3) < (rank[File.text($1 + "/type") ?? ""] ?? 3)
        }) else { return nil }
        return Backlight(device, runner: runner)
    }

    /// `writable` is for the tests, which run as whoever they run as.
    init(_ device: String, runner: Runner, writable: Bool? = nil) {
        self.device = device
        maxRaw = max(Int(File.number(device + "/max_brightness") ?? 1), 1)
        self.writable = writable ?? File.accessible(device + "/brightness", W_OK)
        self.runner = runner
    }

    public var brightness: Double? { File.number(device + "/brightness").map { min(max($0 / Double(maxRaw), 0), 1) } }

    @discardableResult public func setBrightness(_ setting: Double) -> Bool {
        // Never 0: some panels turn off
        let raw = min(max(Int((setting * Double(maxRaw)).rounded()), 1), maxRaw)
        if writable, File.write(String(raw), to: device + "/brightness") { return true }
        return runner.run("busctl", ["--timeout=2", "call", "org.freedesktop.login1", "/org/freedesktop/login1/session/auto",
                                     "org.freedesktop.login1.Session", "SetBrightness", "ssu", "backlight",
                                     URL(fileURLWithPath: device).lastPathComponent, String(raw)]) != nil
    }

    public var contrast: (value: Int, max: Int)? { nil }
    public func setContrast(_: Int) {}
    public func refresh() {}
}

/// On battery when no mains or USB supply is online and there's a battery (not
/// a mouse's).
public enum Power {
    public static func onBattery(_ paths: Paths = .current) -> Bool {
        let base = paths.sys + "/class/power_supply"
        var battery = false
        for supply in File.list(base) {
            let dir = base + "/" + supply
            switch File.text(dir + "/type") {
            case "Mains", "USB":
                if File.text(dir + "/online") == "1" { return false }
            case "Battery":
                if File.text(dir + "/scope") != "Device" { battery = true }
            default:
                break
            }
        }
        return battery
    }
}
