// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore
@testable import BrilhoEngine
import Foundation
import Testing

final class FakeLight: AmbientLight {
    var value: Double?
    init(_ value: Double?) { self.value = value }
    func lux() -> Double? { value }
}

/// A display whose hardware is a number: what Brilho sets, and what the user or the system set behind its back.
final class FakeScreen: Screen {
    let key: String, name: String, builtin: Bool, mode: String
    let guess: Levels
    let resolution: Double
    let stepInterval: TimeInterval
    let systemDims: Bool
    var hardware: Double?
    var writes = 0
    var contrastState: (value: Int, max: Int)?
    var refreshes = 0

    init(key: String = "builtin", name: String = "Panel", builtin: Bool = true, at level: Double? = 0.5) {
        self.key = key
        self.name = name
        self.builtin = builtin
        mode = builtin ? "builtin" : "ddc"
        guess = builtin ? .builtinGuess : .ddcGuess
        resolution = builtin ? 1.0 / 1000 : 0.01
        stepInterval = builtin ? 0.05 : 0.1
        systemDims = builtin
        hardware = level
    }

    var brightness: Double? { hardware }
    var refuses = false // no permission
    func setBrightness(_ setting: Double) -> Bool {
        guard !refuses else { return false }
        hardware = setting
        writes += 1
        return true
    }
    var contrast: (value: Int, max: Int)? { contrastState }
    func setContrast(_ value: Int) { contrastState?.value = value }
    func refresh() { refreshes += 1 }
}

final class FakeWhite: WhiteOutput {
    var white: Double?
    var resets = 0
    func setWhite(_ kelvin: Double) { white = kelvin }
    func reset() {
        resets += 1
        white = nil
    }
}

final class FakeSurroundings: Surroundings {
    var app: String?
    var dark = false
    var battery = false
    var idle: TimeInterval? = 0
    func context(night: Double) -> Context { Context(night: night, app: app, dark: dark, battery: battery) }
    func idleTime() -> TimeInterval? { idle }
}

func utc() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

func at(_ hour: Int, _ minute: Int = 0) -> Date {
    utc().date(from: DateComponents(year: 2026, month: 11, day: 5, hour: hour, minute: minute))!
}

/// An engine on fake hardware, run in steps of a twentieth of a second.
final class Rig {
    let light: FakeLight
    let screens: [FakeScreen]
    let white = FakeWhite()
    let surroundings = FakeSurroundings()
    var saved: State?
    var savedConfig: Config?
    var logs: [String] = []
    var date: Date
    var engine: Engine!

    init(screens: [FakeScreen] = [FakeScreen()], lux: Double? = 300, state: State = State(), config: Config = Config(), at date: Date = at(12)) {
        light = FakeLight(lux)
        self.screens = screens
        self.date = date
        engine = Engine(sensor: light, screens: screens, white: white, surroundings: surroundings, config: config, state: state,
                        calendar: utc(), save: { [unowned self] in self.saved = $0 }, saveConfig: { [unowned self] in self.savedConfig = $0 },
                        log: { [unowned self] in self.logs.append($0) })
    }

    func run(_ seconds: Double) {
        for _ in 0..<Int((seconds * 20).rounded()) {
            date += 0.05
            engine.update(at: date)
        }
    }

    var panel: FakeScreen { screens[0] }
}

/// The setting a screen's levels give the default curve's nits at a light.
func defaultSetting(_ lux: Double, _ levels: Levels = .builtinGuess) -> Double {
    levels.setting(nits: pow(10, defaultLogNits(at: log10(lux + 1))))
}

func decades(_ a: Double, _ b: Double, _ levels: Levels = .builtinGuess) -> Double {
    abs(log10(levels.nits(a)) - log10(levels.nits(b)))
}

@Suite struct FollowingTheLight {
    @Test func goesWhereTheLightSays() {
        let rig = Rig()
        rig.run(15)
        #expect(decades(rig.panel.hardware!, defaultSetting(300)) < 0.013)
        rig.light.value = 30
        rig.run(30)
        #expect(decades(rig.panel.hardware!, defaultSetting(30)) < 0.013)
        #expect(rig.saved == nil) // nothing learnt
    }

    @Test func smallChangesInTheLightLeaveItBe() {
        let rig = Rig()
        rig.run(15)
        let writes = rig.panel.writes
        rig.light.value = 306 // 2%: under what the eye notices
        rig.run(20)
        #expect(rig.panel.writes == writes)
    }

    @Test func pausedLeavesItAlone() {
        let rig = Rig()
        rig.run(15)
        #expect(rig.engine.command(["pause"], at: rig.date).contains("Paused"))
        #expect(rig.savedConfig?.enabled == false)
        let writes = rig.panel.writes
        rig.light.value = 3000
        rig.run(20)
        #expect(rig.panel.writes == writes)
        _ = rig.engine.command(["resume"], at: rig.date)
        rig.run(20)
        #expect(rig.panel.writes > writes)
    }

