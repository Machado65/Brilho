// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import BrilhoCore
import IOKit.ps

/// What Brilho knows of the moment besides the light, for the preferences to
/// learn from: the app in front (Brilho's own panel aside), the system's
/// appearance, and the power source. Kept on the Mac, with the adjustments.
final class Circumstances {
    private(set) var app: String?
    private(set) var dark = false
    private(set) var battery = false
    private var observer: NSObjectProtocol?

    init() {
        app = Self.ownApp(NSWorkspace.shared.frontmostApplication) ? nil : NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        refresh()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let running, !Self.ownApp(running) else { return }
            self?.app = running.bundleIdentifier
        }
    }

    deinit { observer.map(NSWorkspace.shared.notificationCenter.removeObserver) }

    /// The appearance and the power source change seldom: looked at every few seconds.
    func refresh() {
        dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        battery = Self.onBattery()
    }

    func context(night: Double) -> Context { Context(night: night, app: app, dark: dark, battery: battery) }

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    private static func ownApp(_ app: NSRunningApplication?) -> Bool {
        app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}
