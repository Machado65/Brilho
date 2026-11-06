// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import BrilhoCore
import Charts
import SwiftUI

/// Each display's learnt curve, lux to nits on log scales, with the user's
/// adjustments as points and the current light as a rule; hovering reads it.
struct CurveChart: View {
    /// Where the pointer is over the chart, in lux (@State is a macro whose plugin the Command Line Tools lack).
    final class Hover: ObservableObject { @Published var lux: Double? }

    let series: [PanelModel.Series]
    let now: Double?
    @ObservedObject var hover: Hover
    @Environment(\.colorScheme) private var scheme

    /// Categorical slots 1-3 of the reference palette, in their light and dark steps.
    private func color(_ slot: Int) -> Color {
        let hex = (scheme == .dark ? [0x3987e5, 0xd95926, 0x199e70] : [0x2a78d6, 0xeb6834, 0x1baf7a])[min(slot, 2)]
        return Color(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ForEach(series) { series in
                    HStack(spacing: 5) {
                        Capsule().fill(color(series.slot)).frame(width: 12, height: 2)
                        Text(series.name)
                    }
                }
                if series.contains(where: { $0.night != nil }) {
                    HStack(spacing: 5) {
                        Path { $0.addLines([.init(x: 0, y: 1), .init(x: 12, y: 1)]) }
                            .stroke(.secondary, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                            .frame(width: 12, height: 2)
                        Text("night")
                    }
                }
            }
            Text(readout).monospacedDigit()
            chart.frame(height: 120)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Up to 600 nits, or past it where a curve goes there (the built-in display's XDR boost).
    private var topNits: Double { series.contains { $0.day.contains { $0.nits > 600 } } ? 1200 : 600 }

    private var chart: some View {
        Chart {
            ForEach(series) { series in
                ForEach(series.day) { point in
                    LineMark(x: .value("Lux", point.lux), y: .value("Nits", point.nits), series: .value("Curve", "\(series.id) day"))
                        .foregroundStyle(color(series.slot))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                ForEach(series.night ?? []) { point in
                    LineMark(x: .value("Lux", point.lux), y: .value("Nits", point.nits), series: .value("Curve", "\(series.id) night"))
                        .foregroundStyle(color(series.slot))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]))
                }
                ForEach(series.adjustments) { point in
                    // An 8 pt marker in a 2 pt ring of the surface
                    PointMark(x: .value("Lux", point.lux), y: .value("Nits", point.nits))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor)).symbolSize(144)
                    PointMark(x: .value("Lux", point.lux), y: .value("Nits", point.nits))
                        .foregroundStyle(color(series.slot)).symbolSize(64)
                }
            }
            if let now {
                RuleMark(x: .value("Now", max(now, 1))).foregroundStyle(Color.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let hover = hover.lux {
                RuleMark(x: .value("Lux", hover)).foregroundStyle(Color.primary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: 1...10000, type: .log)
        .chartYScale(domain: 2...topNits, type: .log)
        .chartXAxis {
            AxisMarks(values: [1.0, 10, 100, 1000, 10000]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel { Text(label(value.as(Double.self) ?? 0)) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [3.0, 10, 30, 100, 300] + (topNits > 600 ? [1000] : [])) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel { Text(label(value.as(Double.self) ?? 0)) }
            }
        }
        .chartXAxisLabel("lux", alignment: .trailing)
        .chartYAxisLabel("nits", position: .leading)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let frame = proxy.plotFrame else { return hover.lux = nil }
                            hover.lux = proxy.value(atX: location.x - geometry[frame].origin.x, as: Double.self).map { min(max($0, 1), 10000) }
                        case .ended:
                            hover.lux = nil
                        }
                    }
            }
        }
    }

    private var readout: String {
        guard let hover = hover.lux else { return now.map { "Now \(Int($0.rounded())) lux, nits by light" } ?? "Nits by light" }
        let values = series.map { series -> String in
            let nits = pow(10, interpolate(series.day.map { (log10($0.lux), log10($0.nits)) }, at: log10(hover)))
            return "\(series.name) \(Int(nits.rounded()))"
        }
        return "\(Int(hover.rounded())) lux: " + values.joined(separator: " · ") + " nits"
    }

    private func label(_ value: Double) -> String { value >= 1000 ? "\(Int(value / 1000))k" : "\(Int(value))" }
}