    @Test func withoutASensorItFollowsTheTimeOfDay() {
        let rig = Rig(lux: nil, at: at(23))
        rig.run(15)
        #expect(rig.engine.estimate)
        #expect(rig.engine.status(at: rig.date).contains("by the time of day"))
        // Late at night, a dim room's light: about 45 lux, a little more given the time it's been fading
        #expect(rig.panel.hardware! < defaultSetting(300))
    }
}

@Suite struct LearningFromTheUser {
    @Test func learnsWhatTheUserSetsAndKeepsIt() {
        let rig = Rig()
        rig.run(15)
        rig.panel.hardware = 0.85 // the desktop's brightness keys
        rig.run(3)
        #expect(rig.saved?.displays["builtin"]?.brightness.count == 1)
        rig.run(30)
        #expect(abs(rig.panel.hardware! - 0.85) < 0.01) // not fought back
        #expect(rig.logs.contains { $0.contains("learnt") })
    }

    @Test func theSystemsDimmingIsNotLearnt() {
        let rig = Rig()
        rig.run(15)
        let before = rig.panel.hardware!
        rig.surroundings.idle = 300 // no one at the keyboard: the desktop dims the screen
        rig.panel.hardware = 0.2
        rig.run(5)
        #expect(rig.saved == nil)
        rig.run(20)
        #expect(abs(rig.panel.hardware! - 0.2) < 0.01) // held while it lasts
        // Back at the keyboard, the desktop puts it back: undoing the dimming isn't learnt either
        rig.surroundings.idle = 0
        rig.panel.hardware = before
        rig.run(5)
        #expect(rig.saved == nil)
        rig.run(20)
        #expect(decades(rig.panel.hardware!, before) < 0.013)
    }

    @Test func aKeyPressedWhileItEasesIsTheUsersAndHolds() {
        let rig = Rig(screens: [FakeScreen(at: 0.1)])
        rig.run(1.5) // easing up towards the light's level
        #expect(rig.panel.hardware! > 0.1 && rig.panel.hardware! < defaultSetting(300) - 0.02)
        rig.panel.hardware = 0.9 // a brightness key, mid-way
        rig.run(4)
        #expect(abs(rig.panel.hardware! - 0.9) < 0.01)
        #expect(rig.saved?.displays["builtin"]?.brightness.count == 1)
    }

    @Test func fullInTheSunIsntLearnt() {
        // Put to full on its way there, with the light asking for more than the panel has: learnt, that would pull the
        // curve down to the panel's limit
        let rig = Rig(screens: [FakeScreen(at: 0.3)], lux: 13000)
        rig.run(1)
        #expect(rig.panel.hardware! < 0.98)
        rig.panel.hardware = 1
        rig.run(4)
        #expect(rig.saved?.displays["builtin"]?.brightness.isEmpty ?? true)
        #expect(rig.logs.contains { $0.contains("nothing to learn") })
        #expect(rig.panel.hardware == 1)
    }

    @Test func aScreenItCantSetIsntLearntFrom() {
        let rig = Rig()
        rig.panel.refuses = true
        rig.run(20)
        #expect(rig.panel.hardware == 0.5) // left as it was
        #expect(rig.saved == nil) // and that isn't the user's doing
        #expect(rig.logs.filter { $0.contains("couldn't set") }.count == 1)
    }

    @Test func aMonitorsButtonsAreAlwaysTheUsers() {
        let monitor = FakeScreen(key: "1507-9616-14488", name: "2590G4", builtin: false)
        let rig = Rig(screens: [monitor])
        rig.surroundings.idle = 600 // the keyboard isn't touched to press a monitor's buttons
        rig.run(15)
        monitor.hardware = min(monitor.hardware! + 0.2, 1)
        rig.run(3)
        #expect(rig.saved?.displays[monitor.key]?.brightness.count == 1)
        #expect(monitor.refreshes > 0) // asked again every 10 s while quiet
    }

    @Test func commandsStepAndLearn() {
        let rig = Rig()
        rig.run(15)
        let level = rig.panel.hardware!
        let reply = rig.engine.command(["brighter"], at: rig.date)
        #expect(abs(rig.panel.hardware! - (((level * 16).rounded() + 1) / 16)) < 1e-9)
        #expect(reply.contains("Panel"))
        #expect(rig.saved?.displays["builtin"]?.brightness.count == 1)
        #expect(rig.engine.command(["dimmer", "nothing"], at: rig.date).contains("No screen"))
    }

