// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct Level: Codable, Equatable, Sendable {
    public var setting: Double
    public var nits: Double

    public init(setting: Double, nits: Double) {
        self.setting = setting
        self.nits = nits
    }
}

/// How a display's brightness setting (0...1) turns into nits, linear in
/// log(nits) between levels that were measured, calibrated by eye, or guessed.
public struct Levels: Sendable {
    public let points: [Level]
    public let calibrated: Bool

    public init(points: [Level], calibrated: Bool) {
        self.points = points
        self.calibrated = calibrated
    }

    /// The built-in panel until it's measured: a guess, measured on a 14-inch
    /// M2 Pro MacBook Pro (exponential in two pieces, kinked at 0.5).
    public static let builtinGuess = Levels(points: [
        (0.05, 2.4), (0.1, 3.45), (0.15, 5.61), (0.2, 9.12), (0.25, 14.82), (0.3, 24.09), (0.35, 39.15), (0.4, 63.62),
        (0.45, 103.38), (0.5, 168), (0.55, 184.47), (0.6, 203.18), (0.7, 248.56), (0.8, 307.09), (0.9, 382.6), (1, 480),
    ].map { Level(setting: $0.0, nits: $0.1) }, calibrated: false)

    /// An external display macOS dims itself, until it's measured: a guess,
    /// measured on a 400-nit monitor in HDR mode, where the setting is the SDR
    /// white level macOS puts in the signal.
    public static let nativeGuess = Levels(points: [
        (0, 4), (0.1, 7.38), (0.2, 12.35), (0.3, 20.03), (0.4, 31.87), (0.5, 50), (0.6, 77.6), (0.65, 96.35), (0.7, 119.4),
        (0.75, 147.68), (0.8, 182.36), (0.85, 224.82), (0.9, 276.76), (0.95, 340.23), (1, 417.71),
    ].map { Level(setting: $0.0, nits: $0.1) }, calibrated: false)

    /// A backlight over DDC, until it's calibrated: a guess, linear from 50 to
    /// 350 nits.
    public static let ddcGuess = Levels(points: stride(from: 0.0, through: 1, by: 0.05).map {
        Level(setting: $0, nits: 50 + 300 * $0)
    }, calibrated: false)

    /// A display dimmed in software, until it's calibrated: a guess, a 250-nit
    /// white scaled by the gamma table.
    public static let softwareGuess = Levels(points: stride(from: 0.0, through: 1, by: 0.05).map {
        Level(setting: $0, nits: 250 * softwareLight($0))
    }, calibrated: false)

    /// The share of its light a display dimmed in software keeps at a setting:
    /// never below 10%, past which the picture is lost before the light.
    public static func softwareLight(_ setting: Double) -> Double { 0.1 + 0.9 * min(max(setting, 0), 1) }

    /// Levels as kept: in order of setting, and more setting never giving less
    /// light (a level that came out dimmer is taken as just above the one before).
    public static func kept(_ levels: [Level]) -> Levels {
        var points = levels.sorted { $0.setting < $1.setting }
        for i in points.indices.dropFirst() { points[i].nits = max(points[i].nits, points[i - 1].nits * 1.01) }
        return Levels(points: points, calibrated: true)
    }

    public var minNits: Double { points[0].nits }
    public var maxNits: Double { points[points.count - 1].nits }

    /// The light at a setting. Past 1 it's the XDR boost, which multiplies the
    /// white of 1.
    public func nits(_ setting: Double) -> Double {
        if setting > 1 { return nits(1) * setting }
        return pow(10, interpolate(points.map { ($0.setting, log10($0.nits)) }, at: setting))
    }

    public func setting(nits: Double) -> Double {
        interpolate(points.map { (log10($0.nits), $0.setting) }, at: log10(max(nits, 1e-3)))
    }
}

/// The brightness every display starts from, as log10(nits) at light level
/// x = log10(lux + 1): 35 nits to read by in the dark, plus a part that grows
/// with the light, but more slowly than it (to the power 2/3), so a room ten
/// times as bright asks for 4.6 times the light: about 110 nits at 100 lux, 190
/// at 300 and 385 at 1000.
public func defaultLogNits(at x: Double) -> Double {
    log10(35 + 3.5 * pow(max(pow(10, x) - 1, 0), 2.0 / 3))
}

/// One step of a brightness transition, taken in log(nits) so that it looks
/// even across the range: 6% of the way (at 20 steps a second, most of the way
/// in about 2.5 s), never less than 0.002 decades. Settings that give the same
/// light (the bottom of some panels) are skipped.
public func rampStep(from level: Double, to target: Double, levels: Levels, fraction: Double = 0.06, minimum: Double = 0.002) -> Double {
    let from = log10(levels.nits(level)), to = log10(levels.nits(target))
    guard abs(to - from) > minimum else { return target }
    let next = levels.setting(nits: pow(10, from + (to > from ? 1 : -1) * max(abs(to - from) * fraction, minimum)))
    let towards = target > level ? next > level : next < level
    guard towards else { return target }
    return target > level ? min(next, target) : max(next, target)
}
