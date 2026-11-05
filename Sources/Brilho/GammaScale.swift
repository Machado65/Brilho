// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// Scales a display's gamma table, per channel: above 1 for XDR, below 1 to dim
/// past the lowest a backlight goes or to warm its white. It scales the table
/// the display had when first touched and puts that back when all factors are
/// 1; macOS restores it if Brilho quits. The table's output is gamma encoded, so
/// a factor k scales light by about k^2.2.
final class GammaScale {
    let id: CGDirectDisplayID
    private var table: (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue])?
    private var factors: [Float] = [1, 1, 1]

    init(_ id: CGDirectDisplayID) { self.id = id }

    func set(_ wanted: [Float]) {
        guard wanted.allSatisfy(\.isFinite) else { return }
        guard wanted.contains(where: { abs($0 - 1) > 0.001 }) else { return reset() }
        if table == nil {
            var red = [CGGammaValue](repeating: 0, count: 256), green = red, blue = red
            var count: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count) == .success, count > 0 else { return }
            table = (Array(red.prefix(Int(count))), Array(green.prefix(Int(count))), Array(blue.prefix(Int(count))))
        }
        guard let table else { return }
        // Also put back when something else (a reconfiguration, another app) has reset the table
        var red = [CGGammaValue](repeating: 0, count: table.red.count), green = red, blue = red
        var count: UInt32 = 0
        CGGetDisplayTransferByTable(id, UInt32(red.count), &red, &green, &blue, &count)
        let current: [Float] = [red.last ?? 0, green.last ?? 0, blue.last ?? 0]
        let expected: [Float] = [(table.red.last ?? 0) * factors[0], (table.green.last ?? 0) * factors[1], (table.blue.last ?? 0) * factors[2]]
        let drifted = zip(current, expected).contains { abs($0 - $1) > 0.01 }
        guard drifted || zip(wanted, factors).contains(where: { abs($0 - $1) > 0.001 }) else { return }
        CGSetDisplayTransferByTable(id, UInt32(table.red.count), table.red.map { $0 * wanted[0] }, table.green.map { $0 * wanted[1] },
                                    table.blue.map { $0 * wanted[2] })
        factors = wanted
    }

    func reset() {
        guard let table else { return }
        CGSetDisplayTransferByTable(id, UInt32(table.red.count), table.red, table.green, table.blue)
        self.table = nil
        factors = [1, 1, 1]
    }
}
