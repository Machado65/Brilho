// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// A brightness indicator like macOS's, on a display a brightness key just
/// changed where macOS shows none.
final class HUD {
    final class Model: ObservableObject { @Published var level = 0.0 }

    private let model = Model()
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    func show(_ level: Double, on screen: NSScreen) {
        model.level = level
        let panel = panel ?? make()
        panel.setFrame(NSRect(x: screen.frame.midX - 100, y: screen.frame.minY + screen.frame.height * 0.12, width: 200, height: 200),
                       display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hide?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel?.animator().alphaValue = 0
            }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        self.panel = panel
        return panel
    }
}

struct HUDView: View {
    @ObservedObject var model: HUD.Model

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "sun.max.fill").font(.system(size: 56))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.3))
                    Capsule().fill(Color(nsColor: .systemRed)).frame(width: max(geometry.size.width * model.level, 6))
                }
            }
            .frame(height: 6)
        }
        .padding(30)
        .frame(width: 200, height: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Brightness \(Int((model.level * 100).rounded())) percent")
    }
}
