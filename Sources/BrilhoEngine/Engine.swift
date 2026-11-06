// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore
import Foundation

/// Brilho's loop where it runs as a service (Linux): it follows the light with
/// every screen's brightness, eases it there, learns from what the user sets
/// (their desktop's brightness keys, a monitor's own buttons, its commands)
/// and sets Night Warmth's white. Driven by `update(at:)`, as often as twenty
/// times a second; the hardware is behind the protocols in Hardware.swift.
public final class Engine {
    /// A screen as Brilho follows it.
    final class Followed {
        let screen: Screen
        var levels: Levels
        var preference: Preference
        var contrast: Preference?
        var level: Double = 0 // where Brilho has it
        var target: Double = 0
        var expected: Double? // what it should read if nothing else has touched it; nil until it's first read
        var expectedContrast: Int?
        var followingContrast = false
        var offset = 0.0 // the system's own dimming (idle, battery), while it lasts
        var pending: (since: Date, value: Double)? // a change Brilho didn't make, waiting to settle
        var steppedAt = Date.distantPast
        var refreshedAt = Date.distantPast
        var failing = false // its brightness couldn't be set: logged once

        init(_ screen: Screen, levels: Levels, preference: Preference) {
            self.screen = screen
            self.levels = levels
            self.preference = preference
        }
    }

    /// The least change in light worth making, in decades: about 3%, under what the eye notices.
    public static let hysteresis = 0.012

    public private(set) var config: Config
    public private(set) var state: State
    public private(set) var light: Double? // log10(lux + 1), filtered
    public private(set) var estimate = false // no sensor reading: the light comes from the time of day, and nothing is learnt
    public private(set) var white: Double = NightSchedule.day

    private let sensor: AmbientLight?
    private let whiteOutput: WhiteOutput?
    private let surroundings: Surroundings
    private let calendar: Calendar
    private let save: (State) -> Void
    private let saveConfig: (Config) -> Void
    private let log: (String) -> Void
    private var followed: [String: Followed] = [:]
    private var order: [String] = []
    private var independent: [String: Preference] = [:]
    private var warmth: Preference
    private var filter = LightFilter()
    private var readAt = Date.distantPast
    private var switchedAt = Date.distantPast
    private var whiteAt = Date.distantPast
    private var whiteSet: Double?
    private var moment: (schedule: NightSchedule, context: Context)?

    public init(sensor: AmbientLight?, screens: [Screen], white: WhiteOutput?, surroundings: Surroundings,
                config: Config, state: State, calendar: Calendar = .current,
                save: @escaping (State) -> Void, saveConfig: @escaping (Config) -> Void, log: @escaping (String) -> Void) {
        self.sensor = sensor
        whiteOutput = white
        self.surroundings = surroundings
        self.config = config
        self.state = state
        self.calendar = calendar
        self.save = save
        self.saveConfig = saveConfig
        self.log = log
        warmth = Preference(prior: Warmth.prior, adjustments: state.warmth, settings: .warmth)
        for key in state.displays.keys { independent[key] = Learned.independent(key, stored: state.displays) }
        setScreens(screens)
    }

    /// The screens now connected: new ones are picked up, gone ones dropped.
    public func setScreens(_ screens: [Screen]) {
        let keys = screens.map(\.key)
        for key in order where !keys.contains(key) {
            log("\(followed[key]?.screen.name ?? key): gone")
            followed[key] = nil
        }
        for screen in screens where followed[screen.key] == nil || followed[screen.key]?.screen !== screen {
            let levels = state.displays[screen.key]?.levels?[screen.mode].map { Levels(points: $0, calibrated: true) } ?? screen.guess
            followed[screen.key] = Followed(screen, levels: levels, preference: brightnessPreference(screen.key))
            log("\(screen.name): \(screen.mode), \(state.displays[screen.key]?.brightness.count ?? 0) adjustments"
                + (levels.calibrated ? "" : ", nits guessed"))
        }
        order = keys
    }

    public var screens: [Screen] { order.compactMap { followed[$0]?.screen } }

    /// Whether a screen is on its way somewhere, and wants `update(at:)` twenty times a second; otherwise twice is enough.
    public var easing: Bool { followed.values.contains { $0.level != $0.target && $0.pending == nil } }

    // MARK: The loop

