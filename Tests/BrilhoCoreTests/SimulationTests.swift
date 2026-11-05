// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import BrilhoCore

/// Someone using Brilho, with preferences only they know: their curve's
/// departure from the default, shifts for the circumstances, how precisely they
/// set the brightness, and how far off it has to be before they bother.
struct SyntheticUser {
    var offset: (Double) -> Double = { _ in 0 }
    var night = 0.0
    var apps: [String: Double] = [:]
    var dark = 0.0
    var battery = 0.0
    var noise = 0.03
    var tolerance = 0.08 // about 20% in the light: plainly too bright or too dim

    func wants(_ moment: Moment) -> Double {
        let context = moment.context
        return prior(moment.x) + offset(moment.x) + night * context.night + (context.app.flatMap { apps[$0] } ?? 0)
            + (context.dark ? dark : 0) + (context.battery ? battery : 0)
    }
}

struct Moment {
    var x: Double
    var context: Context
}

/// A day at the computer: an hour at a time from 8:00 to midnight, each in an
/// app, in the light of that hour (some of the day by a window), the dark
/// appearance on some days, on battery some of the time.
func dayOfUse(_ random: inout SeededRandom, apps: [String] = ["editor", "browser", "video", "reader"]) -> [Moment] {
    let dark = Double.random(in: 0..<1, using: &random) < 0.3
    let unplugged = Int.random(in: 8...20, using: &random)
    return (8..<24).map { hour in
        let lux: Double = switch hour {
        case ..<18: Double.random(in: 0..<1, using: &random) < 0.12 ? exp(Double.random(in: log(3000)...log(20000), using: &random))
            : exp(Double.random(in: log(150)...log(1500), using: &random))
        case ..<22: exp(Double.random(in: log(30)...log(250), using: &random))
        default: exp(Double.random(in: log(3)...log(60), using: &random))
        }
        let night = interpolate([(8, 1), (9, 0), (20.5, 0), (22.5, 1), (24, 1)], at: Double(hour))
        let context = Context(night: night, app: apps.randomElement(using: &random), dark: dark,
                              battery: (unplugged..<unplugged + 3).contains(hour))
        return Moment(x: log10(lux + 1), context: context)
    }
}

/// Lives `days` days with the user, who corrects the brightness whenever it's
/// off by more than they put up with; returns the corrections made each day.
func live(_ days: Int, with user: SyntheticUser, _ preference: inout Preference, _ random: inout SeededRandom,
          ignoringCircumstances: Bool = false) -> [Int] {
    (0..<days).map { _ in
        var corrections = 0
        for moment in dayOfUse(&random) {
            let context = ignoringCircumstances ? Context() : moment.context
            guard abs(preference.value(at: moment.x, in: context) - user.wants(moment)) > user.tolerance else { continue }
            preference.learn(x: moment.x, value: user.wants(moment) + user.noise * random.normal(), context: context)
            corrections += 1
        }
        return corrections
    }
}

/// How far the curve is from what the user wants, as the root mean square in
/// decades of light, over moments the user lives through but that it hasn't seen.
func miss(_ preference: Preference, _ user: SyntheticUser, ignoringCircumstances: Bool = false) -> Double {
    var random = SeededRandom(seed: 999)
    let moments = (0..<40).flatMap { _ in dayOfUse(&random) }
    let squares = moments.map { moment in
        pow(preference.value(at: moment.x, in: ignoringCircumstances ? Context() : moment.context) - user.wants(moment), 2)
    }
    return (squares.reduce(0, +) / Double(squares.count)).squareRoot()
}

@Suite struct Simulation {
    /// Likes it brighter than the default in the dark and in daylight, dimmer at
    /// night, brighter for video, dimmer reading white pages and on battery.
    static let typical = SyntheticUser(offset: { 0.12 + 0.08 * sin($0 * 1.3) }, night: -0.12,
                                       apps: ["video": 0.1, "reader": -0.1], dark: 0.05, battery: -0.06)

