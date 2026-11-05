// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore

/// How the preferences are made from what's kept, for the app and its diagnostics alike.
enum Learned {
    /// A display's brightness preference: its own adjustments, against what the
    /// other displays have learnt.
    static func brightness(_ key: String, stored: [String: Stored], independent: [String: Preference]) -> Preference {
        let shared = Preference.shared(default: defaultLogNits, from: independent.filter { $0.key != key }.map(\.value))
        return Preference(prior: shared.curve, priorEffects: shared.effects, adjustments: stored[key]?.brightness ?? [])
    }

    /// A display's brightness fitted against the default alone, for the others'
    /// priors: only from adjustments whose nits are known, the built-in
    /// display's, and the others' in a mode they've been calibrated in.
    static func independent(_ key: String, stored: [String: Stored]) -> Preference {
        let calibrated = Set(stored[key]?.levels?.keys.map { $0 } ?? [])
        let known = (stored[key]?.brightness ?? []).filter { key == "builtin" || calibrated.contains($0.mode ?? "") }
        return Preference(prior: defaultLogNits, adjustments: known)
    }
}
