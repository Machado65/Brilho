// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a display says it is, from the first block of its EDID: the numbers
/// macOS gives as CGDisplayVendorNumber, ModelNumber and SerialNumber, so a
/// display's preferences are kept under the same key on any platform.
public struct EDID: Equatable, Sendable {
    /// The manufacturer, as the big-endian 16 bits of bytes 8-9 ("AUS" is 0x06B3).
    public var vendor: UInt32
    /// The product code, little-endian in bytes 10-11.
    public var model: UInt32
    /// The serial number, little-endian in bytes 12-15.
    public var serial: UInt32
    /// The monitor's name, from its 0xFC descriptor, if it has one.
    public var name: String?

    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= 128, Array(bytes[0..<8]) == [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00] else { return nil }
        vendor = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        model = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        serial = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        name = stride(from: 54, through: 108, by: 18).lazy.compactMap { start -> String? in
            // A display descriptor: two zero bytes, a zero, then its type; 0xFC is the name, up to 13 characters
            guard bytes[start] == 0, bytes[start + 1] == 0, bytes[start + 3] == 0xFC else { return nil }
            let text = bytes[(start + 5)..<(start + 18)].prefix { $0 != 0x0A && $0 != 0 }
            let name = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }.first
    }

    /// The three letters of the manufacturer's ID ("AUS", "AOC", "DEL").
    public var manufacturer: String {
        String([(vendor >> 10) & 31, (vendor >> 5) & 31, vendor & 31].map { Character(UnicodeScalar(UInt8(64 + $0))) })
    }

    /// The key a display's preferences are kept under.
    public var key: String { "\(vendor)-\(model)-\(serial)" }
}
