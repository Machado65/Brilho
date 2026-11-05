// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import BrilhoCore

let day = Context()
let night = Context(night: 1)

func prior(_ x: Double) -> Double { defaultLogNits(at: x) }

func isNonDecreasing(_ preference: Preference) -> Bool {
    let values = preference.curve.map(\.value)
    return zip(values, values.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 }
}

@Suite struct Learning {
    @Test func withoutCorrectionsItIsThePrior() {
        let preference = Preference(prior: prior)
        for x in stride(from: 0.0, through: 4.5, by: 0.25) { #expect(abs(preference.base(at: x) - prior(x)) < 1e-12) }
        // Linear between knots, flat beyond the range
        let mid = (prior(1) + prior(1.25)) / 2
        #expect(abs(preference.base(at: 1.125) - mid) < 1e-12)
        #expect(preference.base(at: 7) == preference.base(at: 4.5))
        #expect(preference.base(at: -1) == preference.base(at: 0))
        #expect(preference.value(at: 2, in: Context(night: 1, app: "a", dark: true, battery: true)) == preference.base(at: 2))
        #expect(preference.evidence == 0)
    }

    @Test(arguments: [0.0, 0.6, 1.3, 2.0, 2.71, 3.5, 4.5])
    func aCorrectionIsWhatItGivesBack(x: Double) {
        for shift in [-0.6, -0.2, 0.05, 0.3, 0.6] {
            var preference = Preference(prior: prior)
            preference.learn(x: x, value: prior(x) + shift, context: day)
            #expect(abs(preference.value(at: x, in: day) - (prior(x) + shift)) < 0.004 * abs(shift) + 1e-9)
        }
    }

    @Test func aCorrectionFadesWithDistance() {
        var preference = Preference(prior: prior)
        preference.learn(x: 2, value: prior(2) + 0.2, context: day)
        let effect = { (x: Double) in preference.base(at: x) - prior(x) }
        var last = effect(2)
        for x in stride(from: 2.25, through: 4.5, by: 0.25) {
            #expect(effect(x) < last && effect(x) > 0)
            last = effect(x)
        }
        last = effect(2)
        for x in stride(from: 1.75, through: 0, by: -0.25) {
            #expect(effect(x) < last && effect(x) > 0)
            last = effect(x)
        }
        // Half a decade of lux away it still mostly moves; two decades away, a third as much
        #expect(effect(1.5) > 0.6 * 0.2 && effect(2.5) > 0.6 * 0.2)
        #expect(effect(4) < 0.4 * 0.2 && effect(0) < 0.4 * 0.2)
    }

    @Test func nearbyCorrectionsReplaceEachOther() {
        var preference = Preference(prior: prior)
        preference.learn(x: 2, value: 2.3, context: day)
        preference.learn(x: 2.1, value: 2.1, context: day)
        #expect(preference.adjustments.count == 1)
        #expect(abs(preference.value(at: 2.1, in: day) - 2.1) < 0.002)
        // ...but not one made at night
        preference.learn(x: 2.05, value: 1.9, context: night)
        #expect(preference.adjustments.count == 2)
    }

    @Test func brightnessNeverFallsWithMoreLight() {
        var preference = Preference(prior: prior)
        preference.learn(x: 3, value: 2.0, context: day)
        preference.learn(x: 1, value: 2.4, context: day) // contradicts the one at x = 3, which goes
        #expect(preference.adjustments.count == 1)
        #expect(isNonDecreasing(preference))

        // Contradictions in different circumstances stay, and the curve stays monotonic
        var mixed = Preference(prior: prior)
        mixed.learn(x: 3, value: 2.0, context: Context(app: "a"))
        mixed.learn(x: 1, value: 2.4, context: Context(app: "b"))
        #expect(mixed.adjustments.count == 2)
        #expect(isNonDecreasing(mixed))
        #expect(abs(mixed.value(at: 1, in: Context(app: "b")) - 2.4) < 0.01) // the newest still holds
    }

    @Test func theNightIsLearntApart() {
        var preference = Preference(prior: prior)
        for x in [1.0, 2.0, 3.0] {
            preference.learn(x: x, value: prior(x) + 0.1, context: day)
            preference.learn(x: x + 0.05, value: prior(x + 0.05) - 0.15, context: night)
        }
        #expect(preference.effects.night < -0.18)
        #expect(abs(preference.value(at: 2, in: day) - (prior(2) + 0.1)) < 0.04)
        #expect(abs(preference.value(at: 2, in: night) - (prior(2) - 0.15)) < 0.04)
        // At dusk, half way
        let dusk = preference.value(at: 2, in: Context(night: 0.5))
        #expect(dusk < preference.value(at: 2, in: day) && dusk > preference.value(at: 2, in: night))
    }

    @Test func anAppIsLearntApart() {
        var preference = Preference(prior: prior)
        let video = Context(app: "video"), other = Context(app: "editor")
        for x in stride(from: 1.0, through: 3, by: 0.5) {
            preference.learn(x: x, value: prior(x) + 0.05, context: other)
            preference.learn(x: x + 0.2, value: prior(x + 0.2) + 0.25, context: video)
        }
        #expect(abs((preference.effects.apps["video"] ?? 0) - (preference.effects.apps["editor"] ?? 0) - 0.2) < 0.05)
        #expect(abs(preference.value(at: 2.1, in: video) - (prior(2.1) + 0.25)) < 0.04)
        #expect(abs(preference.value(at: 2.1, in: other) - (prior(2.1) + 0.05)) < 0.04)
        // An app never corrected in gets the base curve
        #expect(preference.value(at: 2, in: Context(app: "new")) == preference.base(at: 2))
    }

    @Test func oneCorrectionInAnAppMostlyMovesTheBase() {
        var preference = Preference(prior: prior)
        preference.learn(x: 2, value: prior(2) + 0.2, context: Context(app: "video"))
        let base = preference.base(at: 2) - prior(2), app = preference.effects.apps["video"]!
        #expect(base > 0.75 * 0.2)
        #expect(app > 0 && app < 0.25 * 0.2)
        #expect(abs(base + app - 0.2) < 0.001)
    }

    @Test func darkAndBatteryShifts() {
        var preference = Preference(prior: prior)
        for x in [1.0, 2.0, 3.0] {
            preference.learn(x: x, value: prior(x), context: day)
            preference.learn(x: x + 0.05, value: prior(x + 0.05) + 0.15, context: Context(dark: true))
            preference.learn(x: x + 0.1, value: prior(x + 0.1) - 0.15, context: Context(battery: true))
        }
        #expect(preference.effects.dark > 0.1)
        #expect(preference.effects.battery < -0.1)
        #expect(abs(preference.effects.night) < 0.03)
    }

    @Test func correctionsInOtherAppsStay() {
        var preference = Preference(prior: prior)
        preference.learn(x: 2, value: 2.3, context: Context(app: "a"))
        preference.learn(x: 2.02, value: 2.1, context: Context(app: "b"))
        #expect(preference.adjustments.count == 2)
        // What differs between them is the apps'
        #expect((preference.effects.apps["a"] ?? 0) > (preference.effects.apps["b"] ?? 0) + 0.1)
        #expect(abs(preference.value(at: 2.02, in: Context(app: "b")) - 2.1) < 0.001)
        #expect(preference.value(at: 2, in: Context(app: "a")) > 2.2)
    }

    @Test func aStrayCorrectionCountsLess() {
        // Six that agree, and one far off, in the same circumstances (as kept by an older version, say)
        var adjustments = [1.0, 1.5, 2.0, 2.5, 3.0, 3.5].map { Adjustment(x: $0, value: prior($0) + 0.1, date: .distantPast, context: day) }
        adjustments.insert(Adjustment(x: 2.25, value: prior(2.25) + 0.9, date: .distantPast, context: day), at: 0)
        let robust = Preference(prior: prior, adjustments: adjustments)
        let plain = Preference(prior: prior, adjustments: adjustments, settings: Preference.Settings(huber: .infinity))
        // It contradicts its neighbours (more light never asks for less), and holds them back less
        let consensus = { (fit: Preference, x: Double) in abs(fit.base(at: x) - prior(x) - 0.1) }
        #expect(consensus(robust, 2.0) <= consensus(plain, 2.0))
        #expect(consensus(robust, 2.25) < 0.7 * consensus(plain, 2.25))
        #expect(consensus(robust, 2.5) < 0.5 * consensus(plain, 2.5))
    }

    @Test func theNewestAlwaysHolds() {
        // Random corrections in random circumstances: right after each, the curve gives back what was chosen,
        // closer than the eye can tell (the panel's hysteresis is 0.012 decades)
        var random = SeededRandom(seed: 7)
        var preference = Preference(prior: prior)
        let apps = ["a", "b", "c", "d", nil]
        for _ in 0..<300 {
            let x = Double.random(in: 0...4.5, using: &random)
            let context = Context(night: [0, 0.5, 1].randomElement(using: &random)!, app: apps.randomElement(using: &random)!,
                                  dark: Bool.random(using: &random), battery: Bool.random(using: &random))
            let value = preference.value(at: x, in: context) + Double.random(in: -0.6...0.6, using: &random)
            preference.learn(x: x, value: value, context: context)
            #expect(abs(preference.value(at: x, in: context) - value) < 0.012)
            #expect(isNonDecreasing(preference))
        }
        #expect(preference.adjustments.count <= 96)
    }

    @Test func olderCountsLessOnlyAsNewerComeIn() {
        // Untouched for years, a correction counts in full
        let lone = Preference(prior: prior, adjustments: [Adjustment(x: 2, value: prior(2) + 0.2, date: .distantPast, context: day)])
        #expect(lone.evidence == 1)
        #expect(abs(lone.base(at: 2) - prior(2) - 0.2) < 0.001)
        // Thirty newer ones halve it
        let many = (0...30).map { Adjustment(x: Double($0) * 0.14, value: prior(Double($0) * 0.14), date: .distantPast, context: day) }
        let expected = (0...30).reduce(0.0) { $0 + pow(0.5, Double($1) / 30) }
        #expect(abs(Preference(prior: prior, adjustments: many).evidence - expected) < 1e-9)
    }

    @Test func nothingNotANumberGetsIn() {
        var preference = Preference(prior: prior)
        preference.learn(x: .nan, value: 2, context: day)
        preference.learn(x: 2, value: .infinity, context: day)
        preference.learn(x: 2, value: 2, context: Context(night: .nan))
        #expect(preference.adjustments.isEmpty)
        let kept = Preference(prior: prior, adjustments: [Adjustment(x: 1, value: .nan, date: Date(), context: day),
                                                          Adjustment(x: 2, value: 2.2, date: Date(), context: day)])
        #expect(kept.adjustments.count == 1 && kept.base(at: 3).isFinite)
    }

    @Test func keepsAtMostItsLimit() {
        var preference = Preference(prior: prior)
        for i in 0..<200 {
            preference.learn(x: Double(i % 30) * 0.15, value: 2, context: Context(night: Double(i % 3) / 2, app: "app\(i % 7)"))
        }
        #expect(preference.adjustments.count <= 96)
    }

    @Test func fitsInAFewSolves() {
        var random = SeededRandom(seed: 3)
        let adjustments = (0..<96).map { i in
            Adjustment(x: Double.random(in: 0...4.5, using: &random), value: Double.random(in: 1...2.7, using: &random), date: Date(),
                       context: Context(night: Double.random(in: 0...1, using: &random), app: "app\(i % 24)",
                                        dark: Bool.random(using: &random), battery: Bool.random(using: &random)))
        }
        let start = Date()
        let preference = Preference(prior: prior, adjustments: adjustments)
        let elapsed = Date().timeIntervalSince(start)
        print("worst-case fit: \(preference.solves) solves")
        #expect(isNonDecreasing(preference))
        // Random, contradictory corrections: the robust weights take all eight rounds, a few solves each (under 10 ms
        // in a release build). Tying knots one pair at a time instead of all at once would take several times as many
        #expect(preference.solves <= 48)
        // and nowhere near a time anyone would notice, even in a debug build on a slow machine running other tests
        #expect(elapsed < 2)
    }
}

@Suite struct OtherPreferences {
    @Test func contrastMayFallWithTheLight() {
        var contrast = Preference(prior: { _ in 70 }, settings: .contrast)
        contrast.learn(x: 1, value: 80, context: day)
        contrast.learn(x: 3, value: 60, context: day)
        #expect(contrast.adjustments.count == 2) // no monotonic contradiction
        #expect(abs(contrast.value(at: 1, in: day) - 80) < 0.5 && abs(contrast.value(at: 3, in: day) - 60) < 0.5)
    }

