// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import BrilhoCore

@Suite struct NightScheduleTests {
    let calendar = utc()
    // Lisbon (the city centre), waking at 8:30, so bedtime is 23:30, warming to night from 22:30; sunset in November ~17:30
    let lisbon = (latitude: 38.7223, longitude: -9.1393)

    func schedule(_ hour: Int, _ minute: Int = 0, location: (latitude: Double, longitude: Double)? = (38.7223, -9.1393),
                  wake: Double = 510) -> (NightSchedule, Date) {
        let when = date(2026, 11, 5, hour, minute, in: calendar)
        return (NightSchedule(when, location: location, wake: wake, calendar: calendar), when)
    }

    @Test func dayEveningAndNight() {
        func white(_ hour: Int, _ minute: Int = 0) -> Double { let (s, d) = schedule(hour, minute); return s.white(at: d) }
        #expect(white(12) == 6500)
        #expect(white(8, 30) == 6500)
        #expect(abs(white(19, 30) - 3500) < 1) // an hour after sunset
        #expect(abs(white(22, 0) - 3500) < 1)
        #expect(abs(white(23, 30) - 2000) < 1) // bedtime
        #expect(abs(white(3) - 2000) < 1)
        let dawn = white(8, 15) // half way back
        #expect(dawn > 2000 && dawn < 6500)
    }

    @Test func eveningsStartAtHalfPastSevenWithoutALocation() {
        let (at19, d19) = schedule(19, 0, location: nil)
        let (at2030, d2030) = schedule(20, 30, location: nil)
        #expect(at19.white(at: d19) == 6500)
        #expect(abs(at2030.white(at: d2030) - 3500) < 1)
        #expect(at19.phase(at: d19) == "Starts at 19:30")
    }

    @Test func movesSmoothlyAllDayForAnyWakingTime() {
        for wake in stride(from: 0.0, to: 1440, by: 90) {
            var last: Double?
            for minute in 0..<(24 * 60) {
                let when = date(2026, 11, 5, minute / 60, minute % 60, in: calendar)
                let schedule = NightSchedule(when, location: lisbon, wake: wake, calendar: calendar)
                let m = mireds(schedule.white(at: when))
                #expect(m >= mireds(6500) - 1e-9 && m <= mireds(2000) + 1e-9)
                // No jumps: never faster than the quickest change by design, 2000 K back to 6500 K over the half hour before waking
                if let last { #expect(abs(m - last) <= (mireds(2000) - mireds(6500)) / 30 + 1e-9) }
                last = m
                let night = schedule.nightness(at: when), phase = schedule.warmthPhase(at: when)
                #expect(night >= 0 && night <= 1 && phase >= 0 && phase <= 2)
            }
        }
    }

    @Test func nightnessFollowsTheUsersHours() {
        func night(_ hour: Int, _ minute: Int = 0) -> Double { let (s, d) = schedule(hour, minute); return s.nightness(at: d) }
        #expect(night(14) == 0)
        #expect(night(20, 30) == 0)
        #expect(abs(night(21, 30) - 0.5) < 1e-9)
        #expect(night(22, 30) == 1)
        #expect(night(4) == 1)
        #expect(abs(night(8, 30) - 0.5) < 1e-9)
        #expect(night(9) == 0)
    }

    @Test func warmthPhasesInOrder() {
        func phase(_ hour: Int, _ minute: Int = 0) -> Double { let (s, d) = schedule(hour, minute); return s.warmthPhase(at: d) }
        #expect(phase(12) == 0)
        #expect(abs(phase(20) - 1) < 1e-9)
        #expect(abs(phase(23, 30) - 2) < 1e-9)
        #expect(abs(phase(3) - 2) < 1e-9)
    }

    @Test func phaseTextsSayWhatComesNext() {
        let (s1, d1) = schedule(14)
        #expect(s1.phase(at: d1).hasPrefix("Starts at 17:"))
        let (s2, d2) = schedule(20)
        #expect(s2.phase(at: d2) == "Evening, warmer at 22:30")
        let (s3, d3) = schedule(1)
        #expect(s3.phase(at: d3) == "Night, until 08:00")
        let (s4, d4) = schedule(8, 10)
        #expect(s4.phase(at: d4) == "Morning")
    }

    @Test func summerEveningsComeLater() {
        // Sunset in Lisbon is at about 20:05 UTC in June, 17:25 in November
        let june = date(2026, 6, 21, 19, 30, in: calendar), november = date(2026, 11, 5, 19, 30, in: calendar)
        #expect(NightSchedule(june, location: lisbon, wake: 510, calendar: calendar).white(at: june) == 6500)
        #expect(abs(NightSchedule(november, location: lisbon, wake: 510, calendar: calendar).white(at: november) - 3500) < 1)
    }

    @Test func fixedNightnessForOldAdjustments() {
        #expect(fixedNightness(date(2026, 1, 1, 12, 0, in: calendar), in: calendar) == 0)
        #expect(fixedNightness(date(2026, 1, 1, 2, 0, in: calendar), in: calendar) == 1)
        #expect(abs(fixedNightness(date(2026, 1, 1, 21, 30, in: calendar), in: calendar) - 0.5) < 1e-9)
    }
}
