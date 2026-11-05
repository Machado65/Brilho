// swift-tools-version:6.0
// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

var targets: [Target] = [
    // The logic, with no AppKit and no private API: what's tested, on any platform Swift runs on
    .target(name: "BrilhoCore"),
    .testTarget(name: "BrilhoCoreTests", dependencies: ["BrilhoCore"]),
]
#if os(macOS)
// The menu bar app: the hardware, the panel, the loop
targets.append(.executableTarget(name: "Brilho", dependencies: ["BrilhoCore"]))
#endif

let package = Package(
    name: "Brilho",
    platforms: [.macOS(.v14)],
    targets: targets,
    swiftLanguageModes: [.v5]
)
