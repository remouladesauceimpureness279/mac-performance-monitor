import SwiftUI

/// A two-region page layout: a wide, flexible main column on the left for the
/// primary timelines, and a fixed-width "stats rail" on the right for the
/// compact read-out panels. The Dashboard and Battery tabs both use it so the
/// two pages share one structure and density, putting horizontal space to work
/// instead of stacking every panel full-width down a single column.
///
/// The enclosing view supplies its own `ScrollView` and outer padding; this only
/// arranges the two columns. The window's 860 pt minimum keeps the main column
/// comfortably wide even at the rail's fixed width, so no narrow fallback is
/// needed.
struct MainRailLayout<Main: View, Rail: View>: View {
    /// Fixed width of the right-hand stats rail.
    static var railWidth: CGFloat { 300 }

    @ViewBuilder var main: () -> Main
    @ViewBuilder var rail: () -> Rail

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                main()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 16) {
                rail()
            }
            .frame(width: Self.railWidth)
        }
    }
}
