import MacPerfMonitorCore
import SwiftUI

/// A compact mirrored network-throughput chart for the menu-bar dropdown:
/// download rises upward from a centre line (green), upload drops downward (red),
/// both scaled to their shared peak so the two directions always read clearly —
/// unlike a single overlaid line where upload disappears under a much larger
/// download. Uses the same line + soft-area body as `MenuTrendChart` so all the
/// menu-bar headers share one visual style, with the shared peak rate labelled at
/// the top-left as the marked axis. Canvas-drawn, cheap to redraw at 1 Hz.
struct NetworkUpDownChart: View {
    let download: [Double]
    let upload: [Double]

    var body: some View {
        Canvas { ctx, size in
            // No gutter: the throughput labels are too wide for one, so the shared
            // peak is captioned at the top-left instead.
            let plot = MenuChart.plotRect(in: size, reserveGutter: false)
            let mid = plot.midY
            let halfHeight = plot.height / 2
            let peak = max(download.max() ?? 0, upload.max() ?? 0, 1)
            // Scale tight to the visible peak (a little headroom so it doesn't clip),
            // not the coarse 1–2–5 rounding: the trace then fills the height and the
            // axis adapts as throughput changes, instead of low traffic reading flat.
            let upper = peak * 1.2

            // Centre line + peak caption — the marked axis for both directions.
            var centre = Path()
            centre.move(to: CGPoint(x: plot.minX, y: mid))
            centre.addLine(to: CGPoint(x: plot.maxX, y: mid))
            ctx.stroke(centre, with: .color(MenuChart.gridColor), lineWidth: 0.5)
            ctx.draw(
                Text("\(ByteFormat.rate(peak)) peak").font(MenuChart.labelFont)
                    .foregroundColor(MenuChart.labelColor),
                at: CGPoint(x: plot.minX, y: plot.minY + 4), anchor: .topLeading)

            func points(_ values: [Double], up: Bool) -> [CGPoint] {
                let stepX = values.count >= 2 ? plot.width / CGFloat(values.count - 1) : 0
                return values.enumerated().map { index, value in
                    let fraction = min(1, max(0, value / upper))
                    let height = CGFloat(fraction) * halfHeight
                    return CGPoint(
                        x: plot.minX + CGFloat(index) * stepX, y: up ? mid - height : mid + height)
                }
            }

            if !download.isEmpty {
                MenuChart.drawTrend(
                    ctx, points: points(download, up: true), baselineY: mid,
                    color: NetworkStyle.download, gradientTop: plot.minY, gradientBottom: mid)
            }
            if !upload.isEmpty {
                MenuChart.drawTrend(
                    ctx, points: points(upload, up: false), baselineY: mid,
                    color: NetworkStyle.upload, gradientTop: plot.maxY, gradientBottom: mid)
            }
        }
        .accessibilityHidden(true)
    }
}
