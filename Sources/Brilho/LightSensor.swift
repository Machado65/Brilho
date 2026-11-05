// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The built-in ambient light sensor, read through IOHIDEventSystemClient (the
/// AppleLMUController of Intel Macs doesn't exist on Apple Silicon).
final class LightSensor {
    private typealias CopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias FloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double
    private static let ambientLight: Int64 = 12 // kIOHIDEventTypeAmbientLightSensor

    private let services: CFArray
    private let copyEvent: CopyEvent
    private let floatValue: FloatValue

    init?() {
        typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
        typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        guard let create = symbol(iokit, "IOHIDEventSystemClientCreate", as: Create.self),
              let setMatching = symbol(iokit, "IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol(iokit, "IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyEvent = symbol(iokit, "IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let floatValue = symbol(iokit, "IOHIDEventGetFloatValue", as: FloatValue.self),
              // The client is never released: it has to outlive the services it hands out
              let client = create(kCFAllocatorDefault) else { return nil }
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 4] as CFDictionary)
        guard let list = copyServices(client) else { return nil }
        services = Unmanaged<CFArray>.fromOpaque(list).takeRetainedValue()
        self.copyEvent = copyEvent
        self.floatValue = floatValue
        guard CFArrayGetCount(services) > 0 else { return nil }
    }

    /// The light's level in lux, and its colour temperature in kelvin (field 10
    /// of the event, where the MacBook sensors seen so far put it). nil while
    /// the sensor gives nothing (the lid closed).
    func read() -> (lux: Double, kelvin: Double)? {
        for i in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, i),
                  let event = copyEvent(service, Self.ambientLight, 0, 0) else { continue }
            defer { Unmanaged<AnyObject>.fromOpaque(event).release() }
            let field = Int32(Self.ambientLight << 16)
            let lux = floatValue(event, field)
            guard lux.isFinite, lux >= 0 else { continue }
            return (lux, floatValue(event, field | 10))
        }
        return nil
    }
}
