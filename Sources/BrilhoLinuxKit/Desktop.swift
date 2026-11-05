// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore
import BrilhoEngine
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// An X11 session, through Xlib and its extensions looked up at run time, so
/// Brilho needs none of them to build: every screen's gamma ramps (RandR) for
/// Night Warmth, the app in front (EWMH), and how long the user's been idle
/// (XScreenSaver). On 64-bit Linux only, whose struct layouts it reads.
public final class X11Session: WhiteOutput {
    private typealias OpenDisplay = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
    private typealias ErrorHandler = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias SetErrorHandler = @convention(c) (ErrorHandler?) -> ErrorHandler?
    private typealias RootWindow = @convention(c) (OpaquePointer) -> UInt
    private typealias Flush = @convention(c) (OpaquePointer) -> Int32
    private typealias Free = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias InternAtom = @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32) -> UInt
    private typealias GetWindowProperty = @convention(c) (OpaquePointer, UInt, UInt, Int, Int, Int32, UInt, UnsafeMutablePointer<UInt>,
                                                          UnsafeMutablePointer<Int32>, UnsafeMutablePointer<UInt>, UnsafeMutablePointer<UInt>,
                                                          UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> Int32
    private typealias GetClassHint = @convention(c) (OpaquePointer, UInt, UnsafeMutableRawPointer) -> Int32
    private typealias GetResources = @convention(c) (OpaquePointer, UInt) -> UnsafeMutableRawPointer?
    private typealias FreeResources = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias GammaSize = @convention(c) (OpaquePointer, UInt) -> Int32
    private typealias AllocGamma = @convention(c) (Int32) -> UnsafeMutableRawPointer?
    private typealias GetGamma = @convention(c) (OpaquePointer, UInt) -> UnsafeMutableRawPointer?
    private typealias SetGamma = @convention(c) (OpaquePointer, UInt, UnsafeMutableRawPointer) -> Void
    private typealias FreeGamma = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias AllocIdle = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias QueryIdle = @convention(c) (OpaquePointer, UInt, UnsafeMutableRawPointer) -> Int32

    private let display: OpaquePointer
    private let root: UInt
    private let flush: Flush
    private let free: Free?
    private let internAtom: InternAtom?
    private let getWindowProperty: GetWindowProperty?
    private let getClassHint: GetClassHint?
    private let getResources: GetResources?
    private let freeResources: FreeResources?
    private let gammaSize: GammaSize?
    private let allocGamma: AllocGamma?
    private let getGamma: GetGamma?
    private let setGamma: SetGamma?
    /// Each CRTC's ramps as they were (a colour profile's calibration, say), which the white scales and which go back
    /// at the end; looked at once per CRTC (`seen`), since after that they're Brilho's own. One without ramps (all
    /// zeros) is taken as linear.
    private var original: [UInt: [[UInt16]]] = [:]
    private var seen: Set<UInt> = []
    private let freeGamma: FreeGamma?
    private let idleInfo: UnsafeMutableRawPointer?
    private let queryIdle: QueryIdle?
    private var activeWindowAtom: UInt = 0

    /// nil outside an X11 session (or one Xlib can't reach).
    public init?() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DISPLAY"] != nil, environment["XDG_SESSION_TYPE"].map({ $0 == "x11" }) ?? true,
              MemoryLayout<Int>.size == 8, let xlib = dlopen("libX11.so.6", RTLD_NOW),
              let open = symbol(xlib, "XOpenDisplay", as: OpenDisplay.self),
              let rootWindow = symbol(xlib, "XDefaultRootWindow", as: RootWindow.self),
              let flush = symbol(xlib, "XFlush", as: Flush.self),
              let setErrorHandler = symbol(xlib, "XSetErrorHandler", as: SetErrorHandler.self) else { return nil }
        // Xlib's own handler ends the process on any error (a window gone by the time it's asked about): ignored instead
        _ = setErrorHandler { _, _ in 0 }
        guard let display = open(nil) else { return nil }
        self.display = display
        root = rootWindow(display)
        self.flush = flush
        free = symbol(xlib, "XFree", as: Free.self)
        internAtom = symbol(xlib, "XInternAtom", as: InternAtom.self)
        getWindowProperty = symbol(xlib, "XGetWindowProperty", as: GetWindowProperty.self)
        getClassHint = symbol(xlib, "XGetClassHint", as: GetClassHint.self)
        let randr = dlopen("libXrandr.so.2", RTLD_NOW)
        getResources = symbol(randr, "XRRGetScreenResourcesCurrent", as: GetResources.self)
        freeResources = symbol(randr, "XRRFreeScreenResources", as: FreeResources.self)
        gammaSize = symbol(randr, "XRRGetCrtcGammaSize", as: GammaSize.self)
        allocGamma = symbol(randr, "XRRAllocGamma", as: AllocGamma.self)
        getGamma = symbol(randr, "XRRGetCrtcGamma", as: GetGamma.self)
        setGamma = symbol(randr, "XRRSetCrtcGamma", as: SetGamma.self)
        freeGamma = symbol(randr, "XRRFreeGamma", as: FreeGamma.self)
        let screensaver = dlopen("libXss.so.1", RTLD_NOW)
        idleInfo = symbol(screensaver, "XScreenSaverAllocInfo", as: AllocIdle.self)?()
        queryIdle = symbol(screensaver, "XScreenSaverQueryInfo", as: QueryIdle.self)
        activeWindowAtom = "_NET_ACTIVE_WINDOW".withCString { internAtom?(display, $0, 0) ?? 0 }
    }

    public var canSetWhite: Bool { getResources != nil && setGamma != nil }

    /// Every CRTC's ramps, as they were, scaled per channel as the Mac's gamma
    /// tables are: by the white's gain to the power 1/2.2, as the ramps are
    /// gamma encoded.
    public func setWhite(_ kelvin: Double) {
        let (r, g, b) = whiteGains(kelvin: kelvin)
        apply { index, step, size, original in
            let base = original?[index][step] ?? UInt16(Double(step) / Double(size - 1) * 65535)
            return UInt16(min(Double(base) * pow([r, g, b][index], 1 / 2.2), 65535))
        }
    }

    public func reset() {
        apply { index, step, size, original in original?[index][step] ?? UInt16(Double(step) / Double(size - 1) * 65535) }
        original = [:]
        seen = []
    }

    /// Sets every CRTC's ramps, a value per channel and step from what they were.
    private func apply(_ value: (_ channel: Int, _ step: Int, _ size: Int, _ original: [[UInt16]]?) -> UInt16) {
        guard let getResources, let freeResources, let gammaSize, let allocGamma, let setGamma, let freeGamma,
              let resources = getResources(display, root) else { return }
        defer { freeResources(resources) }
        // XRRScreenResources: two Times, then int ncrtc, then RRCrtc *crtcs
        let count = Int(resources.load(fromByteOffset: 16, as: Int32.self))
        guard let crtcs = resources.load(fromByteOffset: 24, as: UnsafeMutablePointer<UInt>?.self) else { return }
        for index in 0..<count {
            let crtc = crtcs[index]
            let size = Int(gammaSize(display, crtc))
            guard size > 1 else { continue }
            if !seen.contains(crtc) {
                seen.insert(crtc)
                if let getGamma, let current = getGamma(display, crtc) {
                    let ramps = Self.ramps(current, size)
                    if ramps.allSatisfy({ ($0.max() ?? 0) > 1000 }) { original[crtc] = ramps }
                    freeGamma(current)
                }
            }
            guard let gamma = allocGamma(Int32(size)) else { continue }
            // XRRCrtcGamma: int size, then unsigned short *red, *green, *blue
            for channel in 0..<3 {
                guard let ramp = gamma.load(fromByteOffset: 8 + 8 * channel, as: UnsafeMutablePointer<UInt16>?.self) else { continue }
                for step in 0..<size { ramp[step] = value(channel, step, size, original[crtc]) }
            }
            setGamma(display, crtc, gamma)
            freeGamma(gamma)
        }
        _ = flush(display)
    }

    /// The first CRTC's ramps now (the tests).
    func currentRamps() -> [[UInt16]]? {
        guard let getResources, let freeResources, let gammaSize, let getGamma, let freeGamma,
              let resources = getResources(display, root) else { return nil }
        defer { freeResources(resources) }
        guard resources.load(fromByteOffset: 16, as: Int32.self) > 0,
              let crtcs = resources.load(fromByteOffset: 24, as: UnsafeMutablePointer<UInt>?.self) else { return nil }
        let size = Int(gammaSize(display, crtcs[0]))
        guard size > 1, let gamma = getGamma(display, crtcs[0]) else { return nil }
        defer { freeGamma(gamma) }
        return Self.ramps(gamma, size)
    }

    private static func ramps(_ gamma: UnsafeMutableRawPointer, _ size: Int) -> [[UInt16]] {
        (0..<3).map { channel in
            guard let ramp = gamma.load(fromByteOffset: 8 + 8 * channel, as: UnsafeMutablePointer<UInt16>?.self) else { return [] }
            return Array(UnsafeBufferPointer(start: ramp, count: size))
        }
    }

    /// The class of the window in front ("firefox", "Code"), as the apps' shifts are kept by.
    public func activeApp() -> String? {
        guard let getWindowProperty, let getClassHint, let free, activeWindowAtom != 0 else { return nil }
        var type: UInt = 0, format: Int32 = 0, count: UInt = 0, after: UInt = 0
        var data: UnsafeMutablePointer<UInt8>?
        // Of any type (window managers write WINDOW; not all do), as long as it's a 32-bit value
        guard getWindowProperty(display, root, activeWindowAtom, 0, 1, 0, 0 /* AnyPropertyType */, &type, &format, &count, &after, &data) == 0,
              let data else { return nil }
        guard count > 0, format == 32 else {
            _ = free(data)
            return nil
        }
        let window = UnsafeRawPointer(data).load(as: UInt.self)
        _ = free(data)
        guard window != 0 else { return nil }
        // XClassHint: char *res_name, *res_class
        var hint: (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?) = (nil, nil)
        guard withUnsafeMutableBytes(of: &hint, { getClassHint(display, window, $0.baseAddress!) }) != 0 else { return nil }
        defer {
            if let name = hint.0 { _ = free(name) }
            if let cls = hint.1 { _ = free(cls) }
        }
        return hint.1.map { String(cString: $0) }
    }

    /// Seconds since the keyboard or pointer was last used.
    public func idleTime() -> TimeInterval? {
        guard let idleInfo, let queryIdle, queryIdle(display, root, idleInfo) != 0 else { return nil }
        // XScreenSaverInfo: Window window; int state, kind; unsigned long til_or_since, idle (ms)
        return Double(idleInfo.load(fromByteOffset: 24, as: UInt.self)) / 1000
    }
}

