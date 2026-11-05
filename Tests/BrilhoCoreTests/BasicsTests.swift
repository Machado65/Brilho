// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import BrilhoCore

func utc() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, in calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite struct Interpolation {
    @Test func flatBeyondTheEnds() {
        let points: [(x: Double, y: Double)] = [(0, 1), (1, 3), (3, 5)]
        #expect(interpolate(points, at: -5) == 1)
        #expect(interpolate(points, at: 9) == 5)
    }

    @Test func linearBetweenPoints() {
        let points: [(x: Double, y: Double)] = [(0, 1), (1, 3), (3, 5)]
        #expect(interpolate(points, at: 0.5) == 2)
        #expect(interpolate(points, at: 2) == 4)
        #expect(interpolate(points, at: 1) == 3)
    }

    @Test func solveTiesGroupsTogether() {
        // Two variables pulled to 1 and 3, tied: they meet at 2
        let tied = solve([[1, 0], [0, 1]], [1, 3], tying: [[0, 1]])
        #expect(abs(tied[0] - 2) < 1e-12 && abs(tied[1] - 2) < 1e-12)
        let free = solve([[2, 1], [1, 3]], [3, 5], tying: [[0], [1]])
        #expect(abs(free[0] - 0.8) < 1e-12 && abs(free[1] - 1.4) < 1e-12)
    }
}

struct PublishedSunset: Sendable, CustomTestStringConvertible {
    var zone: String
    var latitude: Double, longitude: Double
    var year: Int, month: Int, day: Int
    var hour: Int, minute: Int
    var testDescription: String { "\(zone) \(year)-\(month)-\(day)" }
}

@Suite struct Sunsets {
    /// Against published sunset times (timeanddate.com), within the approximation's few minutes.
    @Test(arguments: [
        PublishedSunset(zone: "Europe/London", latitude: 51.5074, longitude: -0.1278, year: 2026, month: 6, day: 21, hour: 21, minute: 21),
        PublishedSunset(zone: "America/New_York", latitude: 40.7128, longitude: -74.0060, year: 2026, month: 1, day: 1, hour: 16, minute: 39),
        PublishedSunset(zone: "Australia/Sydney", latitude: -33.8688, longitude: 151.2093, year: 2026, month: 12, day: 21, hour: 20, minute: 5),
        PublishedSunset(zone: "Atlantic/Reykjavik", latitude: 64.1466, longitude: -21.9426, year: 2026, month: 12, day: 21, hour: 15, minute: 30),
    ])
    func matchesPublishedTimes(_ published: PublishedSunset) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: published.zone)!
        let minutes = sunset(on: date(published.year, published.month, published.day, in: calendar),
                             latitude: published.latitude, longitude: published.longitude, in: calendar)
        #expect(minutes != nil)
        #expect(abs((minutes ?? 0) - Double(published.hour * 60 + published.minute)) < 6)
    }

    @Test func noneWhereTheSunNeverSetsOrRises() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        #expect(sunset(on: date(2026, 6, 21, in: calendar), latitude: 69.65, longitude: 18.96, in: calendar) == nil)
        #expect(sunset(on: date(2026, 12, 21, in: calendar), latitude: 69.65, longitude: 18.96, in: calendar) == nil)
    }
}

@Suite struct Colour {
    @Test func daylightIsNeutral() {
        let (r, g, b) = whiteGains(kelvin: 6500)
        #expect(abs(r - 1) < 1e-9 && abs(g - 1) < 1e-9 && abs(b - 1) < 1e-9)
    }

    @Test func warmerTakesBlueFirstAndNeverGoesOutOfRange() {
        var lastBlue = 1.0, lastGreen = 1.0
        for kelvin in stride(from: 6500.0, through: 1000, by: -100) {
            let (r, g, b) = whiteGains(kelvin: kelvin)
            #expect([r, g, b].allSatisfy { $0 >= 0 && $0 <= 1 && $0.isFinite })
            #expect(max(r, g, b) == 1)
            #expect(b <= lastBlue + 1e-9 && g <= lastGreen + 1e-9)
            #expect(b <= g + 1e-9)
            lastBlue = b
            lastGreen = g
        }
        #expect(whiteGains(kelvin: 2000).2 < 0.05) // blue near gone, as with any 2000 K source
    }

    @Test func roomWhiteIsSubtleAndBounded() {
        #expect(roomWhite(6500) == 6500)
        #expect(roomWhite(9000) == 6500) // never bluer
        #expect(abs(roomWhite(3500) - 5500) < 1e-9) // a third of the way, at the floor
        #expect(roomWhite(2000) == 5500)
        #expect(abs(roomWhite(5000) - 6000) < 1e-9)
    }
}

@Suite struct LevelsAndRamp {
    @Test func settingsAndNitsRoundTrip() {
        for levels in [Levels.builtinGuess, .nativeGuess, .ddcGuess, .softwareGuess] {
            for setting in stride(from: levels.points[0].setting, through: 1, by: 0.01) {
                #expect(abs(levels.setting(nits: levels.nits(setting)) - setting) < 1e-6)
            }
        }
    }

    @Test func keptLevelsAreSortedAndRising() {
        let kept = Levels.kept([Level(setting: 1, nits: 300), Level(setting: 0, nits: 50), Level(setting: 0.5, nits: 40)])
        #expect(kept.points.map(\.setting) == [0, 0.5, 1])
        #expect(kept.points[1].nits > kept.points[0].nits && kept.points[2].nits > kept.points[1].nits)
        #expect(kept.calibrated)
    }

