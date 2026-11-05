// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import BrilhoCore
import CoreLocation
import ServiceManagement

/// The popover, and what's set from it.
extension Controller {
    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button, calibration == nil, measuring == nil {
            updateLogin()
            updatePanel()
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_: Notification) {
        for display in displays.values {
            finishSliding(display)
            display.adjustingContrast = false
        }
        if warmthOverride != nil { editingWarmth(false) }
    }

    func updatePanel() {
        let shownLux = light.map(lux)
        if model.lux != shownLux { model.lux = shownLux }
        if model.estimated != lightIsEstimate { model.estimated = lightIsEstimate }
        if model.auto != enabled { model.auto = enabled }
        if model.nightWarmth != nightWarmth { model.nightWarmth = nightWarmth }
        let nightPhase = now.schedule.phase(at: now.date)
        if model.nightPhase != nightPhase { model.nightPhase = nightPhase }
        // The strength only means something while the schedule has warmth to scale
        let scheduledWarmth = mireds(now.scheduledWhite) - mireds(NightSchedule.day)
        let warmthShown = nightWarmth && !fluxRunning && scheduledWarmth > 10 ? min(max(warmthStrength, 0), 2) : nil
        if model.warmth != warmthShown { model.warmth = warmthShown }
        let kelvin = Int((nightWhite / 50).rounded() * 50)
        if model.warmthKelvin != kelvin { model.warmthKelvin = kelvin }
        let place = placeText
        if model.place != place { model.place = place }
        if model.locationProblem != locationProblem { model.locationProblem = locationProblem }
        if model.xdr != xdr { model.xdr = xdr }
        // Only for the built-in display, and only with the lid open
        let xdrAvailable = builtin.flatMap { screen($0.id) }.map { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 } ?? false
        if model.xdrAvailable != xdrAvailable { model.xdrAvailable = xdrAvailable }
        let xdrAllowed = !lightIsEstimate && (light ?? 0) >= xdrLight
        if model.xdrAllowed != xdrAllowed { model.xdrAllowed = xdrAllowed }
        if model.canCalibrate != (builtin != nil) { model.canCalibrate = builtin != nil }
        if model.measuring != measuring { model.measuring = measuring }
        let wakeMinutes = Int(UserDefaults.standard.double(forKey: "wakeTime"))
        let wake = Calendar.current.date(bySettingHour: wakeMinutes / 60, minute: wakeMinutes % 60, second: 0, of: Date()) ?? Date()
        if model.wake != wake { model.wake = wake }
        let keysNeedPermission = displays.values.contains { $0.control != .native } && !AXIsProcessTrusted()
        if model.keysNeedPermission != keysNeedPermission { model.keysNeedPermission = keysNeedPermission }

        let sorted = displays.values.sorted { ($0.builtin ? 0 : $0.id) < ($1.builtin ? 0 : $1.id) }
        let rows = sorted.map { display in
            PanelModel.Row(
                id: display.id, name: display.name, brightness: display.level, nits: Int(display.nits.rounded()),
                // In XDR the built-in display's slider is the boost, from 100% (480 nits) up
                brightnessRange: xdr && display.builtin ? 1...maxBoost : 0...1,
                contrast: display.controls[.contrast].map { Double($0.value) }, volume: display.controls[.volume].map { Double($0.value) },
                controlMax: display.controls.mapValues { Double($0.max) }, hdr: display.hdr,
                roomColour: display.control != .native && !fluxRunning ? display.roomColour : nil,
                white: fluxRunning ? nil : Int((white(of: display) / 100).rounded() * 100),
                external: !display.builtin, software: display.control == .software, measurable: display.measurable,
                calibrated: display.levels.calibrated)
        }
        if model.rows != rows { model.rows = rows }

        // The curves the panel draws: what each display aims for in the present circumstances, by day and at
        // night, within what it can do
        let samples = stride(from: 0.0, through: 4.0, by: 0.1).map { pow(10, $0) }
        let series = sorted.enumerated().map { slot, display in
            let reach = (display.control == .ddc ? display.levels.minNits * 0.3 : display.levels.minNits)...display.levels.maxNits
            func curve(_ night: Double) -> [PanelModel.Point] {
                var context = now.context
                context.night = night
                return samples.map { lux in
                    let nits = pow(10, display.brightness.value(at: log10(lux + 1), in: context))
                    return PanelModel.Point(lux: lux, nits: min(max(nits, reach.lowerBound), reach.upperBound))
                }
            }
            return PanelModel.Series(
                id: display.id, name: display.builtin ? "Built-in" : display.name, slot: slot, day: curve(0),
                night: abs(display.brightness.effects.night) > 0.02 ? curve(1) : nil,
                adjustments: display.brightness.adjustments.map {
                    PanelModel.Point(lux: max(pow(10, $0.x) - 1, 1), nits: pow(10, $0.value))
                })
        }
        if model.series != series { model.series = series }
    }

    func slide(_ id: CGDirectDisplayID, _ setting: Setting, _ value: Double) {
        guard let display = displays[id] else { return }
        if let control = setting.control {
            let new = Int(value.rounded())
            guard let state = display.controls[control], new != state.value else { return }
            display.controls[control]?.value = new
            display.lastWrite = Date()
            display.ddc?.write(control, new)
        } else {
            display.sliding = true
            display.pending = nil
            display.level = value
            display.target = value
            display.dim = 1 // the slider is the backlight alone
            apply(display)
            applyGamma(display)
        }
        updatePanel()
    }

