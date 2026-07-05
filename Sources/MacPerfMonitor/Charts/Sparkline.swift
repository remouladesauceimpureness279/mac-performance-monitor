import SwiftUI

/// A tiny, lightweight line sparkline drawn with a `Path` rather than Swift
/// Charts, so it is cheap enough to render ten at a time in the menubar panel.
/// Values are normalised to their own min/max; a flat series draws a centre line.
struct Sparkline: View {
    var values: [Double]
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let points = normalisedPoints(in: geo.size)
            if points.count >= 2 {
                Path { path in
                    path.move(to: points[0])
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(
                    .tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    private func normalisedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let range = maxValue - minValue
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let x = CGFloat(index) * stepX
            // Flat series: draw through the vertical centre.
            let fraction = range > 0 ? (value - minValue) / range : 0.5
            let y = size.height - CGFloat(fraction) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}
