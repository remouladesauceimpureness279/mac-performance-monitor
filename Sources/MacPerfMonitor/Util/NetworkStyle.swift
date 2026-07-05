import SwiftUI

/// The network feature's colour and glyph vocabulary, kept beside
/// `BatteryStyle`/`CPUStyle` so every network surface — the menu bar read-out,
/// the menu panel, the dashboard chart — speaks one language. Download and
/// upload use green and red to match the menu-bar activity LEDs (green = down,
/// red = up), so the two directions read the same way across the whole feature.
enum NetworkStyle {
    /// Incoming traffic (download / received).
    static let download = Color.green
    /// Outgoing traffic (upload / sent).
    static let upload = Color.red

    /// SF Symbol for the download direction.
    static let downSymbol = "arrow.down"
    /// SF Symbol for the upload direction.
    static let upSymbol = "arrow.up"
}