    func editing(_ id: CGDirectDisplayID, _ setting: Setting, _ began: Bool) {
        guard let display = displays[id] else { return }
        switch setting {
        case .brightness:
            if began { display.sliding = true } else { finishSliding(display) }
        case .contrast:
            display.adjustingContrast = began
            display.followingContrast = false
            if !began, enabled, !lightIsEstimate, let light, let value = display.controls[.contrast]?.value {
                learnContrast(display, value, at: light)
            }
        case .volume:
            break
        }
    }

    /// A brightness slider let go is a manual adjustment like any other. In XDR
    /// it sets the boost instead.
    func finishSliding(_ display: Display) {
        guard display.sliding else { return }
        display.sliding = false
        if xdr && display.builtin {
            xdrLevel = display.level
            UserDefaults.standard.set(xdrLevel, forKey: "xdrLevel")
        } else {
            manual(display)
        }
    }

    /// The Warmth slider sets every screen's white as it moves.
    func setWarmth(_ strength: Double) {
        warmthOverride = strength
        displays.values.forEach(applyGamma)
        updatePanel()
    }

    /// Let go, it's learnt for this time of the evening and the app in front.
    func editingWarmth(_ began: Bool) {
        if began {
            warmthOverride = warmthOverride ?? warmthStrength
            return
        }
        guard let strength = warmthOverride else { return }
        learnWarmth(strength)
        warmthOverride = nil
        displays.values.forEach(applyGamma)
        updatePanel()
    }

    /// brilho://auto and brilho://xdr toggle those, for keyboard shortcuts.
    func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "auto": setAuto(!enabled)
            case "xdr": setXDR(!xdr)
            default: log("unknown URL \(url)")
            }
        }
    }

    /// Turning it on also ends XDR: back to following the light everywhere.
    func setAuto(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(enabled, forKey: "enabled")
        for display in displays.values { display.target = display.level }
        if on {
            endXDR(gradually: true)
            systemAutoCheckedAt = .distantPast
        }
        updateIcon()
        updatePanel()
        log("auto brightness \(enabled ? "on" : "off")")
    }

    func setXDR(_ on: Bool) {
        if on {
            startXDR()
        } else {
            endXDR(gradually: true)
        }
        updatePanel()
    }

    /// The display goes black for a moment while it switches; refreshDisplays then
    /// picks it up again under its new control.
    func setHDR(_ id: CGDirectDisplayID, _ on: Bool) {
        guard let display = displays[id], display.hdr != nil else { return }
        HDR.set(id, on)
        display.hdr = on
        updatePanel()
        log("\(display.name): HDR \(on ? "on" : "off")")
    }

    func setNightWarmth(_ on: Bool) {
        nightWarmth = on
        UserDefaults.standard.set(on, forKey: "nightWarmth")
        displays.values.forEach(applyGamma)
        updatePanel()
        log("night warmth \(on ? "on" : "off")")
    }

    func useCurrentLocation() {
        locationProblem = nil
        model.locating = true
        updatePanel()
        locator.locate()
    }

    /// Kept to two decimals, about a kilometre: more than the sunset needs.
    func located(_ result: Result<CLLocation, Error>) {
        model.locating = false
        switch result {
        case let .success(location):
            let defaults = UserDefaults.standard
            defaults.set((location.coordinate.latitude * 100).rounded() / 100, forKey: "latitude")
            defaults.set((location.coordinate.longitude * 100).rounded() / 100, forKey: "longitude")
            locationProblem = nil
            updateMoment()
            displays.values.forEach(applyGamma)
            log("location: \(placeText)")
        case let .failure(error):
            locationProblem = Locator.describe(error)
            log("location: \(error.localizedDescription)")
        }
        updatePanel()
    }

    /// "Sunsets for 38.72° N, 9.14° W", for the panel.
    var placeText: String {
        guard let (latitude, longitude) = location else { return "Evenings from 19:30, until you set your location" }
        return String(format: "Sunsets for %.2f° %@, %.2f° %@", abs(latitude), latitude < 0 ? "S" : "N", abs(longitude), longitude < 0 ? "W" : "E")
    }

    func setWake(_ date: Date) {
        let time = Calendar.current.dateComponents([.hour, .minute], from: date)
        UserDefaults.standard.set(Double((time.hour ?? 7) * 60 + (time.minute ?? 30)), forKey: "wakeTime")
        updateMoment()
        displays.values.forEach(applyGamma)
        updatePanel()
    }

    /// Through the system's Login Items, so it needs nothing else to start with the Mac.
    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log("open at login \(on ? "on" : "off")")
        } catch {
            log("open at login: \(error.localizedDescription)")
        }
        updateLogin()
        updatePanel()
    }

    func updateLogin() {
        let status = SMAppService.mainApp.status
        if model.openAtLogin != (status == .enabled) { model.openAtLogin = status == .enabled }
        if model.loginNeedsApproval != (status == .requiresApproval) { model.loginNeedsApproval = status == .requiresApproval }
    }

    func setRoomColour(_ id: CGDirectDisplayID, _ on: Bool) {
        guard let display = displays[id] else { return }
        display.roomColour = on
        stored[display.key, default: Stored()].roomColour = on
        save()
        applyGamma(display)
        updatePanel()
        log("\(display.name): room colour \(on ? "on" : "off")")
    }
}