    @Test func softwareLightNeverLosesThePicture() {
        #expect(Levels.softwareLight(0) == 0.1)
        #expect(Levels.softwareLight(1) == 1)
        #expect(Levels.softwareLight(-3) == 0.1 && Levels.softwareLight(3) == 1)
    }

    @Test func defaultCurve() {
        func nits(_ lux: Double) -> Double { pow(10, defaultLogNits(at: log10(lux + 1))) }
        #expect(abs(nits(0) - 35) < 0.01)
        #expect(abs(nits(100) - 110.4) < 0.5)
        #expect(abs(nits(300) - 191.9) < 0.5)
        #expect(abs(nits(1000) - 385) < 0.5)
        var last = 0.0
        for x in stride(from: 0.0, through: 5, by: 0.05) {
            #expect(defaultLogNits(at: x) > last)
            last = defaultLogNits(at: x)
        }
    }

    @Test(arguments: [(0.2, 0.9), (0.9, 0.2), (0.0, 1.0), (0.5, 0.5), (0.01, 0.04)])
    func rampReachesItsTargetWithoutOvershooting(from: Double, to: Double) {
        let levels = Levels.builtinGuess
        var level = from, steps = 0
        while level != to && steps < 400 {
            let next = rampStep(from: level, to: to, levels: levels)
            #expect(to > from ? next >= level && next <= to : next <= level && next >= to)
            level = next
            steps += 1
        }
        #expect(level == to)
        #expect(steps < 200) // under ten seconds at 20 steps a second
    }

    @Test func rampMovesEvenlyInLight() {
        // Each step moves the light by about the same factor, wherever in the range it is
        let levels = Levels.builtinGuess
        var level = 0.1
        var ratios: [Double] = []
        for _ in 0..<10 {
            let next = rampStep(from: level, to: 1, levels: levels)
            ratios.append(log10(levels.nits(next)) - log10(levels.nits(level)))
            level = next
        }
        // Successive steps shrink smoothly (6% of what's left), never jump
        for (a, b) in zip(ratios, ratios.dropFirst()) { #expect(b <= a * 1.0001 && b >= a * 0.9) }
    }
}

@Suite struct Light {
    @Test func aSpikeBarelyMovesIt() {
        var filter = LightFilter()
        for _ in 0..<20 { filter.add(log10(301), interval: 0.5, rising: 1.5, falling: 3) }
        let before = filter.level!
        filter.add(log10(20001), interval: 0.5, rising: 1.5, falling: 3)
        filter.add(log10(301), interval: 0.5, rising: 1.5, falling: 3)
        #expect(abs(filter.level! - before) < 1e-9)
    }

    @Test func followsARealChangeFasterUpThanDown() {
        var up = LightFilter(), down = LightFilter()
        for _ in 0..<10 {
            up.add(1, interval: 0.5, rising: 1.5, falling: 3)
            down.add(3, interval: 0.5, rising: 1.5, falling: 3)
        }
        for _ in 0..<6 {
            up.add(3, interval: 0.5, rising: 1.5, falling: 3)
            down.add(1, interval: 0.5, rising: 1.5, falling: 3)
        }
        let upProgress = (up.level! - 1) / 2, downProgress = (3 - down.level!) / 2
        #expect(upProgress > downProgress)
        for _ in 0..<40 {
            up.add(3, interval: 0.5, rising: 1.5, falling: 3)
            down.add(1, interval: 0.5, rising: 1.5, falling: 3)
        }
        #expect(abs(up.level! - 3) < 0.01 && abs(down.level! - 1) < 0.01)
    }

    @Test func scheduledLightByTheClock() {
        let calendar = utc()
        func lux(_ hour: Int) -> Double { pow(10, scheduledLight(date(2026, 11, 5, hour, 0, in: calendar), in: calendar)) - 1 }
        #expect(abs(lux(3) - 30) < 0.5)
        #expect(abs(lux(12) - 300) < 1)
        #expect(lux(20) < lux(12) && lux(20) > lux(23))
    }
}

@Suite struct DDCBytes {
    @Test func getRequestIsChecksummed() {
        #expect(DDCMessage.get(0x10) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test func setRequestCarriesTheValueBigEndian() {
        let message = DDCMessage.set(0x12, 0x0150)
        #expect(Array(message.prefix(5)) == [0x84, 0x03, 0x12, 0x01, 0x50])
        let body: [UInt8] = [0x84, 0x03, 0x12, 0x01, 0x50]
        #expect(message[5] == body.reduce(0x6E ^ 0x51, ^))
        #expect(Array(DDCMessage.set(0x10, -4).prefix(5)) == [0x84, 0x03, 0x10, 0, 0])
    }

    @Test func repliesAreReadOrRefused() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x3D, 0x00]
        #expect(DDCMessage.reply(reply, for: 0x10).map { [$0.value, $0.max] } == [61, 100])
        #expect(DDCMessage.reply(reply, for: 0x12) == nil) // another control's
        var unsupported = reply
        unsupported[3] = 1
        #expect(DDCMessage.reply(unsupported, for: 0x10) == nil)
        #expect(DDCMessage.reply(Array(reply.prefix(6)), for: 0x10) == nil)
    }

    @Test func edidNamesVendorAndProduct() {
        #expect(edidProduct("06B3E127-0000-0000-0A24-0103803C2278").map { [$0.vendor, $0.model] } == [0x06B3, 0x27E1])
        #expect(edidProduct("05E39025-0000-0000-2B1C-010380361E78").map { [$0.vendor, $0.model] } == [0x05E3, 0x2590])
        #expect(edidProduct("ZZ") == nil)
        #expect(edidProduct("GGGG0000") == nil)
    }
}
