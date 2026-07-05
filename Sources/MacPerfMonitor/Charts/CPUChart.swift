import MacPerfMonitorCore
import SwiftUI

/// The total-CPU timeline: a 0–100% area chart of system CPU across all cores,
/// with the "busy" (60%) and "heavy" (85%) bands marked, tinted by the current
/// `CPULevel`. Drawn with the lightweight Canvas `TrendChart`. Plots
/// `SystemHistoryPoint.cpuLoad` (a 0...1 fraction) as a percentage.
struct CPUChart: View {
    let points: [SystemHistoryPoint]
    let currentLevel: CPULevel
    var showsTimeAxis: Bool = false

    private var accessibilitySummary: String {
        guard let latest = points.last?.cpuLoad else { return "No data yet." }
        let values = points.map { $0.cpuLoad * 100 }
        let lo = Int((values.min() ?? latest * 100).rounded())
        let hi = Int((values.max() ?? latest * 100).rounded())
        return
            "Currently \(Int((latest * 100).rounded())) percent. Window range \(lo) to \(hi) percent."
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: points.map { TrendPoint(date: $0.date, value: $0.cpuLoad * 100) },
                    color: currentLevel.color, filled: true)
            ],
            yDomain: 0...100,
            yTicks: [0, 60, 85, 100],
            rules: [
                TrendRule(value: 60, label: "Busy", color: .orange),
                TrendRule(value: 85, label: "Heavy", color: .red),
            ],
            showsTimeAxis: showsTimeAxis
        )
        .accessibilityLabel("Total CPU timeline")
        .accessibilityValue(accessibilitySummary)
    }
}
