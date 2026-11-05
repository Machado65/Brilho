// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Mireds (micro reciprocal degrees), the colour temperature scale on which
/// equal steps look equal.
public func mireds(_ kelvin: Double) -> Double { 1e6 / kelvin }

/// Linear RGB gains, none above 1, that move a D65 display's white to the
/// colour of a black body at `kelvin` (Kim et al.'s cubic fit of the Planckian
/// locus, through the sRGB primaries); 1, 1, 1 at 6500 K. Below about 2000 K
/// blue falls outside sRGB: none is as far as a display goes.
public func whiteGains(kelvin: Double) -> (Double, Double, Double) {
    func rgb(_ t: Double) -> (Double, Double, Double) {
        let x = t <= 4000
            ? -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        let y = t <= 2222 ? -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
            : t <= 4000 ? -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
            : 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        let (X, Z) = (x / y, (1 - x - y) / y)
        return (3.2406 * X - 1.5372 - 0.4986 * Z, -0.9689 * X + 1.8758 + 0.0415 * Z, 0.0557 * X - 0.2040 + 1.0570 * Z)
    }
    let kelvin = min(max(kelvin, 1667), 25000) // where the fit holds
    let (r, g, b) = rgb(kelvin), (r0, g0, b0) = rgb(6500)
    let gains = (max(r / r0, 0), max(g / g0, 0), max(b / b0, 0))
    let top = max(gains.0, gains.1, gains.2)
    return (gains.0 / top, gains.1 / top, gains.2 / top)
}

/// A display's white towards the room's, as an external display without True
/// Tone needs: a third of the way from D65 to the room's colour, never bluer
/// than D65 nor warmer than 5500 K, subtle enough for a monitor bought for its
/// colour.
public func roomWhite(_ roomKelvin: Double) -> Double {
    min(max(6500 - (6500 - roomKelvin) / 3, 5500), 6500)
}

/// Night Warmth's strength, which is what's learnt of the warmth a user
/// likes: the share of the schedule's warmth (its distance from D65, in
/// mireds) that they want; 0 is none (D65), 1 the schedule itself. By day
/// there's no warmth to take a share of, so the day's white is always D65.
public enum Warmth {
    /// As strong as the schedule.
    public static func prior(_: Double) -> Double { 1 }

    /// The strength a white is, against the schedule's at that moment; nil
    /// while the schedule has next to no warmth to scale (by day).
    public static func strength(of kelvin: Double, scheduled: Double) -> Double? {
        let warmth = mireds(scheduled) - mireds(NightSchedule.day)
        guard warmth > 10 else { return nil }
        return min(max((mireds(kelvin) - mireds(NightSchedule.day)) / warmth, 0), 2)
    }

    /// The white for a strength: never bluer than D65, nor warmer than 1700 K.
    public static func white(strength: Double, scheduled: Double) -> Double {
        let warmth = (mireds(scheduled) - mireds(NightSchedule.day)) * min(max(strength, 0), 2)
        return max(1e6 / (mireds(NightSchedule.day) + max(warmth, 0)), 1700)
    }
}
