import MacPerfMonitorCore
import SwiftUI

/// A compact toolbar control — present on every tab — that sets the GLOBAL refresh
/// interval: how often the heavy per-process scan runs and the in-window charts,
/// table, and cards re-render. Slower intervals lower CPU use sharply (the default
/// is a deliberately light 10 s); the menu-bar read-outs stay live at 1 Hz
/// regardless.
///
/// Backed by the shared `tableIntervalKey`, so it stays in lockstep with the same
/// setting in Settings, and the app applies any change through its
/// `UserDefaults.didChangeNotification` wiring. It reads only `@AppStorage`, not
/// the sampler, so placing it in the window toolbar does not re-render the tab
/// host on every sample.
struct RefreshIntervalControl: View {
    @AppStorage(SamplerModel.tableIntervalKey) private var interval =
        SamplerModel.defaultTableInterval

    var body: some View {
        Menu {
            Picker("Refresh interval", selection: $interval) {
                ForEach(SamplerModel.tableIntervalChoices, id: \.self) { seconds in
                    Text(SamplerModel.tableIntervalLabel(seconds)).tag(seconds)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // Explicit icon + value so the toolbar shows the current interval
            // rather than collapsing a Label down to the glyph alone.
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text(SamplerModel.tableIntervalLabel(interval))
                    .font(.callout.monospacedDigit())
            }
        }
        .fixedSize()
        .help(
            "How often the charts and process list refresh. A slower interval uses noticeably "
                + "less CPU; the menu-bar read-outs stay live."
        )
    }
}