/// GNOME's own Night Light, which Brilho drives where it can't set the gamma
/// itself (GNOME on Wayland): always on, at the temperature Night Warmth wants,
/// off by day. GNOME takes 1700 to 4700 K. What it was set to is put back when
/// Brilho stops.
public final class GnomeNightLight: WhiteOutput {
    private static let schema = "org.gnome.settings-daemon.plugins.color"
    private let runner: Runner
    private var original: [String: String] = [:]
    private var temperature: Int?
    private var enabled: Bool?

    public init?(runner: Runner = .system, desktop: String? = ProcessInfo.processInfo.environment["XDG_CURRENT_DESKTOP"]) {
        guard desktop?.contains("GNOME") == true,
              runner.run("gsettings", ["get", Self.schema, "night-light-temperature"]) != nil else { return nil }
        self.runner = runner
        for key in ["night-light-enabled", "night-light-schedule-automatic", "night-light-schedule-from", "night-light-schedule-to",
                    "night-light-temperature"] {
            original[key] = runner.run("gsettings", ["get", Self.schema, key])
        }
        // From 0 to 0 is the whole day
        set("night-light-schedule-automatic", "false")
        set("night-light-schedule-from", "0.0")
        set("night-light-schedule-to", "0.0")
    }

    public func setWhite(_ kelvin: Double) {
        guard kelvin < 4700 else {
            if enabled != false { set("night-light-enabled", "false") }
            enabled = false
            return
        }
        let wanted = max(Int(kelvin.rounded()), 1700)
        if temperature.map({ abs($0 - wanted) >= 25 }) ?? true {
            set("night-light-temperature", String(wanted))
            temperature = wanted
        }
        if enabled != true { set("night-light-enabled", "true") }
        enabled = true
    }

