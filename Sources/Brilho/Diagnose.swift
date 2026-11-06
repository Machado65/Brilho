// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import BrilhoCore
import ServiceManagement

/// `Brilho --diagnose`: what Brilho sees and has learnt, for a bug report. It
/// only reads: DDC values are asked for, never set.
func diagnose() {
    let defaults = UserDefaults.standard
    let stored = defaults.data(forKey: "preferences").flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
    let context = Circumstances().context(night: 0)
    let schedule = NightSchedule(Date(), location: defaults.object(forKey: "latitude").flatMap { latitude in
        defaults.object(forKey: "longitude").map { (latitude as? Double ?? 0, $0 as? Double ?? 0) }
    }, wake: defaults.object(forKey: "wakeTime") as? Double ?? 450)
    let night = schedule.nightness(at: Date())
    let now = Context(night: night, app: context.app, dark: context.dark, battery: context.battery)

    print("Brilho \(appVersion), diagnostics (reads only)")
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.processorCount) cores")
    if let sensor = LightSensor() {
        let readings = sensor.readings()
        if readings.isEmpty { print("Light sensors: no reading (lid closed?)") }
        for reading in readings {
            print("Light sensor \(reading.product) (\(reading.builtIn ? "the Mac's" : "a display's")): "
                + "\(Int(reading.lux.rounded())) lux, \(Int(reading.kelvin.rounded())) K")
        }
    } else {
        print("Light sensor: none found")
    }
    print("Now: night \(String(format: "%.2f", night)), app \(now.app ?? "none"), \(now.dark ? "dark" : "light") appearance, "
        + "\(now.battery ? "on battery" : "on power")")
    print("Settings: auto brightness \(defaults.object(forKey: "enabled") as? Bool ?? true ? "on" : "off"), "
        + "night warmth \(defaults.object(forKey: "nightWarmth") as? Bool ?? true ? "on" : "off"), "
        + "location \(defaults.object(forKey: "latitude") == nil ? "not set" : "set"), "
        + "wake \(Int(defaults.double(forKey: "wakeTime")) / 60):\(String(format: "%02d", Int(defaults.double(forKey: "wakeTime")) % 60))")
    let login = switch SMAppService.mainApp.status {
    case .enabled: "on"
    case .requiresApproval: "waiting for approval"
    case .notRegistered: "off"
    default: "not found"
    }
    // From a terminal, macOS asks about the terminal's permission, not Brilho's
    print("Open at Login: \(login); Accessibility for whatever started this: \(AXIsProcessTrusted() ? "granted" : "not granted")")

    let warmthAdjustments = defaults.data(forKey: "warmth").flatMap { try? JSONDecoder().decode([Adjustment].self, from: $0) } ?? []
    let warmth = Preference(prior: Warmth.prior, adjustments: warmthAdjustments, settings: .warmth)
    let strength = warmth.value(at: schedule.warmthPhase(at: Date()), in: now)
    print("Night Warmth: \(schedule.phase(at: Date())); scheduled \(Int(schedule.white(at: Date()))) K, strength "
        + "\(Int((strength * 100).rounded()))%, white \(Int(Warmth.white(strength: strength, scheduled: schedule.white(at: Date())))) K; "
        + "\(warmthAdjustments.count) adjustments; by phase " + [0.0, 1, 2].map { "\(Int((warmth.base(at: $0) * 100).rounded()))%" }.joined(separator: " "))

    var independent: [String: Preference] = [:]
    for key in stored.keys { independent[key] = Learned.independent(key, stored: stored) }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &count)
    for id in ids.prefix(Int(count)) {
        let key = Display.key(id), builtin = CGDisplayIsBuiltin(id) != 0
        let ddc = builtin ? nil : DDC(display: id)
        let control = builtin || Backlight.canChange(id) ? "native" : ddc != nil ? "ddc" : "software"
        print("\nDisplay \(id): \(screen(id)?.localizedName ?? "unnamed"), key \(key), \(control)")
        if let brightness = Backlight.get(id) { print("  macOS brightness \(percent(brightness))") }
        if control == "native", let nits = Meter.nits(id) { print("  driven at \(Int(nits.rounded())) nits") }
        if !builtin, let hdr = HDR.isOn(id) { print("  HDR \(hdr ? "on" : "off")") }
        if Backlight.systemAuto(id) { print("  macOS automatic brightness is ON (Brilho turns it off when it runs)") }
        if let ddc {
            let values = [("brightness", DDC.Control.brightness), ("contrast", .contrast), ("volume", .volume)].map { name, control in
                "\(name) " + (ddc.readNow(control).map { "\($0.value)/\($0.max)" } ?? "no answer")
            }
            print("  DDC: " + values.joined(separator: ", "))
        }
        let kept = stored[key]
        print("  levels: " + ((kept?.levels?.keys.sorted()).map { $0.isEmpty ? "guessed" : "kept for " + $0.joined(separator: ", ") } ?? "guessed"))
        let start = Date()
        let white = builtin ? (kept?.levels?["builtin"].map { Levels(points: $0, calibrated: true) } ?? .builtinGuess).nits(1) : nil
        let preference = Learned.brightness(key, stored: stored, independent: independent, white: white)
        let elapsed = Date().timeIntervalSince(start)
        print("  \(preference.adjustments.count) brightness adjustments, fitted in \(String(format: "%.1f", elapsed * 1000)) ms; "
            + "\(kept?.contrast.count ?? 0) contrast" + (kept?.contrastBase.map { " (from \($0))" } ?? ""))
        let curve = [1.0, 10, 100, 1000, 10000].map { lux in
            "\(Int(lux)) lux \(Int(pow(10, preference.value(at: log10(lux + 1), in: now)).rounded()))"
        }
        print("  nits wanted now: " + curve.joined(separator: ", "))
        let effects = preference.effects
        let apps = effects.apps.sorted { abs($0.value) > abs($1.value) }.prefix(5).map { "\($0.key) \(signed($0.value))" }
        print("  shifts (decades): night \(signed(effects.night)), dark \(signed(effects.dark)), battery \(signed(effects.battery))"
            + (apps.isEmpty ? "" : "; apps " + apps.joined(separator: ", ")))
    }
}

private func signed(_ value: Double) -> String { String(format: "%+.3f", value) }
