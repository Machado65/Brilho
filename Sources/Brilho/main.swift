// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Brilho: keeps every display's brightness right for the light in the room,
// from the ambient light sensor, and learns from each correction the user
// makes, by the light, the hour, the app in front and more. It warms the
// screens' white at night, as much as the user likes, takes the built-in
// display past its SDR limit in bright light, switches external displays in and
// out of HDR, and dims the ones macOS can't, over DDC or in software,
// brightness keys included.

import AppKit

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--version") {
    print("Brilho \(appVersion)")
} else if arguments.contains("--diagnose") {
    _ = NSApplication.shared // for the screens' names and the appearance
    diagnose()
} else if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.endIndex {
    #if DEBUG
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    snapshot(to: arguments[index + 1], dark: arguments.contains("dark"), xdr: arguments.contains("xdr"), hud: arguments.contains("hud"))
    #endif
} else if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    Brilho \(appVersion): automatic brightness that learns.
      --diagnose   what Brilho sees (sensor, displays, what it has learnt), changing nothing
      --version    the version
    Run without options, it's the menu bar app.
    """)
} else {
    let app = NSApplication.shared
    let controller = Controller()
    app.delegate = controller
    app.run()
}
