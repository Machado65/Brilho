// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import ServiceManagement
import SwiftUI

/// A switch drawn in SwiftUI, so it keeps its colour where AppKit's would turn grey.
struct Switch: ToggleStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View { Drawn(configuration: configuration, color: color) }

    private struct Drawn: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            Capsule()
                .fill(configuration.isOn ? color : Color.secondary.opacity(0.35))
                .frame(width: 38, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).shadow(radius: 1, y: 0.5).padding(2)
                }
                .opacity(enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .onTapGesture { if enabled { configuration.isOn.toggle() } }
                .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    private let accent = Color(nsColor: .systemRed)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Brilho").font(.headline)
                Spacer()
                Text(model.estimated ? "lid closed: by time of day" : model.lux.map { "\($0) lux" } ?? "")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            switchRow("Auto Brightness", isOn: model.auto, set: model.setAuto)
            nightWarmth
            if model.xdrAvailable {
                switchRow("Automatic XDR", isOn: model.xdr, set: model.setXDR)
                Text(model.auto ? "In sunlight. At full, brightness up turns XDR on too" : "Only with Auto Brightness on")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(model.rows) { row in display(row) }
            if model.keysNeedPermission {
                HStack {
                    Text("Brightness keys for external displays need Accessibility").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…", action: model.allowKeys).controlSize(.small)
                }
            }
            switchRow("Open at Login", isOn: model.openAtLogin, set: model.setOpenAtLogin)
            if model.loginNeedsApproval {
                HStack {
                    Text("Waiting for approval in Login Items").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings…") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                }
            }
            Divider()
            CurveChart(series: model.series, now: model.estimated ? nil : model.lux.map(Double.init), hover: model.hover)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Button("Forget My Adjustments", action: model.forget)
                    Text("Brilho learns from every change you make, by the light, the hour, the app and more; this starts over.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .tint(accent)
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder private var nightWarmth: some View {
        HStack {
            Text("Night Warmth")
            Spacer()
            if model.nightWarmth { Text(model.nightPhase).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            Toggle("Night Warmth", isOn: Binding(get: { model.nightWarmth }, set: model.setNightWarmth)).toggleStyle(Switch(color: accent))
        }
        .help("Warms every screen from sunset to the morning: 3500 K in the evening, 2000 K by bedtime, nine hours before waking")
        if model.nightWarmth {
            if let warmth = model.warmth {
                HStack {
                    Text("Warmth").foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                    Slider(value: Binding(get: { warmth }, set: model.setWarmth), in: 0...2,
                           onEditingChanged: model.editingWarmth)
                        .controlSize(.small)
                    Text(verbatim: "\(model.warmthKelvin) K").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                .help("How warm the screens are now. Brilho learns it for this time of the evening, and for the app in front")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(model.locationProblem ?? model.place).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(model.locating ? "Locating…" : "Use Current Location", action: model.useCurrentLocation)
                    .controlSize(.small).disabled(model.locating)
            }
            HStack {
                Text("Wake-up time").font(.caption).foregroundStyle(.secondary)
                Spacer()
                DatePicker("Wake-up time", selection: Binding(get: { model.wake }, set: model.setWake), displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field).controlSize(.small).fixedSize()
            }
        }
    }

    private func display(_ row: PanelModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name.uppercased())
                Spacer()
                Text(verbatim: row.white.map { "\(row.nits) nits · \($0) K" } ?? "\(row.nits) nits").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            sliderRow(row, .brightness, "Brightness", row.brightness, row.brightnessRange, percent: row.brightness * 100)
            if let contrast = row.contrast, let max = row.controlMax[.contrast] {
                sliderRow(row, .contrast, "Contrast", contrast, 0...max, percent: contrast * 100 / max)
            }
            if let volume = row.volume, let max = row.controlMax[.volume] {
                sliderRow(row, .volume, "Volume", volume, 0...max, percent: volume * 100 / max)
            }
            if let roomColour = row.roomColour {
                optionRow("Room Colour", isOn: roomColour) { model.setRoomColour(row.id, $0) }
                    .help("Warms this screen a little towards the colour of the room's light, as True Tone does on the Mac; "
                        + "at night, the warmer of this and Night Warmth")
            }
            if let hdr = row.hdr {
                optionRow("HDR", isOn: hdr) { model.setHDR(row.id, $0) }
            }
            if row.measurable || row.external {
                HStack {
                    Text(levelsNote(row)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(row.measurable ? (row.calibrated ? "Measure Again" : "Measure") : (row.calibrated ? "Recalibrate" : "Calibrate")) {
                        model.calibrate(row.id)
                    }
                    .controlSize(.small).disabled(model.measuring != nil || !(row.measurable || model.canCalibrate))
                }
            }
        }
    }

    /// Where a display's nits come from: measured where macOS knows them, else calibrated by eye, else a guess.
    private func levelsNote(_ row: PanelModel.Row) -> String {
        if model.measuring == row.id { return "Measuring…" }
        if row.measurable { return row.calibrated ? "Measured" : "Not measured: nits are a guess" }
        return (row.software ? "Dimmed in software (no DDC). " : "") + (row.calibrated ? "Calibrated" : "Not calibrated: nits are a guess")
    }

    private func switchRow(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: Binding(get: { isOn }, set: set)).toggleStyle(Switch(color: accent))
        }
    }

    private func optionRow(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Toggle(title, isOn: Binding(get: { isOn }, set: set)).toggleStyle(Switch(color: accent))
        }
    }

    private func sliderRow(_ row: PanelModel.Row, _ setting: Setting, _ title: String, _ value: Double,
                           _ range: ClosedRange<Double>, percent: Double) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { model.slide(row.id, setting, $0) }), in: range,
                   onEditingChanged: { model.editing(row.id, setting, $0) })
                .controlSize(.small)
            Text("\(Int(percent.rounded()))%").monospacedDigit().frame(width: 42, alignment: .trailing)
        }
    }
}
