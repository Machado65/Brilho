// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import BrilhoCore
import SwiftUI

/// Brilho's state and its loop: twice a second it reads the light, works out
/// what each display should be at for it and the moment, and eases it there.
final class Controller: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let interval = 0.5
    let maxBoost = 2.0 // ~1000 nits, what the panel sustains over the whole screen
    let xdrLight = log10(1001.0) // XDR is for the sun: not below 1000 lux
    /// The least change in light worth making, in decades: about 3%, under what the eye notices.
    let hysteresis = 0.012
    let sensor = LightSensor()
    let boost = XDR()
    let hud = HUD()
    let circumstances = Circumstances()
    lazy var keys = BrightnessKeys { [weak self] up, fine in self?.brightnessKey(up: up, fine: fine) ?? false }
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    let model = PanelModel()
    var displays: [CGDirectDisplayID: Display] = [:]
    var softwareOnly: Set<CGDirectDisplayID> = [] // they have a DDC channel but didn't answer on it
    var stored: [String: Stored] = [:]
    /// Each display's brightness fitted against the default alone, from the
    /// adjustments whose nits are known: what the others' priors are made of.
    var independent: [String: Preference] = [:]
    var warmth = Preference(prior: Warmth.prior, settings: .warmth)
    var warmthOverride: Double? // the Warmth slider's, while it's held
    var lightFilter = LightFilter()
    var light: Double? // log10(lux + 1), filtered
    var lightIsEstimate = false // lid closed: the light comes from the time of day, and nothing is learnt from it
    var roomKelvin: Double? // smoothed
    var enabled = true
    var xdr = false // not kept across launches: it's for a moment in the sun, and costs battery
    var xdrLevel = 1.6
    var levelBeforeXDR = 1.0
    var dimSince: Date? // when the light dropped below XDR's
    var calibration: Calibration?
    var calibrationWindows: [NSWindow] = []
    var quietUntil = Date.distantPast // no learning right after a display wakes
    var systemAutoCheckedAt = Date.distantPast
    var lightSwitchedAt = Date.distantPast // between the sensor and the time of day
    var nightWarmth = true
    lazy var locator = Locator { [weak self] in self?.located($0) }
    var locationProblem: String?
    var fluxRunning = false // f.lux writes the gamma tables too: the colour is its, and Brilho keeps out
    var measuring: CGDirectDisplayID? // everything else holds still while a display is measured
    var ticks = 0
    var rampTimer: Timer?
    var activity: NSObjectProtocol?
    var now = Moment(date: Date(), schedule: NightSchedule(Date(), location: nil, wake: 450), context: Context())

    var builtin: Display? { displays.values.first(where: \.builtin) }

    func applicationDidFinishLaunching(_: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != .current }) { exit(0) }

        let defaults = UserDefaults.standard
        defaults.register(defaults: ["enabled": true, "xdrLevel": xdrLevel, "nightWarmth": true, "wakeTime": 7.5 * 60])
        nightWarmth = defaults.bool(forKey: "nightWarmth")
        enabled = defaults.bool(forKey: "enabled")
        xdrLevel = min(max(defaults.double(forKey: "xdrLevel"), 1), maxBoost)
        if let data = defaults.data(forKey: "preferences") {
            do {
                stored = try JSONDecoder().decode([String: Stored].self, from: data)
            } catch {
                // Kept aside rather than lost: the next save would overwrite it
                defaults.set(data, forKey: "preferences-unreadable")
                log("couldn't read the saved preferences (\(error)): kept as preferences-unreadable, starting afresh")
            }
        }
        if let data = defaults.data(forKey: "warmth"), let learned = try? JSONDecoder().decode([Adjustment].self, from: data) {
            warmth = Preference(prior: Warmth.prior, adjustments: learned, settings: .warmth)
        }
        for key in stored.keys { independent[key] = independentBrightness(key) }

        model.slide = { [weak self] in self?.slide($0, $1, $2) }
        model.editing = { [weak self] in self?.editing($0, $1, $2) }
        model.setWarmth = { [weak self] in self?.setWarmth($0) }
        model.editingWarmth = { [weak self] in self?.editingWarmth($0) }
        model.setAuto = { [weak self] in self?.setAuto($0) }
        model.setXDR = { [weak self] in self?.setXDR($0) }
        model.setHDR = { [weak self] in self?.setHDR($0, $1) }
        model.setRoomColour = { [weak self] in self?.setRoomColour($0, $1) }
        model.setNightWarmth = { [weak self] in self?.setNightWarmth($0) }
        model.useCurrentLocation = { [weak self] in self?.useCurrentLocation() }
        model.calibrate = { [weak self] in self?.calibrate($0) }
        model.setOpenAtLogin = { [weak self] in self?.setOpenAtLogin($0) }
        model.setWake = { [weak self] in self?.setWake($0) }
        model.allowKeys = { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) }
        model.forget = { [weak self] in self?.forget() }
        let hosting = NSHostingController(rootView: PanelView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateIcon()

        // Without this App Nap throttles the timers while nothing is on screen
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Following the ambient light")
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            // Picked up again, at whatever brightness they wake with
            self?.displays = [:]
            self?.endXDR()
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)

        log("start \(appVersion): sensor \(sensor == nil ? "unavailable" : "ok"), auto brightness \(enabled ? "on" : "off"), "
            + "\(stored.values.reduce(0) { $0 + $1.brightness.count }) brightness and \(warmth.adjustments.count) warmth adjustments")
        tick()
    }

    // MARK: Loop

    func tick() {
        ticks += 1
        refreshDisplays()

        // With the lid closed the built-in display is inactive and its sensor covered: a display's sensor (a
        // Studio Display's) stands in, else the time of day
        let reading = sensor?.read(builtInActive: builtin != nil)
        if (reading == nil) != lightIsEstimate {
            lightIsEstimate = reading == nil
            lightSwitchedAt = Date()
            for display in displays.values where !display.builtin { display.offset = 0 } // holds made against the other light
            log(lightIsEstimate ? "sensor covered: following the time of day" : "sensor back")
        }
        let x = reading.map { log10($0.lux + 1) } ?? scheduledLight(Date())
        // Quicker to brighten than to dim, so a passing shadow does little. Between the sensor and the time of
        // day, slowly: the light last measured fades into the schedule over ~10 minutes (the sensor is often
        // only out for a moment, when the built-in display sleeps), and back over ~20 s
        let switching = Date().timeIntervalSince(lightSwitchedAt) < 60
        let (rising, falling) = lightIsEstimate ? (600.0, 600.0) : switching ? (20.0, 20.0) : (1.5, 3.0)
        light = lightFilter.add(x, interval: interval, rising: rising, falling: falling)
        if let kelvin = reading?.kelvin, (1500...12000).contains(kelvin) {
            // Over a minute or so: a white that moves is more noticeable than one a little off
            roomKelvin = roomKelvin.map { $0 + (kelvin - $0) * (1 - exp(-interval / 60)) } ?? kelvin
        }
        if ticks % 20 == 1 { circumstances.refresh() } // every 10 s
        updateMoment()

        guard calibration == nil, measuring == nil else { return }
        for display in displays.values { track(display) }
        if ticks % 20 == 0 { // every 10 s
            for display in displays.values {
                if display.control == .ddc { poll(display) }
                if display.control == .software { probeDDC(display) }
            }
            if !keys.running, displays.values.contains(where: { $0.control != .native }) { keys.start() }
            let flux = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "org.herf.Flux" }
            if flux != fluxRunning {
                fluxRunning = flux
                log(flux ? "f.lux is running: leaving the gamma tables to it" : "f.lux is gone")
            }
        }

        if xdr, lightIsEstimate || (light ?? 0) < xdrLight {
            if Date().timeIntervalSince(dimSince ?? Date()) > 30 {
                log("XDR: below 1000 lux for half a minute")
                endXDR(gradually: true)
            }
            dimSince = dimSince ?? Date()
        } else {
            dimSince = nil
        }

        // Something (System Settings, another app) may turn it back on: every 30 s is enough to notice
        if enabled, Date().timeIntervalSince(systemAutoCheckedAt) > 30 {
            systemAutoCheckedAt = Date()
            for display in displays.values where display.control == .native && Backlight.systemAuto(display.id) {
                Backlight.turnOffSystemAuto(display.id)
                log("\(display.name): turned off macOS automatic brightness, which fights Brilho's")
            }
        }
        if popover.isShown { updatePanel() }
    }

    func updateMoment() {
        let date = Date()
        let schedule = NightSchedule(date, location: location, wake: UserDefaults.standard.double(forKey: "wakeTime"))
        now = Moment(date: date, schedule: schedule, context: circumstances.context(night: schedule.nightness(at: date)))
    }

    func refreshDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count) // asleep displays aren't active
        let active = Array(ids.prefix(Int(count)))
        // Gone, or switched between HDR (native control) and SDR (DDC): picked up again below
        displays = displays.filter { id, display in
            active.contains(id) && (display.builtin || (display.control == .native) == Backlight.canChange(id))
        }
        if builtin == nil { endXDR() }
        for id in active where displays[id] == nil { add(id) }
    }

    /// Every display gets one: native control, else DDC, else software, which
    /// starts from full white since the gamma table it scales does.
    func add(_ id: CGDirectDisplayID) {
        let isBuiltin = CGDisplayIsBuiltin(id) != 0
        let ddc = isBuiltin ? nil : DDC(display: id)
        let control: Display.Control = isBuiltin || Backlight.canChange(id) ? .native
            : ddc != nil && !softwareOnly.contains(id) ? .ddc : .software
        let key = Display.key(id)
        let mode = isBuiltin ? "builtin" : control.rawValue
        let guess: Levels = isBuiltin ? .builtinGuess : control == .native ? .nativeGuess : control == .ddc ? .ddcGuess : .softwareGuess
        let levels = stored[key]?.levels?[mode].map { Levels(points: $0, calibrated: true) } ?? guess
        let display = Display(id: id, key: key, builtin: isBuiltin, control: control, levels: levels,
                              brightness: brightnessPreference(key),
                              level: control == .native ? Backlight.get(id) ?? 0.5 : control == .ddc ? 0.5 : 1)
        display.ddc = control == .software ? nil : ddc
        display.hdr = isBuiltin ? nil : HDR.isOn(id)
        display.roomColour = stored[key]?.roomColour ?? true
        display.measurable = control == .native && Meter.nits(id) != nil
        displays[id] = display
        quietUntil = Date() + 5
        log("\(display.name): \(display.mode), \(display.brightness.adjustments.count) adjustments\(levels.calibrated ? "" : ", not calibrated")")

        guard let ddc = display.ddc else { return }
        if control == .ddc {
            ddc.read(.brightness) { [weak self, weak display] reply in
                guard let self, let display, self.displays[display.id] === display else { return }
                guard let reply, reply.max > 0 else {
                    // A channel that doesn't answer (DDC/CI off in the monitor's menu, or not ready yet): software for
                    // now, and probeDDC keeps asking
                    log("\(display.name): no answer over DDC, dimming in software")
                    self.softwareOnly.insert(display.id)
                    self.displays[display.id] = nil
                    return
                }
                display.controls[.brightness] = reply
                display.level = Double(reply.value) / Double(reply.max)
                display.target = display.level
                display.ready = true
            }
        }
        for control in [DDC.Control.contrast, .volume] {
            ddc.read(control) { [weak self, weak display] reply in
                guard let self, let display, let reply, reply.max > 0 else { return }
                display.controls[control] = reply
                if control == .contrast { self.startContrast(display, at: reply.value) }
            }
        }
    }

    // MARK: Preferences

    func brightnessPreference(_ key: String) -> Preference { Learned.brightness(key, stored: stored, independent: independent) }
    func independentBrightness(_ key: String) -> Preference { Learned.independent(key, stored: stored) }

    /// After a display's adjustments change, every other one's prior has too.
    func refreshPriors(after key: String) {
        independent[key] = independentBrightness(key)
        for display in displays.values where display.key != key { display.brightness = brightnessPreference(display.key) }
    }

    /// The contrast curve starts flat at the contrast the display had when Brilho
    /// first saw it, so it only ever moves once the user has adjusted it.
    func startContrast(_ display: Display, at value: Int) {
        let base = stored[display.key]?.contrastBase ?? value
        if stored[display.key]?.contrastBase == nil {
            stored[display.key, default: Stored()].contrastBase = value
            save()
        }
        let learned = stored[display.key]?.contrast ?? []
        display.contrast = Preference(prior: { _ in Double(base) }, adjustments: learned, settings: .contrast)
        log("\(display.name): contrast \(value), \(learned.count) adjustments")
    }

    // MARK: Following the light

    func track(_ display: Display) {
        guard display.ready, !display.sliding else { return }
        if let keyedAt = display.keyedAt {
            guard Date().timeIntervalSince(keyedAt) > 1.5 else { return }
            display.keyedAt = nil
            manual(display)
        }

        // Brightness keys and the system can change a native display; the others only change from Brilho, or a DDC one's buttons
        if display.control == .native {
            guard let brightness = Backlight.get(display.id) else { return }
            if abs(brightness - display.backlight) > 0.01 {
                if display.level > 1 {
                    // Dimmed from under the boost: that's the end of XDR
                    display.level = 1
                    display.target = 1
                    endXDR()
                }
                // Changed by someone else: wait until it stops moving to decide by whom
                let user = (display.pending?.user ?? false) || recentlyAdjusted()
                if let pending = display.pending, abs(brightness - pending.value) < 0.003 {
                    display.pending?.user = user
                    if Date().timeIntervalSince(pending.since) >= 1.5 { settle(display, at: brightness, user: user) }
                } else {
                    display.pending = (Date(), brightness, user)
                }
                return
            }
            display.pending = nil
        }

        if enabled, let light {
            followContrast(display, light)
            if !(xdr && display.builtin) {
                let nits = goalNits(display, light)
                let goal = min(max(display.levels.setting(nits: nits) + display.offset, 0), 1)
                // Only a change the eye would notice: the light moves in small steps all day
                if abs(log10(display.levels.nits(goal)) - log10(display.levels.nits(min(display.target, 1)))) > hysteresis {
                    display.target = goal
                    startRamp()
                }
                // Below the lowest a DDC display's backlight goes, the rest comes off the gamma table, down to 30% of the light
                display.dim = display.control == .ddc && !fluxRunning ? min(max(nits / display.levels.minNits, 0.3), 1) : 1
            }
        }
        applyGamma(display)
    }

    func goalNits(_ display: Display, _ light: Double) -> Double {
        pow(10, display.brightness.value(at: light, in: now.context))
    }

    /// A display's gamma table: its white (warmed for the night, and an
    /// external's towards the room too), its brightness when it's dimmed in
    /// software, the light a DDC backlight can't take off, and on the built-in
    /// display the XDR boost.
    func applyGamma(_ display: Display) {
        let boost = display.builtin ? self.boost.factor(display.level, on: display.id) : 1
        // Two apps writing one table take turns, and the screen flickers between their colours
        guard !fluxRunning else {
            display.gamma?.reset()
            display.gamma = nil
            return
        }
        // Calibration compares the displays' light alone, in their own white
        let gains = calibration == nil ? whiteGains(kelvin: white(of: display)) : (1, 1, 1)
        let light = switch display.control {
        case .native: 1.0
        case .ddc: display.dim
        case .software: Levels.softwareLight(display.backlight)
        }
        let factors = [gains.0, gains.1, gains.2].map { Float(pow($0 * light, 1 / 2.2)) * boost }
        if display.gamma == nil { display.gamma = GammaScale(display.id) }
        display.gamma?.set(factors)
    }

    /// Night Warmth's strength now: the Warmth slider's while it's held, else
    /// what's learnt for this time of the evening and these circumstances.
    var warmthStrength: Double { warmthOverride ?? warmth.value(at: now.phase, in: now.context) }

    /// The white Night Warmth sets: D65 by day.
    var nightWhite: Double { nightWarmth ? Warmth.white(strength: warmthStrength, scheduled: now.scheduledWhite) : NightSchedule.day }

    /// The colour temperature a display is set to: the night's, and an
    /// external's room colour if that's warmer (the built-in display has True Tone).
    func white(of display: Display) -> Double {
        var white = nightWhite
        if !display.builtin, display.control != .native, display.roomColour, let roomKelvin { white = min(white, roomWhite(roomKelvin)) }
        return white
    }

    /// Set from Use Current Location; until then evenings start at a fixed time.
    var location: (latitude: Double, longitude: Double)? {
        let defaults = UserDefaults.standard
        guard let latitude = defaults.object(forKey: "latitude") as? Double, let longitude = defaults.object(forKey: "longitude") as? Double
        else { return nil }
        return (latitude, longitude)
    }

    /// One DDC step per tick towards the contrast curve, once it's 2 away: slow
    /// enough not to be noticed, and few enough writes for the monitor.
    func followContrast(_ display: Display, _ light: Double) {
        guard let preference = display.contrast, let state = display.controls[.contrast], !display.adjustingContrast else { return }
        let wanted = preference.value(at: light, in: now.context)
        guard wanted.isFinite else { return }
        let goal = min(max(Int(wanted.rounded()), 0), state.max)
        guard goal != state.value, display.followingContrast || abs(goal - state.value) >= 2 else {
            display.followingContrast = false
            return
        }
        display.followingContrast = true
        let next = state.value + (goal > state.value ? 1 : -1)
        display.controls[.contrast]?.value = next
        display.lastWrite = Date()
        display.ddc?.write(.contrast, next)
    }

    /// Changes made with the monitor's own buttons, read back every 10 s while
    /// Brilho isn't writing: learnt like any other.
    func poll(_ display: Display) {
        guard let ddc = display.ddc, !display.polling, !display.sliding, display.keyedAt == nil, display.level == display.target,
              Date().timeIntervalSince(display.lastWrite) > 3 else { return }
        display.polling = true
        ddc.read(.brightness) { [weak self, weak display] brightness in
            ddc.read(.contrast) { contrast in
                guard let self, let display else { return }
                display.polling = false
                guard !display.sliding, display.keyedAt == nil, display.level == display.target,
                      Date().timeIntervalSince(display.lastWrite) > 3 else { return }
                if let brightness, brightness.max > 0, let known = display.controls[.brightness], abs(brightness.value - known.value) >= 2 {
                    display.controls[.brightness] = brightness
                    display.level = Double(brightness.value) / Double(brightness.max)
                    display.target = display.level
                    display.dim = 1
                    log("\(display.name): brightness set on the monitor to \(brightness.value)")
                    self.manual(display)
                }
                if let contrast, let known = display.controls[.contrast], contrast.value != known.value {
                    display.controls[.contrast] = contrast
                    log("\(display.name): contrast set on the monitor to \(contrast.value)")
                    if self.enabled, !self.lightIsEstimate, let light = self.light { self.learnContrast(display, contrast.value, at: light) }
                }
            }
        }
    }

    /// A display dimmed in software may come to answer DDC: some take a while
    /// after connecting, and some docks only pass it on later. Asked every 10 s for
    /// its first two minutes; once it answers, it's taken over the DDC.
    func probeDDC(_ display: Display) {
        guard !display.polling, Date().timeIntervalSince(display.added) < 120, let ddc = DDC(display: display.id) else { return }
        display.polling = true
        ddc.read(.brightness) { [weak self, weak display] reply in
            guard let self, let display else { return }
            display.polling = false
            guard let reply, reply.max > 0, self.displays[display.id] === display else { return }
            log("\(display.name): answers over DDC now")
            self.softwareOnly.remove(display.id)
            self.displays[display.id] = nil // picked up again by refreshDisplays, over the DDC
        }
    }

    /// A brightness key with the pointer on a display macOS can't dim: Brilho
    /// does it, in macOS's steps (sixteenths, or sixty-fourths with
    /// Option-Shift), and learns it once the keys stop.
    func brightnessKey(up: Bool, fine: Bool) -> Bool {
        let pointer = NSEvent.mouseLocation
        guard calibration == nil, measuring == nil, let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }),
              let id = displayID(screen), let display = displays[id], display.control != .native, display.ready else { return false }
        let step = fine ? 1.0 / 64 : 1.0 / 16
        display.level = min(max(((display.level / step).rounded() + (up ? 1 : -1)) * step, 0), 1)
        display.target = display.level
        display.dim = 1
        display.keyedAt = Date()
        apply(display)
        applyGamma(display)
        hud.show(display.level, on: screen)
        return true
    }

    // MARK: Learning

    func settle(_ display: Display, at brightness: Double, user: Bool) {
        let change = brightness - display.backlight
        display.pending = nil
        display.level = brightness
        display.target = brightness
        guard enabled, Date() > quietUntil else { return }

        // A change that cancels the system's dimming is the system undoing it, even if a click woke the display
        if user && abs(change + display.offset) > 0.02 {
            manual(display)
        } else {
            display.offset = abs(display.offset + change) < 0.01 ? 0 : display.offset + change
            log("\(display.name): system set \(percent(brightness))")
        }
    }

    /// The user set a display's brightness by hand (keys, slider, the monitor's
    /// buttons): learnt, or with the lid closed held as an offset from the
    /// time-of-day level until the sensor is back.
    func manual(_ display: Display) {
        guard enabled, let light else { return }
        if lightIsEstimate {
            display.offset = display.backlight - display.levels.setting(nits: goalNits(display, light))
        } else {
            learnBrightness(display, display.backlight - display.offset, at: light)
        }
    }

    func learnBrightness(_ display: Display, _ brightness: Double, at light: Double) {
        let setting = min(max(brightness, 0), 1) // XDR is never learnt: it's a switch
        let nits = display.levels.nits(setting)
        display.brightness.learn(x: light, value: log10(nits), context: now.context, setting: setting, mode: display.mode)
        stored[display.key, default: Stored()].brightness = display.brightness.adjustments
        save()
        refreshPriors(after: display.key)
        log("\(display.name): learned brightness \(percent(setting)) (\(Int(nits)) nits) at \(lux(light)) lux, \(describe(now.context))")
    }

    func learnContrast(_ display: Display, _ value: Int, at light: Double) {
        guard display.contrast != nil else { return }
        display.contrast?.learn(x: light, value: Double(value), context: now.context)
        stored[display.key, default: Stored()].contrast = display.contrast?.adjustments ?? []
        save()
        log("\(display.name): learned contrast \(value) at \(lux(light)) lux, \(describe(now.context))")
    }

    func learnWarmth(_ strength: Double) {
        warmth.learn(x: now.phase, value: strength, context: now.context)
        if let data = try? JSONEncoder().encode(warmth.adjustments) { UserDefaults.standard.set(data, forKey: "warmth") }
        log("learned warmth \(Int((strength * 100).rounded()))% (\(Int(nightWhite)) K) at phase \(String(format: "%.2f", now.phase)), "
            + describe(now.context))
    }

    func describe(_ context: Context) -> String {
        let night = context.night >= 0.5 ? "night" : "day"
        return [night, context.app, context.dark ? "dark" : nil, context.battery ? "battery" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    func save() {
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: "preferences") }
    }

    /// Whether a brightness key, a click or a scroll (a slider) just happened, as
    /// opposed to the system dimming the display by itself.
    func recentlyAdjusted() -> Bool {
        let systemDefined = CGEventType(rawValue: 14)! // NX_SYSDEFINED, which media and brightness keys are
        return [.keyDown, systemDefined, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .scrollWheel].contains {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < 2.5
        }
    }

    // MARK: Setting it

    func apply(_ display: Display) {
        switch display.control {
        case .native:
            Backlight.set(display.id, display.backlight)
            if display.builtin { applyGamma(display) } // the XDR boost
        case .ddc:
            let max = display.controls[.brightness]?.max ?? 100
            let value = Int((display.backlight * Double(max)).rounded())
            guard value != display.controls[.brightness]?.value else { return }
            display.controls[.brightness] = (value, max)
            display.lastWrite = Date()
            display.ddc?.write(.brightness, value)
        case .software:
            applyGamma(display)
        }
    }

    func startRamp() {
        guard rampTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.ramp() }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
    }

    /// Twenty steps a second: even in the light (see rampStep), most of the way
    /// in two or three seconds, so a change in the room doesn't jump at the eye.
    /// The XDR boost moves in even steps of itself.
    func ramp() {
        var moving = false
        for display in displays.values where display.pending == nil && !display.sliding && display.level != display.target {
            // Set by someone else on the way (a brightness key): stop, and let track() see who
            if display.control == .native, display.level <= 1, let current = Backlight.get(display.id), abs(current - display.backlight) > 0.01 {
                display.target = display.level
                continue
            }
            if display.level > 1 || display.target > 1 {
                let gap = display.target - display.level
                display.level = abs(gap) <= 0.001 ? display.target : display.level + (gap < 0 ? -1 : 1) * max(abs(gap) * 0.04, 0.001)
            } else {
                display.level = rampStep(from: display.level, to: display.target, levels: display.levels)
            }
            apply(display)
            moving = true
        }
        if !moving {
            rampTimer?.invalidate()
            rampTimer = nil
        }
    }

    func startXDR() {
        guard !xdr, let builtin else { return }
        guard !lightIsEstimate, (light ?? 0) >= xdrLight else { return log("XDR: only in bright light, above 1000 lux") }
        xdr = true
        levelBeforeXDR = builtin.level
        builtin.target = xdrLevel
        startRamp()
        updateIcon()
        log("XDR on")
    }

    /// Back to SDR: gradually from the panel, at once when the display went or the user dimmed it.
    func endXDR(gradually: Bool = false) {
        guard xdr else { return boost.off() }
        xdr = false
        if gradually, let builtin {
            builtin.sliding = false
            builtin.target = min(levelBeforeXDR, 1)
            startRamp()
        } else {
            boost.off()
        }
        updateIcon()
        log("XDR off")
    }

    func updateIcon() {
        statusItem.button?.image = NSImage(systemSymbolName: xdr ? "sun.max.fill" : "sun.max", accessibilityDescription: "Brilho")
        statusItem.button?.appearsDisabled = !enabled
    }
}

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
