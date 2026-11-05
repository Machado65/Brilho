// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Native brightness control: the built-in display, and externals in HDR mode,
/// where macOS sets the SDR white level of the signal itself.
enum Backlight {
    private static let library = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let getBrightness = symbol(library, "DisplayServicesGetBrightness",
                                              as: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
    private static let setBrightness = symbol(library, "DisplayServicesSetBrightness",
                                              as: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
    private static let canChangeBrightness = symbol(library, "DisplayServicesCanChangeBrightness",
                                                    as: (@convention(c) (CGDirectDisplayID) -> Bool).self)
    private static let hasCompensation = symbol(library, "DisplayServicesHasAmbientLightCompensation",
                                                as: (@convention(c) (CGDirectDisplayID) -> Bool).self)
    private static let compensationEnabled = symbol(library, "DisplayServicesAmbientLightCompensationEnabled",
                                                    as: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32).self)
    private static let enableCompensation = symbol(library, "DisplayServicesEnableAmbientLightCompensation",
                                                   as: (@convention(c) (CGDirectDisplayID, Bool) -> Int32).self)

    static func get(_ id: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard let getBrightness, getBrightness(id, &value) == 0, value.isFinite else { return nil }
        return Double(value)
    }

    static func set(_ id: CGDirectDisplayID, _ value: Double) { _ = setBrightness?(id, Float(min(max(value, 0), 1))) }
    static func canChange(_ id: CGDirectDisplayID) -> Bool { canChangeBrightness?(id) ?? false }

    /// macOS's own automatic brightness (System Settings > Displays), which fights Brilho's when on.
    static func systemAuto(_ id: CGDirectDisplayID) -> Bool {
        var on = false
        guard let hasCompensation, let compensationEnabled else { return false }
        return hasCompensation(id) && compensationEnabled(id, &on) == 0 && on
    }

    static func turnOffSystemAuto(_ id: CGDirectDisplayID) { _ = enableCompensation?(id, false) }
}

/// An external display's HDR mode (System Settings > Displays > High Dynamic
/// Range), through MonitorPanel's MPDisplay.
enum HDR {
    private static let loaded = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_NOW) != nil

    private static func panel(_ id: CGDirectDisplayID) -> NSObject? {
        guard loaded, let manager = (NSClassFromString("MPDisplayMgr") as? NSObject.Type)?.init(),
              manager.responds(to: NSSelectorFromString("displays")) else { return nil }
        return (manager.value(forKey: "displays") as? [NSObject])?.first {
            $0.responds(to: NSSelectorFromString("displayID")) && $0.value(forKey: "displayID") as? Int == Int(id)
        }
    }

    /// nil for a display without HDR modes.
    static func isOn(_ id: CGDirectDisplayID) -> Bool? {
        guard let panel = panel(id), panel.responds(to: NSSelectorFromString("hasHDRModes")),
              panel.value(forKey: "hasHDRModes") as? Bool == true, panel.responds(to: NSSelectorFromString("preferHDRModes"))
        else { return nil }
        return panel.value(forKey: "preferHDRModes") as? Bool
    }

    static func set(_ id: CGDirectDisplayID, _ on: Bool) {
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        let selector = NSSelectorFromString("setPreferHDRModes:")
        guard let panel = panel(id), panel.responds(to: selector) else { return }
        unsafeBitCast(panel.method(for: selector), to: Set.self)(panel, selector, on)
    }
}

/// The nits macOS drives a display at, for the displays it dims itself:
/// IOMFBBrightnessLevel (16.16 fixed point) on the display's
/// IOMobileFramebufferShim. The built-in panel's sits under disp0; an external's
/// names its vendor and product in its DisplayAttributes. Apple Silicon only.
enum Meter {
    static func nits(_ id: CGDirectDisplayID) -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let shim = IOIteratorNext(iterator), shim != 0 {
            defer { IOObjectRelease(shim) }
            guard belongs(shim, to: id) else { continue }
            let level = IORegistryEntryCreateCFProperty(shim, "IOMFBBrightnessLevel" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            return (level as? NSNumber).map { $0.doubleValue / 65536 }
        }
        return nil
    }

    private static func belongs(_ shim: io_registry_entry_t, to id: CGDirectDisplayID) -> Bool {
        if CGDisplayIsBuiltin(id) != 0 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(shim, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
            defer { IOObjectRelease(parent) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(parent, &name)
            return String(cString: name) == "disp0"
        }
        let attributes = IORegistryEntryCreateCFProperty(shim, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        let product = (attributes as? [String: Any])?["ProductAttributes"] as? [String: Any]
        return (product?["LegacyManufacturerID"] as? NSNumber)?.uint32Value == CGDisplayVendorNumber(id)
            && (product?["ProductID"] as? NSNumber)?.uint32Value == CGDisplayModelNumber(id)
    }
}
