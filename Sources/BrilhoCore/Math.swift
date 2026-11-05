// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Piecewise linear through points sorted by x, flat beyond them.
public func interpolate(_ points: [(x: Double, y: Double)], at x: Double) -> Double {
    guard x > points[0].x else { return points[0].y }
    for (p, q) in zip(points, points.dropFirst()) where x <= q.x {
        return p.y + (q.y - p.y) * (x - p.x) / (q.x - p.x)
    }
    return points[points.count - 1].y
}

/// The time of day in hours (14.5 at 14:30), in the calendar's time zone.
public func hourOfDay(_ date: Date, in calendar: Calendar = .current) -> Double {
    let time = calendar.dateComponents([.hour, .minute, .second], from: date)
    return Double(time.hour ?? 12) + Double(time.minute ?? 0) / 60 + Double(time.second ?? 0) / 3600
}

/// Solves a·v = b for a symmetric positive definite `a` (n×n, row by row),
/// with the variables in each group sharing one value: Gaussian elimination on
/// the reduced system, skipping the zeros a banded matrix is mostly made of.
func solve(_ a: [Double], _ b: [Double], tying groups: [[Int]]) -> [Double] {
    let n = b.count, m = groups.count
    var r = [Double](repeating: 0, count: m * m), y = [Double](repeating: 0, count: m)
    var group = [Int](repeating: 0, count: n)
    for (g, members) in groups.enumerated() { for p in members { group[p] = g } }
    for p in 0..<n {
        y[group[p]] += b[p]
        for q in 0..<n where a[p * n + q] != 0 { r[group[p] * m + group[q]] += a[p * n + q] }
    }
    var u = [Double](repeating: 0, count: m)
    r.withUnsafeMutableBufferPointer { r in
        y.withUnsafeMutableBufferPointer { y in
            for col in 0..<m {
                let pivot = r[col * m + col]
                for row in col + 1..<m {
                    let f = r[row * m + col] / pivot
                    guard f != 0 else { continue }
                    for k in col..<m { r[row * m + k] -= f * r[col * m + k] }
                    y[row] -= f * y[col]
                }
            }
            for row in stride(from: m - 1, through: 0, by: -1) {
                var sum = y[row]
                for k in row + 1..<m { sum -= r[row * m + k] * u[k] }
                u[row] = sum / r[row * m + row]
            }
        }
    }
    return (0..<n).map { u[group[$0]] }
}

/// The same, for a matrix given as rows.
func solve(_ a: [[Double]], _ b: [Double], tying groups: [[Int]]) -> [Double] {
    solve(a.flatMap { $0 }, b, tying: groups)
}
