// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore
import Foundation

/// An ambient light sensor.
public protocol AmbientLight: AnyObject {
    /// The light in lux; nil while the sensor gives nothing.
    func lux() -> Double?
}

/// A display whose brightness Brilho sets.
public protocol Screen: AnyObject {
    /// What its preferences are kept under: "builtin" for a laptop's own panel, else its EDID's key.
    var key: String { get }
    var name: String { get }
    var builtin: Bool { get }
    /// What its calibrations are kept under: "builtin" or "ddc".
    var mode: String { get }
    /// How its settings turn into nits until it's told: a guess.
    var guess: Levels { get }
    /// Its smallest step, as a share of its range: a change by someone else is a bigger one.
    var resolution: Double { get }
    /// The shortest time between two brightness steps it takes well.
    var stepInterval: TimeInterval { get }
    /// Whether the system may change it by itself (a laptop's panel, dimmed when idle); a monitor's buttons
    /// are always the user's.
    var systemDims: Bool { get }
    /// Its brightness setting, 0...1, as last known (read live from a backlight; over DDC, as last set or read);
    /// nil until it's known.
    var brightness: Double? { get }
    /// false when it couldn't be set (no permission): what it reads then isn't the user's doing.
    @discardableResult func setBrightness(_ setting: Double) -> Bool
    /// Its contrast, for a display that has one, as last known.
    var contrast: (value: Int, max: Int)? { get }
    func setContrast(_ value: Int)
    /// Asks the display again, for what may have changed without Brilho (its own buttons).
    func refresh()
}

/// Every screen's white, for Night Warmth.
public protocol WhiteOutput: AnyObject {
    func setWhite(_ kelvin: Double)
    /// Back to the screens' own white, when Brilho stops.
    func reset()
}

/// What Brilho knows of the moment besides the light.
public protocol Surroundings: AnyObject {
    /// The app in front, the appearance and the power source, with how far into the night it is.
    func context(night: Double) -> Context
    /// Seconds since the keyboard or pointer was last used; nil where the platform won't say.
    func idleTime() -> TimeInterval?
}

/// What the user sets.
public struct Config: Codable, Equatable, Sendable {
    public var enabled = true
    public var nightWarmth = true
    public var latitude: Double?
    public var longitude: Double?
    /// When the user wakes, in minutes after midnight.
    public var wake = 7.5 * 60

    public init() {}
}

/// What Brilho learns, and keeps between runs.
public struct State: Codable, Sendable {
    public var displays: [String: Stored] = [:]
    public var warmth: [Adjustment] = []

    public init() {}
}
