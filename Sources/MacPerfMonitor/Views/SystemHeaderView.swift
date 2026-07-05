import MacPerfMonitorCore
import SwiftUI

/// The processor summary shown above the process list — the CPU context the
/// table itself lacks. A total-CPU card (with a two-hour trend), the live
/// per-core utilisation grid, and the load average, plus a slim coverage line
/// specific to this tab. (Memory has its own full breakdown on the Dashboard.)
struct SystemHeaderView: View {
    let snapshot: Sampler.Snapshot?
    @EnvironmentObject private var helper: HelperManager
    @EnvironmentObject private var model: SamplerModel
    @EnvironmentObject private var appState: AppState

    /// Last two hours of raw system history backing the total-CPU trend
    /// sparkline, reloaded periodically so the left edge keeps pace; the live
    /// snapshot is appended on the right edge each tick for immediacy.
    @State private var history: [SystemHistoryPoint] = []

    var body: some View {
        // Prefer the smoothed live CPU (matches the Dashboard's Processor panel),
        // falling back to the snapshot's raw sample before the first smooth lands.
        let cpu = model.smoothedCPU ?? snapshot?.cpu
        let cards = CPUMetrics.cards(cpu: cpu, history: trendPoints, span: 2 * 3600)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("PROCESSOR")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let count = cpu?.cores.count, count > 0 {
                    Text("\(count) cores")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // Total CPU · live per-core grid · load average. The grid is the
            // dynamic centrepiece, updating each tick with the rest of the header.
            HStack(alignment: .top, spacing: 12) {
                if let usage = cards.first {
                    MetricCard(data: usage).frame(maxWidth: .infinity)
                }
                CPUCoreCard(cores: cpu?.cores ?? []).frame(maxWidth: .infinity)
                if cards.count > 1 {
                    MetricCard(data: cards[1]).frame(maxWidth: .infinity)
                }
            }
            // Cap the row at the tallest card's natural height (the core grid) so it
            // sizes to content instead of grabbing a share of the window.
            .fixedSize(horizontal: false, vertical: true)
            coverageLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear(perform: reload)
        .onChange(of: model.displayProcessesVersion) {
            if appState.mainWindowVisible { reload() }
        }
    }

    private func reload() {
        // Downsampled on the model's read queue: the cards re-derive their six
        // metric series from this array on every table tick (the live point is
        // appended each time), so holding the raw 3,600-sample window here
        // would re-map and re-bucket all of it dozens of times a minute — and
        // thinning it on the main thread per reload was itself a per-tick cost.
        model.loadRecentSystemHistory(downsampledTo: 240) { self.history = $0 }
    }

    // MARK: - Trend series

    /// The two-hour history with the current live sample appended on the right
    /// edge, falling back to the in-memory buffer until the first DB load lands.
    private var trendPoints: [SystemHistoryPoint] {
        var pts = history
        if pts.isEmpty {
            pts = model.systemHistory.elements().map(Self.point(from:))
        }
        if let s = snapshot?.system {
            let live = Self.point(from: s)
            if let last = pts.last {
                if live.date > last.date { pts.append(live) }
            } else {
                pts.append(live)
            }
        }
        return pts
    }

    private static func point(from s: SystemSample) -> SystemHistoryPoint {
        SystemHistoryPoint(
            date: s.timestamp,
            pressurePercent: s.pressurePercent,
            appMemory: s.appMemory,
            wired: s.wired,
            compressed: s.compressed,
            cachedFiles: s.cachedFiles,
            swapUsed: s.swapUsed,
            cpuLoad: s.cpuLoad
        )
    }

    // MARK: - Coverage

    /// A slim line beneath the cards: process count, plus an honest note and a
    /// one-tap fix when some processes are not fully readable.
    @ViewBuilder
    private var coverageLine: some View {
        if let snapshot {
            HStack(spacing: 8) {
                Text("\(snapshot.processes.count) processes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if snapshot.unreadableProcessCount > 0 {
                    Text("\u{2022}")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("\(snapshot.unreadableProcessCount) not readable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(
                            "Some processes are owned by other users or the system, so macOS does not allow \(AppInfo.displayName) to read their full memory figures."
                        )
                    coverageAction
                }
                Spacer()
            }
        }
    }

    /// A one-tap shortcut to close the coverage gap, shown only when the helper
    /// can actually help (it is available but not yet active).
    @ViewBuilder
    private var coverageAction: some View {
        switch helper.coverage {
        case .disabled:
            Button("Enable full coverage\u{2026}") { helper.enable() }
                .buttonStyle(.link)
                .font(.caption2)
        case .requiresApproval:
            Button("Approve in Settings\u{2026}") { helper.openApprovalSettings() }
                .buttonStyle(.link)
                .font(.caption2)
        case .enabled, .unavailable:
            EmptyView()
        }
    }
}

/// The live per-core utilisation grid presented as a header card, matching the
/// metric cards' chrome so it sits in the row beside them. Unlike a metric card
/// it has no detail modal — the live bars and the cluster-average legend (carried
/// by `CoreGridView`) are the content. Redraws each tick with the header, so the
/// bars move in real time.
private struct CPUCoreCard: View {
    let cores: [CoreUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(CoreKind.performance.accent)
                    .frame(width: 6, height: 6)
                Text("CORES")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            CoreGridView(cores: cores, barHeight: 40)
        }
        // Match the metric cards' fill so all three header cards are one height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