    public func reset() {
        for (key, value) in original { set(key, value.replacingOccurrences(of: "uint32 ", with: "")) }
    }

    private func set(_ key: String, _ value: String) { _ = runner.run("gsettings", ["set", Self.schema, key, value]) }
}

/// GNOME's own automatic brightness follows the same sensor and fights Brilho's:
/// off while Brilho runs, and as it was when it stops.
public final class GnomeAutoBrightness {
    private static let schema = "org.gnome.settings-daemon.plugins.power"
    private let runner: Runner
    private var turnedOff = false

    public init(runner: Runner = .system) { self.runner = runner }

    public func turnOff(log: (String) -> Void) {
        guard runner.run("gsettings", ["get", Self.schema, "ambient-enabled"]) == "true" else { return }
        _ = runner.run("gsettings", ["set", Self.schema, "ambient-enabled", "false"])
        turnedOff = true
        log("turned off GNOME's automatic screen brightness, which fights Brilho's; it's back when Brilho stops")
    }

    public func restore() {
        if turnedOff { _ = runner.run("gsettings", ["set", Self.schema, "ambient-enabled", "true"]) }
    }
}

/// The moment's circumstances on Linux: the power source (sysfs), the dark
/// appearance (the desktop portal, every ten seconds), the app in front (X11
/// only: Wayland doesn't say), and how long the user's been idle (X11, GNOME,
/// or the freedesktop screensaver interface KDE and others have).
public final class LinuxSurroundings: Surroundings {
    private let paths: Paths
    private let runner: Runner
    private let x11: X11Session?
    private var dark = false
    private var battery = false
    private var app: String?
    private var lookedAt = Date.distantPast