    @Test func contrastIgnoresBattery() {
        var contrast = Preference(prior: { _ in 70 }, settings: .contrast)
        contrast.learn(x: 2, value: 80, context: Context(battery: true))
        #expect(abs(contrast.effects.battery) < 1e-6)
    }

    @Test func warmthIsLearntAsAStrength() {
        var warmth = Preference(prior: Warmth.prior, settings: .warmth)
        // Less warm in the evening; the night itself, dark mode and battery don't come into it
        let evening = Context(night: 1, dark: true, battery: true)
        warmth.learn(x: 1, value: 0.6, context: evening)
        #expect(abs(warmth.value(at: 1, in: evening) - 0.6) < 0.001)
        #expect(abs(warmth.effects.night) < 1e-6 && abs(warmth.effects.dark) < 1e-6 && abs(warmth.effects.battery) < 1e-6)
        let night = warmth.value(at: 2, in: Context())
        #expect(night > 0.65 && night < 0.95) // the night follows some of the way

        // None in a photo editor, the schedule's elsewhere: told apart after one of each
        for phase in [1.0, 2.0] {
            warmth.learn(x: phase, value: 0, context: Context(app: "photos"))
            warmth.learn(x: phase, value: 1, context: Context(app: "mail"))
        }
        for phase in [1.0, 1.5, 2.0] {
            #expect(warmth.value(at: phase, in: Context(app: "photos")) < 0.15)
            #expect(abs(warmth.value(at: phase, in: Context(app: "mail")) - 1) < 0.15)
        }
    }

