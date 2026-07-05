import MacPerfMonitorCore
import SwiftUI

/// The hero pressure-index timeline: a 0–100 area chart with the warning and
/// critical bands marked, tinted by the current pressure level. Drawn with the
/// lightweight Canvas `TrendChart` rather than Swift Charts.
struct PressureChart: View {
    let points: [SystemHistoryPoint]
    let currentLevel: PressureLevel
    var showsTimeAxis: Bool = false

    private var accessibilitySummary: String {
        guard let latest = points.last?.pressurePercent else { return "No data yet." }
        let values = points.map(\.pressurePercent)
        let lo = Int((values.min() ?? latest).rounded())
        let hi = Int((values.max() ?? latest).rounded())
        return "Currently \(currentLevel.label.lowercased()) at \(Int(latest.rounded())) percent. "
            + "Window range \(lo) to \(hi) percent."
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: points.map { TrendPoint(date: $0.date, value: $0.pressurePercent) },
                    color: currentLevel.color, filled: true)
            ],
            yDomain: 0...100,
            yTicks: [0, 34, 67, 100],
            rules: [
                TrendRule(value: 34, label: "Warning", color: .orange),
                TrendRule(value: 67, label: "Critical", color: .red),
            ],
            showsTimeAxis: showsTimeAxis
        )
        .accessibilityLabel("Memory pressure timeline")
        .accessibilityValue(accessibilitySummary)
    }
}
