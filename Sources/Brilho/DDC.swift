// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import BrilhoCore

/// DDC/CI with an external display, for what macOS doesn't control natively.
/// Every message takes tens of milliseconds, so they go through their own queue,
/// and writes are coalesced: a dragged slider only sends its latest value.
final class DDC {
    enum Control: UInt8 { case brightness = 0x10, contrast = 0x12, volume = 0x62 }

    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private let service: CFTypeRef
    private let writeI2C: Transfer
    private let readI2C: Transfer
    private let queue = DispatchQueue(label: "brilho.ddc")
    private var latest: [Control: Int] = [:] // main thread, like `sending`
    private var sending = false

    /// The AV service of external display `id`, found by its EDID: each External
    /// DCPAVServiceProxy sits under the IOMobileFramebufferShim of the display it
    /// talks to, whose EDID UUID starts with the vendor and the byte-swapped
    /// product number. Several of the same monitor are told apart by order.
    init?(display id: CGDirectDisplayID) {
        guard let create = symbol(iokit, "IOAVServiceCreateWithService", as: Create.self),
              let writeI2C = symbol(iokit, "IOAVServiceWriteI2C", as: Transfer.self),
              let readI2C = symbol(iokit, "IOAVServiceReadI2C", as: Transfer.self) else { return nil }
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
            == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var product: (vendor: UInt32, model: UInt32)?
        var found: [CFTypeRef] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &name)
            switch String(cString: name) {
            case "IOMobileFramebufferShim":
                let uuid = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                product = (uuid as? String).flatMap(edidProduct)
            case "DCPAVServiceProxy":
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                if location as? String == "External", product?.vendor == CGDisplayVendorNumber(id), product?.model == CGDisplayModelNumber(id),
                   let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                    found.append(service)
                }
            default:
                break
            }
        }
        var online = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &online, &count)
        let twins = online.prefix(Int(count)).filter {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) == CGDisplayVendorNumber(id) && CGDisplayModelNumber($0) == CGDisplayModelNumber(id)
        }.sorted()
        guard let index = twins.firstIndex(of: id), index < found.count else { return nil }
        service = found[index]
        self.writeI2C = writeI2C
        self.readI2C = readI2C
    }

    func read(_ control: Control, then done: @escaping ((value: Int, max: Int)?) -> Void) {
        queue.async {
            let reply = self.get(control)
            DispatchQueue.main.async { done(reply) }
        }
    }

    /// Off the main thread already (diagnostics): waits for the reply.
    func readNow(_ control: Control) -> (value: Int, max: Int)? { queue.sync { get(control) } }

    func write(_ control: Control, _ value: Int) {
        latest[control] = value
        guard !sending else { return }
        sending = true
        sendLatest()
    }

    private func sendLatest() {
        guard let (control, value) = latest.first else {
            sending = false
            return
        }
        latest[control] = nil
        queue.async {
            self.send(DDCMessage.set(control.rawValue, value))
            DispatchQueue.main.async { self.sendLatest() }
        }
    }

    private func get(_ control: Control) -> (value: Int, max: Int)? {
        for _ in 0..<3 {
            guard send(DDCMessage.get(control.rawValue)) else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            if readI2C(service, 0x37, 0x51, &reply, 12) == kIOReturnSuccess, let value = DDCMessage.reply(reply, for: control.rawValue) {
                return value
            }
        }
        return nil
    }

    /// One message to the display, at I2C address 0x37, from the host at 0x51.
    @discardableResult private func send(_ message: [UInt8]) -> Bool {
        var data = message
        usleep(20_000)
        return writeI2C(service, 0x37, 0x51, &data, UInt32(data.count)) == kIOReturnSuccess
    }
}