    @Test func whatsLearntOnOneScreenStartsAnother() {
        let monitor = FakeScreen(key: "1715-10209-536870912", name: "PA279CRV", builtin: false)
        let rig = Rig(screens: [FakeScreen(), monitor])
        rig.run(15)
        let before = monitor.hardware!
        // The panel set much brighter, three times at about this light
        for _ in 0..<3 {
            rig.panel.hardware = 0.95
            rig.run(3)
            rig.light.value = rig.light.value == 300 ? 250 : 300
            rig.run(10)
        }
        rig.run(20)
        #expect(monitor.hardware! > before + 0.02)
    }

    @Test func whatsLearntIsKeptAcrossRuns() {
        let rig = Rig()
        rig.run(15)
        rig.panel.hardware = 0.85
        rig.run(3)
        let again = Rig(state: rig.saved!)
        again.run(15)
        #expect(abs(again.panel.hardware! - 0.85) < 0.015)
    }

    @Test func forgetting() {
        let rig = Rig()
        rig.run(15)
        rig.panel.hardware = 0.85
        rig.run(3)
        #expect(rig.engine.command(["forget"], at: rig.date).contains("Forgot"))
        #expect(rig.saved?.displays["builtin"]?.brightness.isEmpty == true)
        // Started again from what's kept, it's back on the default curve
        let again = Rig(state: rig.saved!)
        again.run(15)
        #expect(decades(again.panel.hardware!, defaultSetting(300)) < 0.013)
    }
}

@Suite struct Contrast {
    @Test func aMonitorsContrastIsLearntAndFollowed() {
        let monitor = FakeScreen(key: "1507-9616-14488", name: "2590G4", builtin: false)
        monitor.contrastState = (58, 100)
        let rig = Rig(screens: [monitor])
        rig.run(15)
        #expect(rig.saved?.displays[monitor.key]?.contrastBase == 58)
        monitor.contrastState = (70, 100) // its buttons
        rig.run(2)
        #expect(rig.saved?.displays[monitor.key]?.contrast.count == 1)
        rig.run(20)
        #expect(monitor.contrastState?.value == 70) // kept at this light
    }
}

@Suite struct NightWarmthOnLinux {
    @Test func theNightIsWarmAndItsStrengthIsLearnt() {
        let rig = Rig(at: at(23, 30)) // after bedtime for someone waking at 7:30
        rig.run(2)
        #expect(abs(rig.white.white! - NightSchedule.night) < 1)
        let reply = rig.engine.command(["cooler"], at: rig.date)
        #expect(reply.contains("85%"))
        #expect(rig.saved?.warmth.count == 1)
        rig.run(2)
        #expect(rig.white.white! > NightSchedule.night + 100)
        _ = rig.engine.command(["night-warmth", "off"], at: rig.date)
        rig.run(2)
        #expect(rig.white.white == NightSchedule.day)
    }

    @Test func noWarmthToSetByDay() {
        let rig = Rig()
        rig.run(2)
        #expect(rig.white.white == NightSchedule.day)
        #expect(rig.engine.command(["warmer"], at: rig.date).contains("isn't warming now"))
    }

    @Test func stoppingPutsTheWhiteBack() {
        let rig = Rig(at: at(23, 30))
        rig.run(2)
        rig.engine.stop()
        #expect(rig.white.resets == 1)
    }
}

@Suite struct Settings {
    @Test func commandsSetTheConfiguration() {
        let rig = Rig()
        _ = rig.engine.command(["wake", "08:30"], at: rig.date)
        #expect(rig.savedConfig?.wake == 510)
        _ = rig.engine.command(["location", "38.7223", "-9.1393"], at: rig.date)
        #expect(rig.savedConfig?.latitude == 38.72 && rig.savedConfig?.longitude == -9.14)
        #expect(rig.engine.command(["location", "100", "0"], at: rig.date).contains("LATITUDE"))
        #expect(rig.engine.command(["wake", "25:00"], at: rig.date).contains("HH:MM"))
        #expect(rig.engine.command(["frobnicate"], at: rig.date).contains("Unknown"))
    }

    @Test func nitsFromTheSpecifications() {
        let monitor = FakeScreen(key: "1507-9616-14488", name: "2590G4", builtin: false)
        let rig = Rig(screens: [monitor])
        #expect(rig.engine.command(["nits", "2590", "40", "400"], at: rig.date).contains("40 to 400"))
        let levels = rig.saved?.displays[monitor.key]?.levels?["ddc"]
        #expect(levels?.first?.nits == 40 && levels?.last?.nits == 400)
    }

    @Test func screensComeAndGo() {
        let monitor = FakeScreen(key: "1507-9616-14488", name: "2590G4", builtin: false)
        let rig = Rig()
        rig.engine.setScreens([rig.panel, monitor])
        rig.run(2)
        #expect(rig.engine.status(at: rig.date).contains("2590G4"))
        rig.engine.setScreens([rig.panel])
        #expect(!rig.engine.status(at: rig.date).contains("2590G4"))
        #expect(rig.logs.contains { $0.contains("gone") })
    }
}
