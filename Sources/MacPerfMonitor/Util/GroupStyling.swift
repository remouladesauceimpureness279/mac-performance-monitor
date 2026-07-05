import SwiftUI

/// A thin capsule bar showing a value's share of a maximum — the Groups-tab
/// counterpart to the Insights leaderboard's bar (which is file-private there).
struct GroupProportionBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}