    public init(paths: Paths = .current, runner: Runner = .system, x11: X11Session?) {
        self.paths = paths
        self.runner = runner
        self.x11 = x11
    }

    public func context(night: Double) -> Context {
        if Date().timeIntervalSince(lookedAt) >= 10 {
            lookedAt = Date()
            battery = Power.onBattery(paths)
            dark = runner.run("busctl", ["--user", "--timeout=2", "call", "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                                         "org.freedesktop.portal.Settings", "ReadOne", "ss", "org.freedesktop.appearance", "color-scheme"])?
                .hasSuffix(" 1") ?? false
        }
        if let x11 { app = x11.activeApp() ?? app }
        return Context(night: night, app: app, dark: dark, battery: battery)
    }

    public func idleTime() -> TimeInterval? {
        if let idle = x11?.idleTime() { return idle }
        if let reply = runner.run("busctl", ["--user", "--timeout=2", "call", "org.gnome.Mutter.IdleMonitor", "/org/gnome/Mutter/IdleMonitor/Core",
                                             "org.gnome.Mutter.IdleMonitor", "GetIdletime"]),
           let milliseconds = reply.split(separator: " ").last.flatMap({ Double($0) }) {
            return milliseconds / 1000
        }
        if let reply = runner.run("busctl", ["--user", "--timeout=2", "call", "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
                                             "org.freedesktop.ScreenSaver", "GetSessionIdleTime"]),
           let seconds = reply.split(separator: " ").last.flatMap({ Double($0) }) {
            return seconds
        }
        return nil
    }
}
