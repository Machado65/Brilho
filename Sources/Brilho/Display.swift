// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import BrilhoCore

/// One display, as Brilho drives it.
final class Display {
    /// How its brightness is set: by macOS (the built-in display, Apple's and
    /// HDR-mode externals), its backlight over DDC, or in software, scaling the
    /// gamma table, for a display that answers neither.
    enum Control: String { case native, ddc, software }

    let id: CGDirectDisplayID
    let key: String
    let added = Date()
    let builtin: Bool
    let control: Control
    var levels: Levels
    var brightness: Preference
    var contrast: Preference?
    var level: Double // the brightness setting, 0...1; above 1 the XDR boost on top of it
    var target: Double
    var dim = 1.0 // below a DDC display's lowest backlight, the share of the light the gamma table keeps
    var offset = 0.0 // the system's own dimming (on battery, when idle), or a manual hold with the lid closed
    var pending: (since: Date, value: Double, user: Bool)? // a change we didn't make, waiting to settle
    var ready: Bool // a DDC display's brightness arrives a moment after it does
    var sliding = false // brightness being set from the panel: hands off until the slider lets go
    var keyedAt: Date? // brightness keys pressed on it: learnt once they stop
    var adjustingContrast = false
    var followingContrast = false
    var polling = false
    var lastWrite = Date.distantPast // of a DDC value, so a read soon after isn't taken for the monitor's buttons
    var ddc: DDC?
    var gamma: GammaScale?
    var controls: [DDC.Control: (value: Int, max: Int)] = [:] // the ones the display answered for
    var hdr: Bool? // nil without HDR modes
    var roomColour = true
    var measurable = false // macOS knows its nits (Meter)

    /// macOS names a display a moment after it appears.
    var name: String { screen(id)?.localizedName ?? key }
    /// What its calibrations are kept under: the same display has different levels in HDR (native) and SDR (DDC).
    var mode: String { builtin ? "builtin" : control.rawValue }
    var backlight: Double { min(level, 1) }
    var nits: Double { (level > 1 ? levels.nits(1) * level : levels.nits(level)) * dim } // XDR multiplies SDR white

    init(id: CGDirectDisplayID, key: String, builtin: Bool, control: Control, levels: Levels, brightness: Preference, level: Double) {
        self.id = id
        self.key = key
        self.builtin = builtin
        self.control = control
        self.levels = levels
        self.brightness = brightness
        self.level = level
        target = level
        ready = control != .ddc
    }

    deinit { gamma?.reset() }

    /// The key a display's preferences are kept under: its vendor, model and serial number.
    static func key(_ id: CGDirectDisplayID) -> String {
        CGDisplayIsBuiltin(id) != 0 ? "builtin" : "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }
}

/// What a tick works from besides the light: Night Warmth's schedule for today,
/// and the circumstances, as the preferences see them.
struct Moment {
    var date: Date
    var schedule: NightSchedule
    var context: Context

    var phase: Double { schedule.warmthPhase(at: date) }
    var scheduledWhite: Double { schedule.white(at: date) }
}