    public func update(at date: Date) {
        if date.timeIntervalSince(readAt) >= 0.5 {
            let interval = readAt == .distantPast ? 0.5 : min(date.timeIntervalSince(readAt), 5)
            readAt = date
            readLight(at: date, interval: interval)
            let schedule = NightSchedule(date, location: config.latitude.flatMap { latitude in config.longitude.map { (latitude, $0) } },
                                         wake: config.wake, calendar: calendar)
            moment = (schedule, surroundings.context(night: schedule.nightness(at: date)))
            for key in order { if let followed = followed[key] { track(followed, at: date) } }
            setWhite(at: date)
        }
        for key in order {
            guard let followed = followed[key], followed.level != followed.target, followed.pending == nil,
                  date.timeIntervalSince(followed.steppedAt) >= followed.screen.stepInterval else { continue }
            // Set by someone else on the way (a brightness key): stop, and let track() see who
            if let current = followed.screen.brightness, let expected = followed.expected,
               abs(current - expected) > 1.5 * followed.screen.resolution {
                followed.target = followed.level
                followed.pending = (date, current)
                continue
            }
            let next = rampStep(from: followed.level, to: followed.target, levels: followed.levels)
            guard followed.screen.setBrightness(next) else {
                failed(followed)
                continue
            }
            followed.failing = false
            followed.level = next
            followed.expected = next
            followed.steppedAt = date
        }
    }

    /// Its brightness couldn't be set: left where it is, which isn't taken for the user's setting.
    private func failed(_ followed: Followed) {
        if !followed.failing { log("\(followed.screen.name): couldn't set its brightness") }
        followed.failing = true
        let current = followed.screen.brightness ?? followed.level
        followed.level = current
        followed.target = current
        followed.expected = current
        followed.pending = nil
    }

    /// Quicker to brighten than to dim, so a passing shadow does little. Between
    /// the sensor and the time of day, slowly: the light last measured fades into
    /// the schedule over ~10 minutes, and back over ~20 s.
    private func readLight(at date: Date, interval: Double) {
        let lux = sensor?.lux()
        if (lux == nil) != estimate {
            estimate = lux == nil
            switchedAt = date
            log(estimate ? "no light reading: following the time of day" : "light sensor reading")
        }
        let x = lux.map { log10(max($0, 0) + 1) } ?? scheduledLight(date, in: calendar)
        let switching = date.timeIntervalSince(switchedAt) < 60
        let (rising, falling) = estimate ? (600.0, 600.0) : switching ? (20.0, 20.0) : (1.5, 3.0)
        light = filter.add(x, interval: interval, rising: rising, falling: falling)
    }

    private func track(_ followed: Followed, at date: Date) {
        guard let current = followed.screen.brightness else { return }
        if followed.expected == nil {
            // Picked up as it is
            followed.expected = current
            followed.level = current
            followed.target = current
        }
        let quiet = followed.level == followed.target && date.timeIntervalSince(followed.steppedAt) > 1
        // Changed by someone else (the desktop's keys, the system dimming it, the monitor's buttons): held still
        // until it stops moving, to decide who
        if let expected = followed.expected, abs(current - expected) > 1.5 * followed.screen.resolution {
            followed.target = followed.level
            if let pending = followed.pending, abs(current - pending.value) <= 1.5 * followed.screen.resolution {
                if date.timeIntervalSince(pending.since) >= 1.5 { settle(followed, at: current, date: date) }
            } else {
                followed.pending = (date, current)
            }
            return
        }
        followed.pending = nil

        if config.enabled, let light, let context = moment?.context {
            followContrast(followed, light, context, quiet: quiet, date: date)
            let nits = pow(10, followed.preference.value(at: light, in: context))
            let goal = min(max(followed.levels.setting(nits: nits) + followed.offset, 0), 1)
            if abs(log10(followed.levels.nits(goal)) - log10(followed.levels.nits(followed.target))) > Self.hysteresis {
                followed.target = goal
            }
        }
        // A display read on request (DDC) is asked again every 10 s while Brilho isn't changing it
        if quiet, date.timeIntervalSince(followed.steppedAt) > 3, date.timeIntervalSince(followed.refreshedAt) >= 10 {
            followed.refreshedAt = date
            followed.screen.refresh()
        }
    }

