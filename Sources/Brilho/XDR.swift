// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MetalKit

/// Takes the built-in XDR panel past its 500-nit SDR limit: one pixel of HDR
/// content makes macOS open the panel's headroom (the backlight goes to 1600
/// nits and SDR is scaled down to match), and the display's gamma table, its
/// output gamma encoded, multiplied by the factor's 1/2.2 power (along with its
/// white), scales SDR's light back up into it by the factor.
final class XDR: NSObject, MTKViewDelegate {
    private let queue = MTLCreateSystemDefaultDevice()?.makeCommandQueue()
    private var trigger: NSWindow?

    /// Shows the pixel while `factor` is above 1, and gives what the gamma table
    /// can take of it now: no more than the headroom macOS has opened so far, or
    /// highlights would clip until it has.
    func factor(_ factor: Double, on id: CGDirectDisplayID) -> Float {
        guard factor > 1.001, let screen = screen(id), queue != nil else {
            off()
            return 1
        }
        if trigger == nil { on(screen) }
        return Float(min(factor, Double(screen.maximumExtendedDynamicRangeColorComponentValue)))
    }

    func off() {
        trigger?.close()
        trigger = nil
    }

    private func on(_ screen: NSScreen) {
        // A single pixel in the top left corner, under the screen's rounded edge
        let window = NSWindow(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.maxY - 1, width: 1, height: 1),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.animationBehavior = .none

        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), device: queue?.device)
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1, height: 1)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        view.clearColor = MTLClearColorMake(2, 2, 2, 1) // anything above 1 is HDR
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = self
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        window.contentView = view
        window.orderFrontRegardless()
        view.draw()
        trigger = window
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue?.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding() // the pass only clears, to clearColor
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}
}
