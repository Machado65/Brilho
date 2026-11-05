// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The bytes of DDC/CI's VCP messages: what goes to the display (at I2C address
/// 0x37, from the host at 0x51) after the address byte, and what comes back.
public enum DDCMessage {
    /// Asks for a control's current and maximum values.
    public static func get(_ control: UInt8) -> [UInt8] { checksummed([0x82, 0x01, control]) }

    public static func set(_ control: UInt8, _ value: Int) -> [UInt8] {
        let value = min(max(value, 0), 0xFFFF)
        return checksummed([0x84, 0x03, control, UInt8(value >> 8), UInt8(value & 0xff)])
    }

    /// The checksum XORs the destination address (0x6E) and the source (0x51)
    /// with every byte of the message.
    public static func checksummed(_ message: [UInt8]) -> [UInt8] { message + [message.reduce(0x6E ^ 0x51, ^)] }

    /// A get reply: source, length, opcode 0x02, result 0 (supported), the
    /// control, its type, then maximum and current, two bytes each.
    public static func reply(_ bytes: [UInt8], for control: UInt8) -> (value: Int, max: Int)? {
        guard bytes.count >= 10, bytes[2] == 0x02, bytes[3] == 0, bytes[4] == control else { return nil }
        return (Int(bytes[8]) << 8 | Int(bytes[9]), Int(bytes[6]) << 8 | Int(bytes[7]))
    }
}

/// The vendor and product an IOMobileFramebufferShim's EDID UUID names: its
/// first four hex digits, then the next four byte-swapped ("06B3E127..." is
/// vendor 0x06B3, product 0x27E1), as CGDisplayVendorNumber and
/// CGDisplayModelNumber give them.
public func edidProduct(_ uuid: String) -> (vendor: UInt32, model: UInt32)? {
    let hex = Array(uuid.prefix(8))
    guard hex.count == 8, let vendor = UInt32(String(hex[0..<4]), radix: 16),
          let model = UInt32(String(hex[6..<8] + hex[4..<6]), radix: 16) else { return nil }
    return (vendor, model)
}