    /// A change Brilho didn't make, settled: the user's (learnt), or the
    /// system's dimming, made while no one was at the keyboard (kept as an
    /// offset until it's undone). One that undoes the system's dimming is the
    /// system's too, even if a key woke the screen.
    private func settle(_ followed: Followed, at current: Double, date: Date) {
        let change = current - (followed.expected ?? current)
        followed.pending = nil
        followed.level = current
        followed.target = current
        followed.expected = current
        let user = !followed.screen.systemDims || (surroundings.idleTime() ?? 0) < 10
        if user && abs(change + followed.offset) > 0.02 {
            manual(followed, at: date)
        } else {
            followed.offset = abs(followed.offset + change) < 0.01 ? 0 : followed.offset + change
            log("\(followed.screen.name): the system set \(Int((current * 100).rounded()))%")
        }
    }

    /// Set by the user: learnt, or with no light reading, held as an offset
    /// from the time of day's level until there is one.
    private func manual(_ followed: Followed, at date: Date) {
        guard config.enabled, let light, let context = moment?.context else { return }
        if estimate {
            let nits = pow(10, followed.preference.value(at: light, in: context))
            followed.offset = followed.level - followed.levels.setting(nits: nits)
            return
        }
        let wanted = followed.levels.setting(nits: pow(10, followed.preference.value(at: light, in: context)))
        if Learned.censored(followed.level, wanted: wanted, range: 0...1) {
            log("\(followed.screen.name): \(followed.level > 0.5 ? "full" : "at its lowest"), as the light asks: nothing to learn")
            return
        }
        let setting = min(max(followed.level - followed.offset, 0), 1)
        let nits = followed.levels.nits(setting)
        followed.preference.learn(x: light, value: log10(nits), context: context, at: date, setting: setting, mode: followed.screen.mode)
        state.displays[followed.screen.key, default: Stored()].brightness = followed.preference.adjustments
        save(state)
        refreshPriors(after: followed.screen.key)
        log("\(followed.screen.name): learnt \(Int((setting * 100).rounded()))% (\(Int(nits.rounded())) nits) at \(lux(light)) lux, "
            + describe(context))
    }

    /// One DDC step per tick towards the learnt contrast, once it's 2 away; a
    /// change made with the monitor's buttons is learnt.
    private func followContrast(_ followed: Followed, _ light: Double, _ context: Context, quiet: Bool, date: Date) {
        guard let current = followed.screen.contrast, current.max > 0 else { return }
        let key = followed.screen.key
        if followed.contrast == nil {
            let base = state.displays[key]?.contrastBase ?? current.value
            if state.displays[key]?.contrastBase == nil {
                state.displays[key, default: Stored()].contrastBase = current.value
                save(state)
            }
            followed.contrast = Preference(prior: { _ in Double(base) }, adjustments: state.displays[key]?.contrast ?? [], settings: .contrast)
        }
        guard let expected = followed.expectedContrast else { return followed.expectedContrast = current.value }
        if current.value != expected {
            // Set with the monitor's buttons
            followed.expectedContrast = current.value
            followed.followingContrast = false
            if quiet, !estimate {
                followed.contrast?.learn(x: light, value: Double(current.value), context: context, at: date)
                state.displays[key, default: Stored()].contrast = followed.contrast?.adjustments ?? []
                save(state)
                log("\(followed.screen.name): learnt contrast \(current.value) at \(lux(light)) lux, \(describe(context))")
            }
            return
        }
        guard let wanted = followed.contrast?.value(at: light, in: context), wanted.isFinite else { return }
        let goal = min(max(Int(wanted.rounded()), 0), current.max)
        guard goal != current.value, followed.followingContrast || abs(goal - current.value) >= 2 else {
            followed.followingContrast = false
            return
        }
        followed.followingContrast = true
        let next = current.value + (goal > current.value ? 1 : -1)
        followed.expectedContrast = next
        followed.screen.setContrast(next)
    }

    /// Night Warmth's white for now, set when it moves, and once a minute in
    /// case something else reset it.
    private func setWhite(at date: Date) {
        guard let moment else { return }
        white = config.nightWarmth
            ? Warmth.white(strength: warmth.value(at: moment.schedule.warmthPhase(at: date), in: moment.context),
                           scheduled: moment.schedule.white(at: date))
            : NightSchedule.day
        guard let whiteOutput else { return }
        if whiteSet.map({ abs(mireds($0) - mireds(white)) >= 1 }) ?? true || date.timeIntervalSince(whiteAt) >= 60 {
            whiteOutput.setWhite(white)
            whiteSet = white
            whiteAt = date
        }
    }