    @Test(arguments: [1, 2, 3, 4, 5] as [UInt64])
    func learnsSomeoneWithinAFewWeeks(seed: UInt64) {
        var random = SeededRandom(seed: seed)
        var preference = Preference(prior: prior)
        let before = miss(preference, Self.typical)
        let corrections = live(30, with: Self.typical, &preference, &random)
        let after = miss(preference, Self.typical)
        let early = corrections.prefix(3).reduce(0, +), late = corrections.suffix(10).reduce(0, +)
        print("seed \(seed): miss \(before) -> \(after), corrections \(corrections), last fit \(preference.solves) solves")
        #expect(after < 0.06)
        #expect(after < before / 2.5)
        #expect(Double(late) / 10 < Double(early) / 3 / 2) // half as many a day, or fewer
        #expect(Double(late) / 10 < 1.5) // and rarely more than once a day
        #expect(isNonDecreasing(preference))
        #expect(preference.solves <= 8) // a real user's corrections agree: the weights settle at once
    }

    @Test(arguments: [11, 12, 13] as [UInt64])
    func theCircumstancesHelpWhenTheyMatter(seed: UInt64) {
        var a = SeededRandom(seed: seed), b = SeededRandom(seed: seed)
        var aware = Preference(prior: prior), blind = Preference(prior: prior)
        let awareCorrections = live(30, with: Self.typical, &aware, &a).reduce(0, +)
        let blindCorrections = live(30, with: Self.typical, &blind, &b, ignoringCircumstances: true).reduce(0, +)
        let awareMiss = miss(aware, Self.typical), blindMiss = miss(blind, Self.typical, ignoringCircumstances: true)
        print("seed \(seed): aware \(awareMiss) (\(awareCorrections) corrections), light alone \(blindMiss) (\(blindCorrections))")
        #expect(awareMiss < 0.8 * blindMiss)
        #expect(awareCorrections < blindCorrections)
    }

    @Test(arguments: [21, 22, 23] as [UInt64])
    func noWorseWhenTheyDont(seed: UInt64) {
        // Someone who only cares about the light, and sets it a little loosely: the shifts mustn't learn noise
        let user = SyntheticUser(offset: { 0.1 - 0.05 * $0 / 4.5 }, noise: 0.05)
        var a = SeededRandom(seed: seed), b = SeededRandom(seed: seed)
        var aware = Preference(prior: prior), blind = Preference(prior: prior)
        _ = live(30, with: user, &aware, &a)
        _ = live(30, with: user, &blind, &b, ignoringCircumstances: true)
        let awareMiss = miss(aware, user), blindMiss = miss(blind, user, ignoringCircumstances: true)
        print("seed \(seed): aware \(awareMiss), light alone \(blindMiss), shifts \(aware.effects)")
        #expect(awareMiss < blindMiss + 0.01)
        #expect(awareMiss < 0.06)
    }

    @Test(arguments: [31, 32] as [UInt64])
    func followsAChangeOfMind(seed: UInt64) {
        var random = SeededRandom(seed: seed)
        var preference = Preference(prior: prior)
        _ = live(20, with: Self.typical, &preference, &random)
        var changed = Self.typical
        changed.offset = { Self.typical.offset($0) + 0.15 } // new glasses, a new desk
        let corrections = live(14, with: changed, &preference, &random)
        print("seed \(seed): after the change \(miss(preference, changed)), corrections \(corrections)")
        #expect(miss(preference, changed) < 0.07)
        #expect(corrections.suffix(5).reduce(0, +) < corrections.prefix(3).reduce(0, +))
    }

    @Test func reloadingGivesTheSameCurve() {
        var random = SeededRandom(seed: 41)
        var preference = Preference(prior: prior)
        _ = live(20, with: Self.typical, &preference, &random)
        let data = try! JSONEncoder().encode(preference.adjustments)
        let reloaded = Preference(prior: prior, adjustments: try! JSONDecoder().decode([Adjustment].self, from: data))
        var check = SeededRandom(seed: 42)
        for moment in (0..<5).flatMap({ _ in dayOfUse(&check) }) {
            #expect(abs(reloaded.value(at: moment.x, in: moment.context) - preference.value(at: moment.x, in: moment.context)) < 1e-9)
        }
    }

    @Test func aSecondDisplayStartsCloser() {
        // The user's built-in display learnt for a month; a monitor is plugged in
        var random = SeededRandom(seed: 51)
        var builtin = Preference(prior: prior)
        _ = live(30, with: Self.typical, &builtin, &random)
        let shared = Preference.shared(default: prior, from: [builtin])
        let fresh = Preference(prior: prior), primed = Preference(prior: shared.curve, priorEffects: shared.effects)
        print("new display: \(miss(fresh, Self.typical)) from the default, \(miss(primed, Self.typical)) from the shared prior")
        #expect(miss(primed, Self.typical) < 0.7 * miss(fresh, Self.typical))
    }
}
