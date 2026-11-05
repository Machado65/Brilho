// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brilho", category: "brilho")

/// To the system log (Console, or `log stream --predicate 'subsystem == "io.github.machado65.brilho"'`),
/// and to standard error, which a launch agent may keep in a file.
func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    FileHandle.standardError.write(Data("\(Date().formatted(date: .numeric, time: .standard)) \(message)\n".utf8))
}

let iokit = "/System/Library/Frameworks/IOKit.framework/IOKit"

/// A function from a framework without headers, looked up when first needed.
/// Private ones can go in any macOS update: nil then, and what needs it is
/// left out rather than the app failing to start.
func symbol<T>(_ library: String, _ name: String, as _: T.Type) -> T? {
    guard let handle = dlopen(library, RTLD_NOW), let found = dlsym(handle, name) else {
        log("\(name) isn't in this macOS: what needs it is off")
        return nil
    }
    return unsafeBitCast(found, to: T.self)
}

func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

func screen(_ id: CGDirectDisplayID) -> NSScreen? { NSScreen.screens.first { displayID($0) == id } }

func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

/// The light level x = log10(lux + 1) back in lux.
func lux(_ light: Double) -> Int { Int((pow(10, light) - 1).rounded()) }
