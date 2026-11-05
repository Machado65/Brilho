// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The circumstances an adjustment is made in, besides the light, which a
/// preference may come to depend on.
public struct Context: Codable, Equatable, Hashable, Sendable {
    /// 0 by day, 1 at night, by the user's own hours (NightSchedule.nightness).
    public var night: Double
    /// The app in front, by bundle identifier.
    public var app: String?
    /// The system in its dark appearance.
    public var dark: Bool
    /// On battery power.
    public var battery: Bool

    public init(night: Double = 0, app: String? = nil, dark: Bool = false, battery: Bool = false) {
        self.night = night
        self.app = app
        self.dark = dark
        self.battery = battery
    }

    /// Whether these are much the same circumstances as the other's.
    func alike(_ other: Context) -> Bool {
        abs(night - other.night) < 0.5 && dark == other.dark && battery == other.battery && app == other.app
    }
}

/// One correction the user made: at light level x, they wanted `value`.
public struct Adjustment: Codable, Equatable, Sendable {
    public var x: Double
    public var value: Double
    public var date: Date
    /// Brightness only: the setting and display mode it was made at, so that
    /// its nits can be worked out again when the display is calibrated.
    public var setting: Double?
    public var mode: String?
    /// nil in adjustments kept before the circumstances were; their night is
    /// then worked out from the date, by fixed hours.
    public var context: Context?

    public init(x: Double, value: Double, date: Date, setting: Double? = nil, mode: String? = nil, context: Context? = nil) {
        self.x = x
        self.value = value
        self.date = date
        self.setting = setting
        self.mode = mode
        self.context = context
    }

    var circumstances: Context { context ?? Context(night: fixedNightness(date)) }
}

/// How the circumstances shift a preference, on top of its curve over the light.
public struct Effects: Equatable, Sendable {
    public var night = 0.0
    public var dark = 0.0
    public var battery = 0.0
    public var apps: [String: Double] = [:]

    public static let none = Effects()

    public init(night: Double = 0, dark: Double = 0, battery: Double = 0, apps: [String: Double] = [:]) {
        self.night = night
        self.dark = dark
        self.battery = battery
        self.apps = apps
    }

    public func of(_ context: Context) -> Double {
        night * context.night + (context.dark ? dark : 0) + (context.battery ? battery : 0) + (context.app.flatMap { apps[$0] } ?? 0)
    }
}

/// How the user likes one thing (a display's brightness as log10(nits), its
/// contrast in DDC steps, or the warmth of the screens' white in mireds) as a
/// function of a coordinate x (the light level log10(lux + 1), or for warmth
/// the time of the evening) and of the circumstances.
///
/// It's a regularised regression of the user's corrections, small enough to
/// solve exactly every time one comes in: a curve through knots over x, each
/// pulled towards a prior curve and bending away from it only gradually, plus
/// one shift per circumstance (night, dark appearance, battery, and each app
/// corrected in), each held at its prior until the corrections disagree with
/// one another in a way only it explains. A correction counts less as newer
/// ones come in (half as much after 30), not as time passes, so a curve that
/// needs no more correcting is never forgotten; and one far from the rest
/// counts linearly rather than squared (Huber), so a stray one can't drag the
/// curve, though the newest always counts in full: what the user just chose
/// is what they get. Brightness is also kept monotonic: more light never asks
/// for less.
public struct Preference: Sendable {
    public struct Settings: Sendable {
        /// The range of x and the spacing of the curve's knots over it.
        var lower = 0.0, upper = 4.5, spacing = 0.25
        /// More x never asks for less.
        var monotone = true
        /// The weight of a correction, against...
        var weight = 20.0
        /// (the newest's is this many times as much: the curve passes through
        /// what the user just chose, whatever the others say)
        var latest = 1000.0
        /// ...staying on the prior curve,...
        var ridge = 0.04
        /// ...bending away from it suddenly,...
        var smoothness = 1.0
        /// ...and moving each shift from its prior.
        var nightRidge = 1.0, appRidge = 4.0, darkRidge = 4.0, batteryRidge = 4.0
        /// The number of newer corrections that halve one's weight.
        var halfLife = 30.0
        /// Past this miss a correction counts linearly, in the units of value.
        var huber = 0.15
        /// Corrections kept, the oldest dropped first.
        var limit = 96

        /// Held: a shift no circumstance should bring.
        static let held = 1e9

        public static let brightness = Settings()
        /// Battery life is the backlight's, not the contrast's.
        public static let contrast = Settings(monotone: false, batteryRidge: held, huber: 8)
        /// Night Warmth's strength (see Warmth), over the evening's phases (0
        /// day, 1 evening, 2 night), so the night shift is the phase itself: a
        /// knot each for the day, the evening and the night, with the changes
        /// between them in between, as Night Warmth makes them, half of an
        /// evening's correction carried to the night. An app is as likely a
        /// reason as any (none for photos), so half goes to it.
        public static let warmth = Settings(lower: 0, upper: 2, spacing: 1, monotone: false, smoothness: 0.04, nightRidge: held,
                                            appRidge: 0.08, darkRidge: held, batteryRidge: held, huber: 0.3)
    }

