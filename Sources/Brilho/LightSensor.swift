// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The ambient light sensors, read through IOHIDEventSystemClient (the
/// AppleLMUController of Intel Macs doesn't exist on Apple Silicon): the Mac's
/// own, and a display's that has one (a Studio Display, a Pro Display XDR).
final class LightSensor {
    struct Reading {
        let lux: Double
        let kelvin: Double
        /// The Mac's own, which the lid covers, as opposed to a display's.
        let builtIn: Bool
        let product: String
    }

    private typealias CopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias FloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double
    private typealias CopyProperty = @convention(c) (UnsafeRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    private static let ambientLight: Int64 = 12 // kIOHIDEventTypeAmbientLightSensor

    private let services: CFArray
    private let copyEvent: CopyEvent
    private let floatValue: FloatValue
    private let described: [(builtIn: Bool, product: String)]

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
        let found = Unmanaged<CFArray>.fromOpaque(list).takeRetainedValue()
        guard CFArrayGetCount(found) > 0 else { return nil }
        services = found
        self.copyEvent = copyEvent
        self.floatValue = floatValue
        // Which is which: Built-In and Product, as the services say (a sensor that doesn't say is taken as the Mac's)
        let copyProperty = symbol(iokit, "IOHIDServiceClientCopyProperty", as: CopyProperty.self)
        described = (0..<CFArrayGetCount(found)).map { index in
            guard let copyProperty, let service = CFArrayGetValueAtIndex(found, index) else { return (true, "light sensor") }
            let builtIn = copyProperty(service, "Built-In" as CFString)?.takeRetainedValue() as? Bool ?? true
            let product = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "light sensor"
            return (builtIn, product)
        }
    }

    /// Each sensor's light in lux, and its colour temperature in kelvin (field 10
    /// of the event, where the Mac's sensors seen so far put it); a sensor that
    /// gives nothing (the lid closed) is left out.
    func readings() -> [Reading] {
        (0..<CFArrayGetCount(services)).compactMap { index in
            guard let service = CFArrayGetValueAtIndex(services, index),
                  let event = copyEvent(service, Self.ambientLight, 0, 0) else { return nil }
            defer { Unmanaged<AnyObject>.fromOpaque(event).release() }
            let field = Int32(Self.ambientLight << 16)
            let lux = floatValue(event, field)
            guard lux.isFinite, lux >= 0 else { return nil }
            return Reading(lux: lux, kelvin: floatValue(event, field | 10), builtIn: described[index].builtIn, product: described[index].product)
        }
    }

    /// The light to follow: the Mac's own with its lid open (`builtInActive`),
    /// else a display's, which no lid covers.
    func read(builtInActive: Bool) -> Reading? {
        let readings = readings()
        return (builtInActive ? readings.first(where: \.builtIn) : nil) ?? readings.first { !$0.builtIn }
    }
}
