// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How a display's preferences are made from what's kept, on any platform.
public enum Learned {
    /// A display's brightness preference: its own adjustments, against what the
    /// other displays have learnt. With `white`, an XDR display's SDR white in
    /// nits, the prior stays at or under it until the light is bright enough for
    /// the XDR boost (see `boost(at:top:)`): only the user's own corrections
    /// take it past sooner.
    public static func brightness(_ key: String, stored: [String: Stored], independent: [String: Preference],
                                  white: Double? = nil, boostTop: Double = 2) -> Preference {
        let shared = Preference.shared(default: defaultLogNits, from: independent.filter { $0.key != key }.map(\.value))
        var prior = shared.curve
        if let white {
            let curve = shared.curve
            prior = { x in min(curve(x), log10(white * boost(at: x, top: boostTop))) }
        }
        return Preference(prior: prior, priorEffects: shared.effects, adjustments: stored[key]?.brightness ?? [])
    }

    /// How far past its SDR white an XDR display's prior goes, as a factor of
    /// it, by the light x = log10(lux + 1): not at all up to 5000 lux, so bright
    /// rooms and shade stay in SDR, then evenly in log light and log nits up to
    /// `top` at 30 000 lux, direct sun.
    public static func boost(at x: Double, top: Double) -> Double {
        let from = log10(5001.0), to = log10(30001.0)
        return pow(top, min(max((x - from) / (to - from), 0), 1))
    }

    /// A display's brightness fitted against the default alone, for the others'
    /// priors: only from adjustments whose nits are known, the built-in
    /// display's, and the others' in a mode they've been calibrated in.
    public static func independent(_ key: String, stored: [String: Stored]) -> Preference {
        let calibrated = Set(stored[key]?.levels?.keys.map { $0 } ?? [])
        let known = (stored[key]?.brightness ?? []).filter { key == "builtin" || calibrated.contains($0.mode ?? "") }
        return Preference(prior: defaultLogNits, adjustments: known)
    }

    /// Whether a brightness the user set only says "as far as it goes": at the
    /// top of the range when the curve already asked for that much or more (in
    /// the sun, say), or at the bottom when it asked for that little or less.
    /// Learnt, it would pull the curve back to the display's limit, the other
    /// way from what the user wanted, so it isn't. `wanted` is the setting the
    /// curve asks for, which may lie past the range.
    public static func censored(_ setting: Double, wanted: Double, range: ClosedRange<Double>) -> Bool {
        let margin = 0.002
        return (setting >= range.upperBound - margin && wanted >= range.upperBound - margin)
            || (setting <= range.lowerBound + margin && wanted <= range.lowerBound + margin)
    }
}
