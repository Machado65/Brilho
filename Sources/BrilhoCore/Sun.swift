// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// When the sun sets, in minutes after local midnight in the calendar's time
/// zone, by NOAA's approximation (within a couple of minutes); nil where it
/// doesn't set or doesn't rise that day.
public func sunset(on date: Date, latitude: Double, longitude: Double, in calendar: Calendar = .current) -> Double? {
    let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
    let g = 2 * Double.pi / 365 * (day - 1)
    let equation = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
    let declination = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g) + 0.000907 * sin(2 * g)
        - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
    let lat = latitude * .pi / 180
    let cosHourAngle = cos(90.833 * .pi / 180) / (cos(lat) * cos(declination)) - tan(lat) * tan(declination)
    guard (-1...1).contains(cosHourAngle) else { return nil }
    let utc = 720 - 4 * (longitude - acos(cosHourAngle) * 180 / .pi) - equation
    return utc + Double(calendar.timeZone.secondsFromGMT(for: date)) / 60
}