    // MARK: What's learnt

    private func brightnessPreference(_ key: String) -> Preference {
        Learned.brightness(key, stored: state.displays, independent: independent)
    }

    /// After a screen's adjustments change, every other one's prior has too.
    private func refreshPriors(after key: String) {
        independent[key] = Learned.independent(key, stored: state.displays)
        for (other, followed) in followed where other != key { followed.preference = brightnessPreference(other) }
    }

    private func describe(_ context: Context) -> String {
        let night = context.night >= 0.5 ? "night" : "day"
        return [night, context.app, context.dark ? "dark" : nil, context.battery ? "battery" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    private func lux(_ light: Double) -> Int { Int((pow(10, light) - 1).rounded()) }

    // MARK: Commands

    /// What `brilho <command>` asks of the running service; the reply is shown to the user.
    public func command(_ words: [String], at date: Date) -> String {
        guard let verb = words.first?.lowercased() else { return status(at: date) }
        let rest = Array(words.dropFirst())
        switch verb {
        case "status": return status(at: date)
        case "brighter", "dimmer": return step(rest, up: verb == "brighter", at: date)
        case "warmer", "cooler": return stepWarmth(up: verb == "warmer", at: date)
        case "pause": return setConfig { $0.enabled = false } ?? "Paused: brightness is left as it is"
        case "resume": return setConfig { $0.enabled = true } ?? "Following the light again"
        case "night-warmth":
            guard let on = rest.first.flatMap(Self.onOff) else { return "night-warmth on|off" }
            return setConfig { $0.nightWarmth = on } ?? "Night Warmth \(on ? "on" : "off")"
        case "location":
            guard rest.count == 2, let latitude = Double(rest[0]), let longitude = Double(rest[1]),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return "location LATITUDE LONGITUDE, in degrees" }
            return setConfig {
                $0.latitude = (latitude * 100).rounded() / 100
                $0.longitude = (longitude * 100).rounded() / 100
            } ?? "Sunsets worked out for \(String(format: "%.2f, %.2f", latitude, longitude))"
        case "wake":
            let parts = rest.first?.split(separator: ":").compactMap { Int($0) } ?? []
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return "wake HH:MM" }
            return setConfig { $0.wake = Double(parts[0] * 60 + parts[1]) } ?? "Waking at \(rest[0])"
        case "nits":
            return setNits(rest)
        case "forget":
            forget()
            return "Forgot every adjustment; calibrations stay"
        default:
            return "Unknown command \(verb)"
        }
    }

    private static func onOff(_ word: String) -> Bool? { ["on": true, "off": false][word.lowercased()] }

    /// nil when it's set; the message otherwise.
    private func setConfig(_ change: (inout Config) -> Void) -> String? {
        change(&config)
        saveConfig(config)
        for followed in followed.values { followed.target = followed.level } // from where they are
        return nil
    }

    /// The configuration file changed: what the service reads it into.
    public func reload(_ config: Config) {
        guard config != self.config else { return }
        self.config = config
        log("settings read again")
    }

    /// Brighter or dimmer by a sixteenth, like the Mac's keys, on the screens
    /// named (all of them otherwise): learnt as the user's own setting.
    private func step(_ names: [String], up: Bool, at date: Date) -> String {
        let chosen = names.isEmpty ? order.compactMap { followed[$0] } : order.compactMap { followed[$0] }.filter { followed in
            names.contains { followed.screen.key == $0 || followed.screen.name.lowercased().contains($0.lowercased()) }
        }
        guard !chosen.isEmpty else { return "No screen called \(names.joined(separator: " "))" }
        for followed in chosen {
            followed.pending = nil
            followed.level = min(max(((followed.level * 16).rounded() + (up ? 1 : -1)) / 16, 0), 1)
            followed.target = followed.level
            followed.expected = followed.level
            followed.steppedAt = date
            guard followed.screen.setBrightness(followed.level) else {
                failed(followed)
                continue
            }
            manual(followed, at: date)
        }
        return chosen.map { "\($0.screen.name): \(Int(($0.level * 100).rounded()))%" }.joined(separator: "\n")
    }