    public let settings: Settings
    public private(set) var adjustments: [Adjustment]
    public private(set) var effects: Effects
    private let prior: [Double]
    private let priorEffects: Effects
    private var fitted: [Double]
    /// The linear solves the last fit took, which the tests hold to a few.
    private(set) var solves = 0

    /// `prior` is the curve corrections are measured against, and
    /// `priorEffects` the shifts each starts from: another display's, say.
    public init(prior curve: (Double) -> Double, priorEffects: Effects = .none, adjustments: [Adjustment] = [],
                settings: Settings = .brightness) {
        self.settings = settings
        let knots = Int(((settings.upper - settings.lower) / settings.spacing).rounded()) + 1
        prior = (0..<knots).map { curve(settings.lower + Double($0) * settings.spacing) }
        self.priorEffects = priorEffects
        self.adjustments = adjustments.filter { $0.x.isFinite && $0.value.isFinite && $0.circumstances.night.isFinite }
        effects = priorEffects
        fitted = prior
        fit()
    }

    /// The fitted curve, knot by knot.
    public var curve: [(x: Double, value: Double)] {
        fitted.indices.map { (settings.lower + Double($0) * settings.spacing, fitted[$0]) }
    }

    /// How much the corrections count for, all told, in corrections at full
    /// weight (the newest counted as one).
    public var evidence: Double {
        adjustments.isEmpty ? 0 : (weights().reduce(0, +) - settings.weight * (settings.latest - 1)) / settings.weight
    }

    /// The curve over x alone, without the circumstances.
    public func base(at x: Double) -> Double {
        let (i, t) = cell(x)
        return fitted[i] * (1 - t) + fitted[i + 1] * t
    }

    public func value(at x: Double, in context: Context) -> Double { base(at: x) + effects.of(context) }

    /// A correction replaces those made at about the same light in like
    /// circumstances, and, for a monotonic preference, those it now contradicts.
    /// One made in another app stays: what differs between them is the apps'.
    public mutating func learn(x: Double, value: Double, context: Context, at date: Date = Date(),
                               setting: Double? = nil, mode: String? = nil) {
        guard x.isFinite, value.isFinite, context.night.isFinite else { return } // kept for good, so never a NaN
        adjustments.removeAll { old in
            guard old.circumstances.alike(context) else { return false }
            return abs(old.x - x) < 0.15 || settings.monotone && ((old.x < x && old.value > value) || (old.x > x && old.value < value))
        }
        adjustments.append(Adjustment(x: x, value: value, date: date, setting: setting, mode: mode, context: context))
        if adjustments.count > settings.limit { adjustments.removeFirst(adjustments.count - settings.limit) }
        fit()
    }

    /// Each correction's weight: halved by every 30 newer ones (adjustments are
    /// kept oldest first), the newest's raised.
    private func weights() -> [Double] {
        adjustments.indices.map { i in
            let newer = Double(adjustments.count - 1 - i)
            return settings.weight * pow(0.5, newer / settings.halfLife) * (newer == 0 ? settings.latest : 1)
        }
    }

    private func cell(_ x: Double) -> (Int, Double) {
        let position = min(max((x - settings.lower) / settings.spacing, 0), Double(prior.count - 1))
        let i = min(Int(position), prior.count - 2)
        return (i, position - Double(i))
    }

