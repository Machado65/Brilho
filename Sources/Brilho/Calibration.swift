// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import BrilhoCore
import SwiftUI

/// Calibrates an external display by eye against the built-in one, whose nits
/// are measured: at each of five of its settings, the user brings the built-in
/// display's white square to the same brightness as the external's, and the
/// external's levels are what they matched.
final class Calibration: ObservableObject {
    static let settings = [0, 0.25, 0.5, 0.75, 1.0]

    let targetName: String
    private let reference: Levels
    private let guess: Levels
    private let show: (_ referenceNits: Double, _ targetSetting: Double) -> Void
    private let done: ([Level]?) -> Void
    private var matched: [Level] = []
    @Published var step = 0
    /// The built-in display's brightness, from its lowest to its highest nits on a log scale.
    @Published var position = 0.5 { didSet { show(nits, Self.settings[step]) } }

    var nits: Double { reference.minNits * pow(reference.maxNits / reference.minNits, position) }
    var isLast: Bool { step == Self.settings.count - 1 }

    init(targetName: String, reference: Levels, guess: Levels,
         show: @escaping (Double, Double) -> Void, done: @escaping ([Level]?) -> Void) {
        self.targetName = targetName
        self.reference = reference
        self.guess = guess
        self.show = show
        self.done = done
        begin()
    }

    func next() {
        matched.append(Level(setting: Self.settings[step], nits: nits))
        if isLast { return done(matched) }
        step += 1
        begin()
    }

    func cancel() { done(nil) }

    /// Starts the built-in display where the guess says the match is.
    private func begin() {
        let wanted = min(max(guess.nits(Self.settings[step]), reference.minNits), reference.maxNits)
        position = Foundation.log(wanted / reference.minNits) / Foundation.log(reference.maxNits / reference.minNits)
        show(nits, Self.settings[step])
    }
}

struct CalibrationView: View {
    @ObservedObject var calibration: Calibration
    let controls: Bool // on the built-in display; the external one only shows its square

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 32) {
                Rectangle().fill(Color.white).frame(width: 300, height: 300)
                if controls {
                    VStack(spacing: 14) {
                        Text("Step \(calibration.step + 1) of \(Calibration.settings.count)").font(.headline)
                        Text("Move the slider until this square looks as bright as the one on \(calibration.targetName). Ignore any difference in colour.")
                            .multilineTextAlignment(.center).frame(width: 360)
                        Slider(value: $calibration.position, in: 0...1).frame(width: 300)
                        Text("\(Int(calibration.nits.rounded())) nits").monospacedDigit().foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Cancel") { calibration.cancel() }.keyboardShortcut(.cancelAction)
                            Button(calibration.isLast ? "Finish" : "Next") { calibration.next() }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .foregroundStyle(.white)
                } else {
                    Text("Calibrating: follow the steps on the built-in display.").foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .tint(Color(nsColor: .systemRed))
        .environment(\.colorScheme, .dark)
    }
}

/// A borderless window over a whole screen that can still take the keyboard.
final class CalibrationWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    convenience init(screen: NSScreen, view: CalibrationView) {
        self.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .black
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: view)
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
    }
}
