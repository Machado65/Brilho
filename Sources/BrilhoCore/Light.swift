// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The ambient light as Brilho follows it, as a light level x = log10(lux + 1):
/// the median of the last five readings, against spikes (a hand passing over
/// the sensor, a phone screen lighting up near it), then eased towards with one
/// time constant when it brightens and another when it dims.
public struct LightFilter: Sendable {
    public private(set) var level: Double?
    private var recent: [Double] = []

    public init() {}

    @discardableResult
    public mutating func add(_ x: Double, interval: Double, rising: Double, falling: Double) -> Double {
        recent.append(x)
        if recent.count > 5 { recent.removeFirst() }
        let median = recent.sorted()[recent.count / 2]
        guard let level else {
            self.level = median
            return median
        }
        let next = level + (median - level) * (1 - exp(-interval / (median > level ? rising : falling)))
        self.level = next
        return next
    }
}

/// A stand-in for the light level, as log10(lux + 1), while the sensor is
/// covered (lid closed): a typical room by the time of day, 300 lux by day down
/// to 30 late at night.
public func scheduledLight(_ date: Date, in calendar: Calendar = .current) -> Double {
    let lux: [(hour: Double, lux: Double)] = [(0, 30), (7, 30), (9, 300), (18, 300), (21, 100), (24, 30)]
    return interpolate(lux.map { ($0.hour, log10($0.lux + 1)) }, at: hourOfDay(date, in: calendar))
}
