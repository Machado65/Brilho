// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import BrilhoCore

/// Finding out how many nits each setting gives, and starting over.
extension Controller {
    /// Measured where macOS knows the nits; else matched by eye against the
    /// built-in display, measured first if it hasn't been.
    func calibrate(_ id: CGDirectDisplayID) {
        guard let display = displays[id] else { return }
        if display.measurable { return measure(display) }
        if let builtin, builtin.measurable, !builtin.levels.calibrated {
            return measure(builtin) { [weak self] in self?.calibrateByEye(id) }
        }
        calibrateByEye(id)
    }

    /// Steps a display macOS dims itself through its settings, reading back the
    /// nits it drives the panel at once each has settled. Off the main thread: it
    /// takes half a minute, with the screen going through its range meanwhile.
    func measure(_ display: Display, then next: (() -> Void)? = nil) {
        guard measuring == nil, calibration == nil, display.measurable else { return }
        popover.performClose(nil)
        dropBoost()
        measuring = display.id
        let id = display.id, before = display.backlight
        log("\(display.name): measuring")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var points: [Level] = []
            for step in 1...20 {
                let setting = Double(step) / 20
                Backlight.set(id, setting)
                var last = -1.0
                for _ in 0..<12 { // until two readings half a second apart agree, or 6 s
                    usleep(500_000)
                    guard let nits = Meter.nits(id), abs(nits - last) > 0.01 else { break }
                    last = nits
                }
                if let nits = Meter.nits(id), nits > 0 { points.append(Level(setting: setting, nits: nits)) }
            }
            Backlight.set(id, before)
            DispatchQueue.main.async { self?.endMeasuring(id, points, then: next) }
        }
    }

    func endMeasuring(_ id: CGDirectDisplayID, _ points: [Level], then next: (() -> Void)?) {
        measuring = nil
        quietUntil = Date() + 5
        for display in displays.values {
            display.target = display.level
            display.pending = nil
        }
        guard let display = displays[id] else { return }
        guard points.count == 20 else { return log("\(display.name): couldn't measure it") }
        keep(points, for: display, "measured")
        next?()
    }

    func calibrateByEye(_ id: CGDirectDisplayID) {
        guard let target = displays[id], !target.builtin, let builtin,
              let builtinScreen = screen(builtin.id), let targetScreen = screen(id) else { return }
        popover.performClose(nil)
        dropBoost()
        // The square has to be the backlight alone: no dimming or warming in the gamma table
        target.dim = 1
        target.gamma?.reset()
        let session = Calibration(targetName: target.name, reference: builtin.levels, guess: target.levels,
                                  show: { [weak self] nits, setting in
                                      builtin.level = builtin.levels.setting(nits: nits)
                                      builtin.target = builtin.level
                                      Backlight.set(builtin.id, builtin.level)
                                      target.level = setting
                                      target.target = setting
                                      self?.apply(target)
                                  },
                                  done: { [weak self] matched in self?.endCalibration(target, matched) })
        calibration = session
        displays.values.forEach(applyGamma) // to the backlights alone
        calibrationWindows = [
            CalibrationWindow(screen: targetScreen, view: CalibrationView(calibration: session, controls: false)),
            CalibrationWindow(screen: builtinScreen, view: CalibrationView(calibration: session, controls: true)),
        ]
        NSApp.activate()
        calibrationWindows.last?.makeKeyAndOrderFront(nil)
        log("\(target.name): calibrating (\(target.mode))")
    }

    func endCalibration(_ display: Display, _ matched: [Level]?) {
        calibrationWindows.forEach { $0.close() }
        calibrationWindows = []
        calibration = nil
        quietUntil = Date() + 5
        for display in displays.values {
            display.target = display.level
            display.pending = nil
        }
        guard let matched else { return log("\(display.name): calibration cancelled") }
        keep(matched, for: display, "calibrated")
    }

    /// New levels for a display, measured or matched by eye; and the adjustments
    /// made in its mode, which were made at a setting, get the nits that setting
    /// gives now.
    func keep(_ levels: [Level], for display: Display, _ how: String) {
        display.levels = Levels.kept(levels)
        let points = display.levels.points
        stored[display.key, default: Stored()].levels = (stored[display.key]?.levels ?? [:]).merging([display.mode: points]) { $1 }
        let adjustments = display.brightness.adjustments.map { adjustment -> Adjustment in
            guard adjustment.mode == display.mode, let setting = adjustment.setting else { return adjustment }
            var recalculated = adjustment
            recalculated.value = log10(display.levels.nits(setting))
            return recalculated
        }
        stored[display.key, default: Stored()].brightness = adjustments
        save()
        display.brightness = brightnessPreference(display.key)
        refreshPriors(after: display.key)
        let shown = points.count > 5 ? stride(from: 0, to: points.count, by: points.count / 4).map { points[$0] } + [points[points.count - 1]] : points
        log("\(display.name): \(how) (\(display.mode)) " + shown.map { "\(percent($0.setting)) = \(Int($0.nits)) nits" }.joined(separator: ", "))
    }

    /// Every adjustment, of brightness, contrast and warmth; the calibrations stay.
    func forget() {
        for key in stored.keys {
            stored[key]?.brightness = []
            stored[key]?.contrast = []
        }
        save()
        UserDefaults.standard.removeObject(forKey: "warmth")
        warmth = Preference(prior: Warmth.prior, settings: .warmth)
        independent = [:]
        for display in displays.values {
            display.brightness = brightnessPreference(display.key)
            if let base = stored[display.key]?.contrastBase {
                display.contrast = Preference(prior: { _ in Double(base) }, settings: .contrast)
            }
        }
        displays.values.forEach(applyGamma)
        log("adjustments forgotten")
    }
}