    /// Minimises, over the knot values v and the shifts s, the weighted (Huber)
    /// misses on the corrections + ridge·(v - prior)² + smoothness·(change in
    /// v - prior between neighbouring knots)² + Σ ridge_s·(s - prior_s)², by
    /// iteratively reweighted least squares; for a monotonic preference, knots
    /// that come out decreasing are tied together and it's solved again.
    private mutating func fit() {
        solves = 0
        let n = prior.count
        let apps = Array(Set(adjustments.compactMap { $0.context?.app })).sorted()
        let night = n, dark = n + 1, battery = n + 2, firstApp = n + 3
        let m = firstApp + apps.count

        var a = [Double](repeating: 0, count: m * m), b = [Double](repeating: 0, count: m)
        for k in 0..<n {
            a[k * m + k] += settings.ridge
            b[k] += settings.ridge * prior[k]
        }
        for k in 1..<n {
            let slope = prior[k] - prior[k - 1], s = settings.smoothness
            a[k * m + k] += s
            a[(k - 1) * m + k - 1] += s
            a[k * m + k - 1] -= s
            a[(k - 1) * m + k] -= s
            b[k] += s * slope
            b[k - 1] -= s * slope
        }
        func anchor(_ i: Int, _ strength: Double, at value: Double) {
            a[i * m + i] += strength
            b[i] += strength * value
        }
        anchor(night, settings.nightRidge, at: priorEffects.night)
        anchor(dark, settings.darkRidge, at: priorEffects.dark)
        anchor(battery, settings.batteryRidge, at: priorEffects.battery)
        for (j, app) in apps.enumerated() { anchor(firstApp + j, settings.appRidge, at: priorEffects.apps[app] ?? 0) }

        let rows = zip(adjustments, weights()).map { adjustment, weight -> (terms: [(Int, Double)], y: Double, weight: Double) in
            let context = adjustment.circumstances
            let (i, t) = cell(adjustment.x)
            var terms = [(i, 1 - t), (i + 1, t)]
            if context.night != 0 { terms.append((night, context.night)) }
            if context.dark { terms.append((dark, 1)) }
            if context.battery { terms.append((battery, 1)) }
            if let app = context.app, let j = apps.firstIndex(of: app) { terms.append((firstApp + j, 1)) }
            return (terms, adjustment.value, weight)
        }

        // Iteratively reweighted: each correction's weight is cut by how far
        // the last fit missed it, past `huber`, until the weights settle
        var robust = [Double](repeating: 1, count: rows.count)
        var values = [Double]()
        for _ in 0..<8 {
            var ra = a, rb = b
            for (row, h) in zip(rows, robust) {
                let w = row.weight * h
                for (p, wp) in row.terms {
                    rb[p] += w * wp * row.y
                    for (q, wq) in row.terms { ra[p * m + q] += w * wp * wq }
                }
            }
            let solved = solveMonotone(ra, rb, knots: n)
            values = solved.values
            solves += solved.solves
            var next = rows.map { row in
                let miss = abs(row.y - row.terms.reduce(0) { $0 + $1.1 * values[$1.0] })
                return miss <= settings.huber ? 1 : settings.huber / miss
            }
            if !next.isEmpty { next[next.count - 1] = 1 } // the newest
            let settled = zip(next, robust).allSatisfy { abs($0 - $1) < 1e-3 }
            robust = next
            if settled { break }
        }
        fitted = Array(values[0..<n])
        // Apps only the prior knows of keep the prior's shift
        effects = Effects(night: values[night], dark: values[dark], battery: values[battery],
                          apps: priorEffects.apps.merging(apps.enumerated().map { ($1, values[firstApp + $0]) }) { $1 })
    }

    /// Solved, then for a monotonic preference every pair of neighbouring
    /// knots that comes out decreasing tied together, and solved again, until
    /// none do. (Groups are runs of knots in order, then each shift alone.)
    private func solveMonotone(_ a: [Double], _ b: [Double], knots n: Int) -> (values: [Double], solves: Int) {
        var groups = (0..<b.count).map { [$0] }
        var solves = 0
        while true {
            let values = solve(a, b, tying: groups)
            solves += 1
            guard settings.monotone else { return (values, solves) }
            var merged = false
            var g = 0
            while g + 1 < groups.count, groups[g + 1][0] < n {
                if values[groups[g].last!] > values[groups[g + 1][0]] + 1e-9 {
                    groups[g] += groups.remove(at: g + 1)
                    merged = true
                } else {
                    g += 1
                }
            }
            if !merged { return (values, solves) }
        }
    }

    /// The prior for one display, from what the others have learnt: the
    /// default curve moved by the others' departures from it, and their shifts,
    /// each display counting by its evidence, and all of them by how much
    /// there is: a correction on another display carries over a quarter of
    /// itself, ten of them three quarters. Each is fitted against the default
    /// alone, so nothing feeds back on itself.
    public static func shared(default curve: @escaping (Double) -> Double, from others: [Preference], shrink: Double = 3)
        -> (curve: (Double) -> Double, effects: Effects) {
        let weighted = others.map { ($0, $0.evidence) }.filter { $0.1 > 0 }
        let total = weighted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return (curve, .none) }
        let departures = weighted.map { other, weight in
            (other.curve.map { (x: $0.x, y: $0.value - curve($0.x)) }, weight / (total + shrink))
        }
        let shared = { (x: Double) in curve(x) + departures.reduce(0) { $0 + interpolate($1.0, at: x) * $1.1 } }
        func mean(_ shift: (Effects) -> Double) -> Double { weighted.reduce(0) { $0 + shift($1.0.effects) * $1.1 } / (total + shrink) }
        var apps: [String: Double] = [:]
        for app in Set(weighted.flatMap { $0.0.effects.apps.keys }) {
            let having = weighted.filter { $0.0.effects.apps[app] != nil }
            apps[app] = having.reduce(0) { $0 + $1.0.effects.apps[app]! * $1.1 } / (having.reduce(0) { $0 + $1.1 } + shrink)
        }
        return (shared, Effects(night: mean(\.night), dark: mean(\.dark), battery: mean(\.battery), apps: apps))
    }
}

/// What's kept per display: the corrections (brightness as log10(nits),
/// contrast in DDC steps), the contrast it had before Brilho first touched it,
/// which is where its contrast curve starts from, its levels by mode, and
/// whether its white follows the room.
public struct Stored: Codable, Sendable {
    public var brightness: [Adjustment] = []
    public var contrast: [Adjustment] = []
    public var contrastBase: Int?
    public var levels: [String: [Level]]?
    public var roomColour: Bool?

    public init() {}
}