    @Test func strengthAndWhite() {
        #expect(Warmth.strength(of: 6500, scheduled: 6500) == nil) // nothing to scale by day
        #expect(abs(Warmth.strength(of: 3500, scheduled: 3500)! - 1) < 1e-12)
        #expect(abs(Warmth.strength(of: 6500, scheduled: 2000)!) < 1e-12)
        #expect(Warmth.strength(of: 9000, scheduled: 3500) == 0) // never bluer than D65
        for scheduled in [3500.0, 2800, 2000] {
            for strength in [0.0, 0.3, 1, 1.6] {
                let white = Warmth.white(strength: strength, scheduled: scheduled)
                #expect(white >= 1700 && white <= 6500)
                if white > 1700 { #expect(abs(Warmth.strength(of: white, scheduled: scheduled)! - strength) < 1e-9) }
            }
        }
        #expect(Warmth.white(strength: 1, scheduled: 3500) == 3500)
        #expect(Warmth.white(strength: 0, scheduled: 2000) == 6500)
        #expect(Warmth.white(strength: 2, scheduled: 2000) == 1700)
    }
}

@Suite struct SharedPrior {
    @Test func aNewDisplayStartsFromWhatTheOthersLearnt() {
        var builtin = Preference(prior: prior)
        for x in [0.5, 1.5, 2.5, 3.5] { builtin.learn(x: x, value: prior(x) + 0.2, context: day) }
        builtin.learn(x: 2, value: prior(2) + 0.1, context: Context(app: "video"))
        let untouched = Preference(prior: prior)
        let shared = Preference.shared(default: prior, from: [builtin, untouched])
        // An untouched display doesn't water it down; five corrections carry over five eighths
        let share = builtin.evidence / (builtin.evidence + 3)
        #expect(abs(builtin.evidence - 5) < 0.5)
        for x in [0.5, 1.5, 2.5, 3.5] { #expect(abs(shared.curve(x) - prior(x) - share * (builtin.base(at: x) - prior(x))) < 1e-9) }
        #expect(abs(shared.effects.apps["video"]! - share * builtin.effects.apps["video"]!) < 1e-9)

        let new = Preference(prior: shared.curve, priorEffects: shared.effects)
        #expect(abs(new.value(at: 1.5, in: day) - (prior(1.5) + share * 0.2)) < 0.03)
        #expect(new.effects.apps["video"] == shared.effects.apps["video"]) // an app only the prior knows of
    }

    @Test func moreCorrectionsCarryMoreOver() {
        func carried(_ count: Int) -> Double {
            let other = Preference(prior: prior, adjustments: (0..<count).map { i in
                let x = 1 + Double(i) * 2.5 / Double(count)
                return Adjustment(x: x, value: prior(x) + 0.2, date: Date(), context: day)
            })
            return (Preference.shared(default: prior, from: [other]).curve(2) - prior(2)) / (other.base(at: 2) - prior(2))
        }
        #expect(abs(carried(1) - 0.25) < 0.01)
        #expect(carried(3) > 0.45 && carried(10) > 0.7 && carried(30) > 0.85)
    }

    @Test func displaysCountByTheirEvidence() {
        var a = Preference(prior: prior), b = Preference(prior: prior)
        a.learn(x: 2, value: prior(2) + 0.3, context: day)
        for x in [1.6, 1.8, 2.0, 2.2, 2.4] { b.learn(x: x, value: prior(x) - 0.1, context: day) }
        let shared = Preference.shared(default: prior, from: [a, b])
        let expected = (a.evidence * (a.base(at: 2) - prior(2)) + b.evidence * (b.base(at: 2) - prior(2))) / (a.evidence + b.evidence + 3)
        #expect(abs(shared.curve(2) - prior(2) - expected) < 1e-9)
        #expect(shared.curve(2) < prior(2)) // b, with more to go on, wins
    }

    @Test func nothingLearntIsTheDefault() {
        let shared = Preference.shared(default: prior, from: [])
        #expect(shared.curve(2) == prior(2) && shared.effects == .none)
    }
}

@Suite struct Keeping {
    @Test func adjustmentsKeptBeforeCircumstancesStillDecode() throws {
        let json = #"[{"x":2,"value":2.1,"date":800000000,"setting":0.5,"mode":"builtin"}]"#
        let adjustments = try JSONDecoder().decode([Adjustment].self, from: Data(json.utf8))
        #expect(adjustments[0].context == nil)
        #expect(adjustments[0].setting == 0.5 && adjustments[0].mode == "builtin")
        let calendar = Calendar.current
        #expect(adjustments[0].circumstances.night == fixedNightness(adjustments[0].date, in: calendar))
    }

