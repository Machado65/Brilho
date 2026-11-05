// swift-tools-version:6.0
// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

var products: [Product] = []
var targets: [Target] = [
    // The logic, with no AppKit and no private API, on any platform Swift runs on
    .target(name: "BrilhoCore"),
    // The loop where Brilho runs as a service, with the hardware behind protocols
    .target(name: "BrilhoEngine", dependencies: ["BrilhoCore"]),
    // Linux's hardware and desktops: sysfs, DDC over /dev/i2c, X11, GNOME, the service (testable anywhere)
    .target(name: "BrilhoLinuxKit", dependencies: ["BrilhoEngine"]),
    .testTarget(name: "BrilhoCoreTests", dependencies: ["BrilhoCore"]),
    .testTarget(name: "BrilhoEngineTests", dependencies: ["BrilhoEngine"]),
    .testTarget(name: "BrilhoLinuxKitTests", dependencies: ["BrilhoLinuxKit"]),
]
#if os(macOS)
// The menu bar app: the hardware, the panel, the loop
targets.append(.executableTarget(name: "Brilho", dependencies: ["BrilhoCore"]))
#elseif os(Linux)
// The service and its commands
targets.append(.executableTarget(name: "BrilhoLinux", dependencies: ["BrilhoLinuxKit"]))
products.append(.executable(name: "brilho", targets: ["BrilhoLinux"]))
#endif

let package = Package(
    name: "Brilho",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
