// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The day as Night Warmth and the preferences see it, laid out from the time
/// the user wakes: day until sunset; then the evening, its white reaching
/// 3500 K over the hour after sunset; then the night, reaching 2000 K over the
/// hour before bedtime (nine hours before waking); and back to daylight over
/// the half hour before waking. Without a location, evenings start at 19:30.
public struct NightSchedule: Sendable {
    public static let day = 6500.0
    public static let evening = 3500.0
    public static let night = 2000.0
    /// Bedtime, in minutes since waking.
    public static let bedtime = 1440 - 9 * 60.0

    private let wake: Double
    private let dusk: Double
    private let calendar: Calendar

    /// `wake` in minutes after midnight.
    public init(_ date: Date, location: (latitude: Double, longitude: Double)?, wake: Double, calendar: Calendar = .current) {
        self.wake = wake
        self.calendar = calendar
        let start = location.flatMap { sunset(on: date, latitude: $0.latitude, longitude: $0.longitude, in: calendar) } ?? 19.5 * 60
        dusk = min(Self.since(start, wake), Self.bedtime - 120)
    }

    /// The white point, in kelvin; between points it moves in mireds, which is
    /// how the eye takes colour temperature.
    public func white(at date: Date) -> Double {
        1e6 / interpolate(timeline([Self.day, Self.day, Self.evening, Self.evening, Self.night, Self.night, Self.day].map { 1e6 / $0 }),
                          at: minutes(date))
    }

    /// Where in its colours the day is: 0 by day, 1 in the evening, 2 at night,
    /// in between on the way; what the warmth a user prefers is learnt against.
    public func warmthPhase(at date: Date) -> Double {
        interpolate(timeline([0, 0, 1, 1, 2, 2, 0]), at: minutes(date))
    }

    /// How far into the user's night it is, for the brightness they prefer: 0
    /// from half an hour after waking until three hours before bedtime, 1 from
    /// an hour before bedtime until half an hour before waking.
    public func nightness(at date: Date) -> Double {
        interpolate([(0, 0.5), (30, 0), (Self.bedtime - 180, 0), (Self.bedtime - 60, 1), (1410, 1), (1440, 0.5)], at: minutes(date))
    }

    /// What Night Warmth is doing, and what comes next, for the panel.
    public func phase(at date: Date) -> String {
        switch minutes(date) {
        case ..<dusk: "Starts at \(clock(dusk))"
        case ..<(Self.bedtime - 60): "Evening, warmer at \(clock(Self.bedtime - 60))"
        case ..<1410: "Night, until \(clock(1410))"
        default: "Morning"
        }
    }

    /// The day's turning points, in minutes since waking, with a value each.
    private func timeline(_ values: [Double]) -> [(x: Double, y: Double)] {
        Array(zip([0, dusk, dusk + 60, Self.bedtime - 60, Self.bedtime, 1410, 1440], values))
    }

    private func minutes(_ date: Date) -> Double { Self.since(hourOfDay(date, in: calendar) * 60, wake) }

    private func clock(_ since: Double) -> String {
        let minute = (Int((since + wake).rounded()) % 1440 + 1440) % 1440
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private static func since(_ minute: Double, _ wake: Double) -> Double {
        let since = (minute - wake).truncatingRemainder(dividingBy: 1440)
        return since < 0 ? since + 1440 : since
    }
}

/// How much of the night a moment is in, for adjustments kept before the
/// schedule was: 0 from 8:00 to 20:00, 1 from 23:00 to 5:00.
public func fixedNightness(_ date: Date, in calendar: Calendar = .current) -> Double {
    interpolate([(0, 1), (5, 1), (8, 0), (20, 0), (23, 1), (24, 1)], at: hourOfDay(date, in: calendar))
}