    @Test func storedRoundTrips() throws {
        var stored = Stored()
        stored.brightness = [Adjustment(x: 1, value: 2, date: Date(timeIntervalSince1970: 1_800_000_000), setting: 0.4, mode: "ddc",
                                        context: Context(night: 0.5, app: "com.apple.Safari", dark: true, battery: false))]
        stored.contrastBase = 58
        stored.levels = ["ddc": [Level(setting: 0, nits: 56), Level(setting: 1, nits: 366)]]
        stored.roomColour = true
        let decoded = try JSONDecoder().decode(Stored.self, from: JSONEncoder().encode(stored))
        #expect(decoded.brightness == stored.brightness)
        #expect(decoded.contrastBase == 58 && decoded.roomColour == true)
        #expect(decoded.levels?["ddc"] == stored.levels?["ddc"])
    }

    @Test func storedFromBeforeDecodes() throws {
        let json = #"{"brightness":[],"contrast":[{"x":1,"value":70,"date":800000000}],"contrastBase":80}"#
        let stored = try JSONDecoder().decode(Stored.self, from: Data(json.utf8))
        #expect(stored.contrast.count == 1 && stored.contrastBase == 80 && stored.levels == nil)
    }
}

/// SplitMix64: the same numbers every run.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func normal() -> Double {
        let u = Double.random(in: Double.ulpOfOne..<1, using: &self), v = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
