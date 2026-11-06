// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import AppKit
import SwiftUI

/// `Brilho --snapshot <file.png> [dark]`, in debug builds: the panel drawn with
/// made-up displays, to look at its layout without the menu bar.
func snapshot(to path: String, dark: Bool) {
    final class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }
    let model = PanelModel()
    model.lux = 182
    model.nightPhase = "Evening, warmer at 22:30"
    model.warmth = 0.8
    model.warmthKelvin = 3900
    model.place = "Sunsets for 38.72° N, 9.14° W"
    model.xdrAvailable = true
    model.xdr = true
    model.canCalibrate = true
    model.openAtLogin = true
    model.rows = [
        PanelModel.Row(id: 1, name: "Built-in Retina Display", brightness: 0.55, nits: 186, brightnessRange: 0...1, contrast: nil, volume: nil,
                       controlMax: [:], hdr: nil, roomColour: nil, white: 3900, external: false, software: false, measurable: true,
                       calibrated: true),
        PanelModel.Row(id: 2, name: "PA279CRV", brightness: 0.42, nits: 160, brightnessRange: 0...1, contrast: 80, volume: 30,
                       controlMax: [.contrast: 100, .volume: 100], hdr: false, roomColour: true, white: 3900, external: true,
                       software: false, measurable: false, calibrated: true),
    ]
    let samples = stride(from: 0.0, through: 4.0, by: 0.1).map { pow(10, $0) }
    func curve(_ scale: Double, top: Double = 480) -> [PanelModel.Point] {
        samples.map { PanelModel.Point(lux: $0, nits: min(scale * (35 + 3.5 * pow($0, 2.0 / 3)), top)) }
    }
    model.series = [
        PanelModel.Series(id: 1, name: "Built-in", slot: 0, day: curve(1.1, top: 960), night: curve(0.8, top: 960),
                          adjustments: [PanelModel.Point(lux: 182, nits: 186)]),
        PanelModel.Series(id: 2, name: "PA279CRV", slot: 1, day: curve(0.9), night: nil, adjustments: []),
    ]
    let view = PanelView(model: model).environment(\.controlActiveState, .key).background(Color(nsColor: .windowBackgroundColor))
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    hosting.frame.size = hosting.fittingSize
    let window = KeyWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date() + 0.5)
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
#endif
