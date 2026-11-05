// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The brightness keys, caught before macOS handles them, so the ones pressed
/// with the pointer on a display macOS can't dim (over DDC, or in software)
/// can go to it. It needs the Accessibility permission, and starts once that's
/// granted.
final class BrightnessKeys {
    private var tap: CFMachPort?
    private var swallowing = false // the key went to Brilho, so its release does too
    private let handle: (_ up: Bool, _ fine: Bool) -> Bool

    init(handle: @escaping (Bool, Bool) -> Bool) { self.handle = handle }

    var running: Bool { tap != nil }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let callback: CGEventTapCallBack = { _, type, event, info in
            Unmanaged<BrightnessKeys>.fromOpaque(info!).takeUnretainedValue().filter(type, event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(1 << 14), // NX_SYSDEFINED: media and brightness keys
                                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("brightness keys: on")
    }

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
        let code = (key.data1 & 0xFFFF0000) >> 16, state = (key.data1 & 0xFF00) >> 8
        guard code == 2 || code == 3 else { return Unmanaged.passUnretained(event) } // NX_KEYTYPE_BRIGHTNESS_UP, _DOWN
        if state == 0xA { swallowing = handle(code == 2, key.modifierFlags.contains([.option, .shift])) } // down, or repeating
        return swallowing ? nil : Unmanaged.passUnretained(event)
    }
}