    private func stepWarmth(up: Bool, at date: Date) -> String {
        guard config.nightWarmth, let moment else { return "Night Warmth is off" }
        let scheduled = moment.schedule.white(at: date)
        guard let strength = Warmth.strength(of: white, scheduled: scheduled) else {
            return "Night Warmth isn't warming now: \(moment.schedule.phase(at: date))"
        }
        let next = min(max(strength + (up ? 0.15 : -0.15), 0), 2)
        warmth.learn(x: moment.schedule.warmthPhase(at: date), value: next, context: moment.context, at: date)
        state.warmth = warmth.adjustments
        save(state)
        setWhite(at: date)
        log("learnt warmth \(Int((next * 100).rounded()))% (\(Int(white)) K), \(describe(moment.context))")
        return "Warmth \(Int((next * 100).rounded()))%: \(Int(white)) K"
    }

    /// `nits SCREEN MIN MAX`: how many nits a screen gives at its lowest and its
    /// highest, from its specifications; in between it's taken as linear.
    private func setNits(_ words: [String]) -> String {
        guard words.count == 3, let low = Double(words[1]), let high = Double(words[2]), low > 0, high > low else {
            return "nits SCREEN MIN MAX"
        }
        guard let followed = order.compactMap({ followed[$0] }).first(where: {
            $0.screen.key == words[0] || $0.screen.name.lowercased().contains(words[0].lowercased())
        }) else { return "No screen called \(words[0])" }
        let points = stride(from: 0.0, through: 1, by: 0.05).map { Level(setting: $0, nits: low + (high - low) * $0) }
        followed.levels = Levels.kept(points)
        let key = followed.screen.key
        state.displays[key, default: Stored()].levels = (state.displays[key]?.levels ?? [:]).merging([followed.screen.mode: points]) { $1 }
        // Adjustments made at a setting get the nits it gives now
        let adjustments = (state.displays[key]?.brightness ?? []).map { adjustment -> Adjustment in
            guard adjustment.mode == followed.screen.mode, let setting = adjustment.setting else { return adjustment }
            var recalculated = adjustment
            recalculated.value = log10(followed.levels.nits(setting))
            return recalculated
        }
        state.displays[key, default: Stored()].brightness = adjustments
        save(state)
        followed.preference = brightnessPreference(key)
        refreshPriors(after: key)
        return "\(followed.screen.name): \(Int(low)) to \(Int(high)) nits"
    }

    /// Every adjustment, of brightness, contrast and warmth; calibrations stay.
    public func forget() {
        for key in state.displays.keys {
            state.displays[key]?.brightness = []
            state.displays[key]?.contrast = []
        }
        state.warmth = []
        save(state)
        warmth = Preference(prior: Warmth.prior, settings: .warmth)
        independent = [:]
        for (key, followed) in followed {
            followed.preference = brightnessPreference(key)
            followed.contrast = nil
        }
        log("adjustments forgotten")
    }

    /// Back to the screens' own white and the state kept: Brilho is stopping.
    public func stop() {
        whiteOutput?.reset()
        save(state)
    }

    // MARK: Status

    public func status(at date: Date) -> String {
        var lines: [String] = []
        let lightText = light.map { "\(lux($0)) lux" + (estimate ? " (no sensor reading: by the time of day)" : "") } ?? "no light yet"
        lines.append("Brilho: \(config.enabled ? "following the light" : "paused"), \(lightText)")
        if let moment {
            lines.append("Night Warmth: " + (config.nightWarmth ? "\(Int(white)) K, \(moment.schedule.phase(at: date))" : "off")
                + "; " + describe(moment.context))
        }
        for key in order {
            guard let followed = followed[key] else { continue }
            let setting = followed.screen.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "unknown"
            let nits = followed.screen.brightness.map { "\(Int(followed.levels.nits($0).rounded())) nits" } ?? ""
            let wanted = light.flatMap { light in moment.map { pow(10, followed.preference.value(at: light, in: $0.context)) } }
            lines.append("\(followed.screen.name) [\(key)]: \(setting) \(nits)"
                + (wanted.map { ", wants \(Int($0.rounded())) nits" } ?? "")
                + ", \(followed.preference.adjustments.count) adjustments"
                + (followed.levels.calibrated ? "" : ", nits guessed")
                + (followed.screen.contrast.map { ", contrast \($0.value)/\($0.max)" } ?? ""))
        }
        if order.isEmpty { lines.append("No screens found") }
        return lines.joined(separator: "\n")
    }
}
