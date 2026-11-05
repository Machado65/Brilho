// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// A slider in a display's row.
enum Setting {
    case brightness, contrast, volume

    var control: DDC.Control? {
        switch self {
        case .brightness: nil
        case .contrast: .contrast
        case .volume: .volume
        }
    }
}

/// What the popover shows; refreshed only while it's open.
final class PanelModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: CGDirectDisplayID
        var name: String
        var brightness: Double
        var nits: Int
        var brightnessRange: ClosedRange<Double>
        var contrast: Double?
        var volume: Double?
        var controlMax: [DDC.Control: Double]
        var hdr: Bool? // nil without HDR modes
        var roomColour: Bool? // nil where Brilho doesn't set the white (native displays)
        var white: Int? // the colour temperature it's set to; nil while another app has its gamma
        var external: Bool
        var software: Bool // dimmed in software: it answers neither macOS nor DDC
        var measurable: Bool // macOS knows its nits, so measuring it takes no eye
        var calibrated: Bool
    }

    struct Point: Identifiable, Equatable {
        var lux: Double
        var nits: Double
        var id: String { "\(lux) \(nits)" }
    }

    struct Series: Identifiable, Equatable {
        let id: CGDirectDisplayID
        var name: String
        var slot: Int
        var day: [Point]
        var night: [Point]? // only once a night shift has been learnt
        var adjustments: [Point]
    }

    @Published var lux: Int?
    @Published var estimated = false
    @Published var auto = true
    @Published var xdr = false
    @Published var xdrAvailable = false
    @Published var xdrAllowed = false
    @Published var canCalibrate = false
    @Published var measuring: CGDirectDisplayID?
    @Published var openAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var wake = Date()
    @Published var keysNeedPermission = false
    @Published var nightWarmth = true
    @Published var nightPhase = ""
    /// Night Warmth's strength now, 0 (none) to 2 (twice the schedule's); nil by day, when there's none to set.
    @Published var warmth: Double?
    @Published var warmthKelvin = 6500
    @Published var place = "" // the sunset, and where it's worked out for
    @Published var locating = false
    @Published var locationProblem: String?
    @Published var rows: [Row] = []
    @Published var series: [Series] = []
    let hover = CurveChart.Hover()

    var slide: (CGDirectDisplayID, Setting, Double) -> Void = { _, _, _ in }
    var editing: (CGDirectDisplayID, Setting, Bool) -> Void = { _, _, _ in }
    var setWarmth: (Double) -> Void = { _ in }
    var editingWarmth: (Bool) -> Void = { _ in }
    var setAuto: (Bool) -> Void = { _ in }
    var setXDR: (Bool) -> Void = { _ in }
    var setHDR: (CGDirectDisplayID, Bool) -> Void = { _, _ in }
    var setRoomColour: (CGDirectDisplayID, Bool) -> Void = { _, _ in }
    var setNightWarmth: (Bool) -> Void = { _ in }
    var useCurrentLocation: () -> Void = {}
    var calibrate: (CGDirectDisplayID) -> Void = { _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var setWake: (Date) -> Void = { _ in }
    var allowKeys: () -> Void = {}
    var forget: () -> Void = {}
}
