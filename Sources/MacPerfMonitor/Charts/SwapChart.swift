import MacPerfMonitorCore
import SwiftUI

/// A compact swap-usage trend. Bytes on the Y axis, formatted in human units.
/// Drawn with the lightweight Canvas `TrendChart`.
struct SwapChart: View {
    let points: [SystemHistoryPoint]

    private var accessibilitySummary: String {
        guard let latest = points.last?.swapUsed else { return "No data yet." }
        let peak = points.map(\.swapUsed).max() ?? latest
        if peak == 0 { return "No swap in use over the shown window." }
        return
            "Currently \(ByteFormat.string(latest)). Peak \(ByteFormat.string(peak)) over the shown window."
    }

    var body: some View {
        TrendChart(
            series: [
                TrendSeries(
                    points: points.map { TrendPoint(date: $0.date, value: Double($0.swapUsed)) },
                    color: .indigo, filled: true)
            ],
            yFormat: { ByteFormat.string(UInt64(max($0, 0))) }
        )
        .accessibilityLabel("Swap usage trend")
        .accessibilityValue(accessibilitySummary)
    }
}
