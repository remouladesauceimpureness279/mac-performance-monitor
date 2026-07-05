import Charts
import MacPerfMonitorCore
import SwiftUI

/// How a metric's values read on the detail chart's Y axis and in read-outs:
/// as a byte size, or as a 0...100 percentage/index.
enum MetricUnit {
    case bytes
    case percent

    func format(_ value: Double) -> String {
        switch self {
        case .bytes: return ByteFormat.string(UInt64(max(0, value.rounded())))
        case .percent: return "\(Int(value.rounded()))%"
        }
    }
}

/// The plain-language explanation shown in a metric's detail modal: what the
/// figure means, and exactly how MacPerfMonitor calculates it.
struct MetricExplanation {
    let meaning: String
    let calculation: String
}

/// One memory figure rendered as a card: a label, the current value, and a
/// trend sparkline. Clicking a card opens a detail modal with a larger, axed
/// chart and the explanation. This single design is shared by the Dashboard
/// headline row and the Processes-tab header, so the same figures are presented
/// the same way on both screens.
struct MetricCardData: Identifiable {
    let label: String
    let value: String?
    var tint: Color = .primary
    /// Timestamped trend, downsampled for a clean line. Drives both the small
    /// sparkline (values only) and the detail modal's axed chart (with dates).
    var samples: [MetricSample] = []
    /// A point-in-time gauge shown instead of a sparkline, for metrics that are a
    /// *state* rather than a trend (e.g. battery wear, which barely moves over the
    /// window so a line would read as flat/broken). Takes precedence over
    /// `samples` in the card's graph area.
    var gauge: MetricGauge? = nil
    /// How the values read on the detail chart's axis.
    var unit: MetricUnit = .bytes
    /// Optional small secondary text shown just after the value (for example a
    /// reference total beside the free figure). Rendered in a quieter style so
    /// it does not compete with the headline value.
    var detail: String? = nil
    /// Short hover tooltip; the richer story lives in `explanation`.
    var help: String? = nil
    /// Long-form explanation shown in the detail modal opened on click.
    var explanation: MetricExplanation? = nil

    var id: String { label }
}

/// A point-in-time gauge for a state metric: a horizontal bar filled to
/// `fraction` (0...1), with an optional tick marking a meaningful threshold (e.g.
/// battery's 80% service line). Shown in a card's graph area in place of a
/// sparkline.
struct MetricGauge: Equatable {
    var fraction: Double
    var threshold: Double? = nil
}

/// A single metric card. The fixed-height graph area keeps every card the same
/// height so a row or grid stays tidy. The whole card is a button that opens a
/// detail modal explaining the figure and showing its chart in full.
struct MetricCard: View {
    let data: MetricCardData
    /// When true, the graph area shows a spinner in place of the sparkline while
    /// the page's range data reloads. Gauges (live state) are left as-is.
    var loading: Bool = false

    @State private var showDetail = false
    @State private var hovering = false

    var body: some View {
        Button {
            if data.explanation != nil { showDetail = true }
        } label: {
            cardBody
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(data.help ?? "")
        .accessibilityLabel(
            "\(data.label): \(data.value ?? "unavailable")"
                + (data.detail.map { ", \($0)" } ?? "")
        )
        .accessibilityHint(
            data.explanation != nil ? "Opens an explanation of this figure." : ""
        )
        .sheet(isPresented: $showDetail) {
            MetricDetailSheet(data: data)
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Label row: a small tint dot acts as a series marker, the label is a
            // quiet uppercase caption, and the info glyph (only when there is an
            // explanation to open) sits at the trailing edge.
            HStack(spacing: 5) {
                Circle()
                    .fill(data.tint)
                    .frame(width: 6, height: 6)
                Text(data.label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if data.explanation != nil {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            // The number does the talking: a precise, neutral, monospaced value
            // rather than a loud colour. Any reference detail trails quietly.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(data.value ?? "—")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let detail = data.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Group {
                if let gauge = data.gauge {
                    MetricGaugeBar(
                        fraction: gauge.fraction, threshold: gauge.threshold, tint: data.tint)
                } else if loading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if data.samples.count >= 2 {
                    Sparkline(values: data.samples.map(\.value), lineWidth: 1.5)
                        .tint(data.tint)
                } else {
                    Color.clear
                }
            }
            .frame(height: 28)
            .accessibilityHidden(true)
        }
        // Fill the row's height so cards of differing content (e.g. beside the
        // Processes-tab core grid) come out the same height; in an equal-height row
        // like the Dashboard's this is a no-op.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(hovering ? 0.5 : 0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    hovering ? data.tint.opacity(0.45) : Color.primary.opacity(0.08),
                    lineWidth: hovering ? 1 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// The bar drawn for a `MetricGauge`: a quiet track, a tinted fill to the
/// fraction, and a thin tick at the threshold so "where am I on the scale" and
/// "how close to the limit" both read at a glance — appropriate for a value that
/// is a state, not a trend.
private struct MetricGaugeBar: View {
    let fraction: Double
    let threshold: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18)).frame(height: 7)
                Capsule().fill(tint).frame(width: max(3, w * f), height: 7)
                if let threshold {
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1.5, height: 13)
                        .offset(x: w * min(1, max(0, threshold)) - 0.75)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

/// The standard memory cards laid out responsively: a single row when there is
/// room, otherwise a wrapping grid. An optional slim header above the row names
/// the group and reports total installed RAM — the denominator for the whole
/// breakdown — in one stable place, so no individual card has to carry it. Used
/// verbatim by the Dashboard and the Processes header so the two screens match.
struct MetricCardsRow: View {
    let cards: [MetricCardData]
    /// Total installed RAM; when set, shown in the header as "X installed".
    var totalRAM: UInt64? = nil
    var gridColumns: Int = 3
    /// Forwarded to each card: shows a spinner in the graph area while the page's
    /// range data reloads.
    var loading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let totalRAM {
                HStack(spacing: 6) {
                    Text("MEMORY")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(ByteFormat.string(totalRAM)) installed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(ByteFormat.string(totalRAM)) installed RAM")
                }
            }
            cardsLayout
        }
    }

    private var cardsLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(cards) { MetricCard(data: $0, loading: loading) }
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: gridColumns),
                alignment: .leading, spacing: 12
            ) {
                ForEach(cards) { MetricCard(data: $0, loading: loading) }
            }
        }
        // Size the row to the tallest card's NATURAL height, not the space offered.
        // The cards fill height to match each other (so a mixed row like the
        // Processes header lines up), but the row itself never grows past that —
        // without this the maxHeight-filling cards make the row greedy.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Overlays a small spinner over a chart (dimming the chart) while its range
/// data reloads, so a range change shows progress instead of appearing to hang.
/// Shared by the Dashboard and Energy timelines. Only flips when the page marks
/// itself as awaiting a new range, so the silent periodic refresh never trips it.
extension View {
    func chartReloading(_ isLoading: Bool) -> some View {
        self
            .opacity(isLoading ? 0.3 : 1)
            .overlay { if isLoading { ProgressView().controlSize(.small) } }
            .animation(.easeInOut(duration: 0.15), value: isLoading)
    }
}

/// The modal shown when a metric card is clicked: the figure, a larger chart
/// with time and value axes, and a plain-language explanation of what the
/// figure means and how MacPerfMonitor calculates it.
struct MetricDetailSheet: View {
    let data: MetricCardData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            MetricDetailChart(samples: data.samples, tint: data.tint, unit: data.unit)
                .frame(height: 220)
            if let explanation = data.explanation {
                explanationSection("What it means", explanation.meaning)
                explanationSection("How it's calculated", explanation.calculation)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(data.tint)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(data.label)
                    .font(.title2.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(data.value ?? "—")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(data.tint)
                    if let detail = data.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    private func explanationSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A larger line chart with visible time and value axes, used in the metric
/// detail modal. Lines only, solid gridlines and a framed plot for a clean,
/// instrument-like read; the Y axis is formatted in the metric's own units and
/// the X axis label format widens with the span shown.
struct MetricDetailChart: View {
    let samples: [MetricSample]
    var tint: Color
    var unit: MetricUnit

    var body: some View {
        if samples.count < 2 {
            emptyState
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Value", sample.value)
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .foregroundStyle(tint)
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.28))
                AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(unit.format(v))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.14))
                AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: xFormat)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.border(Color.secondary.opacity(0.22), width: 0.5)
        }
        .accessibilityLabel("Trend chart")
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary.opacity(0.3))
            .overlay(
                Text("Building history\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            )
    }

    /// Y domain top: a percentage/index uses its true 0...100 scale so the
    /// danger bands stay meaningful; a byte metric scales to its own peak with a
    /// little headroom so the line is not crushed against the floor.
    private var yMax: Double {
        let peak = samples.map(\.value).max() ?? 0
        switch unit {
        case .percent: return 100
        case .bytes: return max(peak * 1.12, 1)
        }
    }

    /// Widen the X label format as the window grows, so a long span does not
    /// show ambiguous repeating clock times.
    private var xFormat: Date.FormatStyle {
        guard let first = samples.first?.date, let last = samples.last?.date else {
            return .dateTime.hour().minute()
        }
        let span = last.timeIntervalSince(first)
        if span <= 10 * 60 { return .dateTime.minute().second() }
        if span <= 26 * 3600 { return .dateTime.hour().minute() }
        return .dateTime.month(.abbreviated).day()
    }
}

/// Builds the standard set of memory metric cards from the current sample and a
/// history window. Both screens call this so the metrics, colours, ordering,
/// tooltips and explanations are defined exactly once.
enum MemoryMetrics {
    static func cards(
        system: SystemSample?, history: [SystemHistoryPoint], span: TimeInterval, points: Int = 80
    ) -> [MetricCardData] {
        let total = system?.totalRAM ?? 0
        func samples(_ value: @escaping (SystemHistoryPoint) -> Double) -> [MetricSample] {
            downsample(
                history.map { MetricSample(date: $0.date, value: value($0)) },
                span: span, to: points)
        }
        return [
            MetricCardData(
                label: "Pressure",
                value: system.map { "\(Int($0.pressurePercent.rounded()))%" },
                tint: system.map { $0.pressureLevel.color } ?? .secondary,
                samples: samples { $0.pressurePercent },
                unit: .percent,
                help:
                    "How hard macOS is working to keep memory available, 0 to 100. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "macOS's own read on how hard the memory system is working, on a 0 to 100 scale. "
                        + "0 to 33 is green and comfortable, 34 to 66 is yellow as it compresses and caches to cope, "
                        + "and 67 to 100 is red, where it swaps to disk and apps can slow down. It is the single number to watch.",
                    calculation:
                        "The colour band comes from the kernel's memory-pressure level. Within that band the exact "
                        + "position is set by how loaded memory is: 50 percent from compression (compressed memory over RAM, "
                        + "full at half your RAM), 30 percent from swap (swap over RAM, full at one times your RAM), and "
                        + "20 percent from how fast compressed plus swap is rising. The value is the band floor plus that "
                        + "signal times 33.")
            ),
            MetricCardData(
                label: "Free",
                value: system.map { ByteFormat.string(freeBytesNow($0)) },
                tint: .green,
                samples: samples { freeBytes($0, total: total) },
                unit: .bytes,
                help: "RAM not held by any category below, ready for new work. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "RAM that is not currently held by the four categories below, so it is immediately available "
                        + "for new work. macOS deliberately keeps this low by using spare RAM as a file cache, so a small "
                        + "free figure is normal and healthy, not a problem.",
                    calculation:
                        "Your total installed RAM minus the four measured categories: free = total minus wired, app, "
                        + "compressed and cached files, never below zero. Derived this way so the parts always reconcile "
                        + "to your installed RAM exactly. This is the same as the dashboard's 'Free and available' slice."
                )
            ),
            MetricCardData(
                label: "App",
                value: system.map { ByteFormat.string($0.appMemory) },
                tint: .blue,
                samples: samples { Double($0.appMemory) },
                unit: .bytes,
                help: "Memory apps are actively using, not reclaimable cache. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "Memory that apps are actively using and that is not a reclaimable file cache. It is the closest "
                        + "match to Activity Monitor's 'App Memory'.",
                    calculation:
                        "Anonymous, app-allocated memory minus the part the system can drop on demand: app = max(internal "
                        + "minus purgeable, 0), read from the kernel's VM statistics and multiplied by the page size."
                )
            ),
            MetricCardData(
                label: "Compressed",
                value: system.map { ByteFormat.string($0.compressed) },
                tint: .orange,
                samples: samples { Double($0.compressed) },
                unit: .bytes,
                help: "RAM the compressor has squeezed to fit more in memory. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "Memory the compressor has squeezed so more fits in RAM without going to disk. A little is normal; "
                        + "a lot, and rising, is an early sign of pressure.",
                    calculation:
                        "The compressor's page count times the page size: compressed = compressor page count times page "
                        + "size, read from the kernel's VM statistics.")
            ),
            MetricCardData(
                label: "Cached files",
                value: system.map { ByteFormat.string($0.cachedFiles) },
                tint: .teal,
                samples: samples { Double($0.cachedFiles) },
                unit: .bytes,
                help:
                    "Spare RAM used as a benign file cache, released on demand. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "Spare RAM that macOS is using to keep recently used files handy. This is not a problem: it is "
                        + "released the instant anything needs the space, so it should never be a cause for concern.",
                    calculation:
                        "File-backed pages plus purgeable pages, times the page size: cached = (external plus purgeable) "
                        + "times page size, from the kernel's VM statistics.")
            ),
            MetricCardData(
                label: "Swap",
                value: system.map { ByteFormat.string($0.swapUsed) },
                tint: .purple,
                samples: samples { Double($0.swapUsed) },
                unit: .bytes,
                help: "Memory moved out to disk because RAM filled up. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "Data the system has moved out to disk because RAM filled up. It is distinct from compression. "
                        + "A flat line at zero is ideal; a sustained climb under pressure is the real warning sign.",
                    calculation:
                        "Taken straight from the kernel's swap usage figure (vm.swapusage.xsu_used). Swap lives on disk, "
                        + "not in RAM, so it is shown on its own and is not part of the total-RAM split."
                )
            ),
        ]
    }

    /// Live "free and available": total RAM minus the four measured categories,
    /// so the headline value matches its own chart and the dashboard taxonomy.
    private static func freeBytesNow(_ s: SystemSample) -> UInt64 {
        let measured = s.wired &+ s.appMemory &+ s.compressed &+ s.cachedFiles
        return s.totalRAM > measured ? s.totalRAM - measured : 0
    }

    /// Free RAM derived the same way over history, as a Double for charting.
    private static func freeBytes(_ p: SystemHistoryPoint, total: UInt64) -> Double {
        let measured = p.wired &+ p.appMemory &+ p.compressed &+ p.cachedFiles
        return Double(total > measured ? total - measured : 0)
    }

    /// Average timestamped samples down to roughly `maxCount` points for a clean
    /// line, bucketed by ABSOLUTE TIME on a fixed grid (`span / maxCount` wide,
    /// anchored to the epoch) so the sparkline's shape is STABLE: a sample's
    /// bucket depends only on its timestamp, not the array length, so a new tick
    /// only changes the rightmost bucket and the line slides left rather than
    /// reshaping. Each bucket is dated to its grid start so timestamps (used by
    /// the detail modal's time axis) stay correct and never wander.
    static func downsample(
        _ samples: [MetricSample], span: TimeInterval, to maxCount: Int
    )
        -> [MetricSample]
    {
        guard samples.count > maxCount, maxCount > 0, span > 0 else { return samples }
        let width = span / Double(maxCount)
        func bucketIndex(_ s: MetricSample) -> Double {
            (s.date.timeIntervalSince1970 / width).rounded(.down)
        }
        var result: [MetricSample] = []
        result.reserveCapacity(maxCount + 1)
        var i = 0
        while i < samples.count {
            let b = bucketIndex(samples[i])
            var j = i
            var sum = 0.0
            while j < samples.count, bucketIndex(samples[j]) == b {
                sum += samples[j].value
                j += 1
            }
            result.append(
                MetricSample(
                    date: Date(timeIntervalSince1970: b * width), value: sum / Double(j - i)))
            i = j
        }
        return result
    }
}

/// The scalar CPU cards for the Processes-tab header, built as the same
/// `MetricCardData` the memory header uses so the two read alike. The per-core
/// grid is a separate card (`CPUCoreCard`); these are the total-usage and
/// load-average figures that flank it. The total-CPU sparkline comes from the
/// persisted `cpuLoad` history; the headline, split, and load come from the live
/// (smoothed) sample.
enum CPUMetrics {
    static func cards(
        cpu: CPUSample?, history: [SystemHistoryPoint], span: TimeInterval, points: Int = 80
    ) -> [MetricCardData] {
        let usageSamples = MemoryMetrics.downsample(
            history.map { MetricSample(date: $0.date, value: $0.cpuLoad * 100) },
            span: span, to: points)
        let coreCount = cpu?.cores.count ?? 0
        return [
            MetricCardData(
                label: "CPU Usage",
                value: cpu.map { "\(Int(($0.totalUsage * 100).rounded()))%" },
                tint: CPULevel(fraction: cpu?.totalUsage ?? 0).color,
                samples: usageSamples,
                unit: .percent,
                detail: cpu.map {
                    "\(Int(($0.userFraction * 100).rounded()))% user · "
                        + "\(Int(($0.systemFraction * 100).rounded()))% sys"
                },
                help: "Share of total CPU capacity in use across every core. Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "How much of your Mac's total CPU capacity is in use right now, across all cores, "
                        + "from 0 to 100 percent. 100 percent means every logical core is fully busy.",
                    calculation:
                        "The busy fraction of each logical core (user plus system time over the tick, from the "
                        + "kernel's per-core tick counters) averaged across all cores, times 100. The split below "
                        + "is that same total divided into user-mode and system-mode (kernel) time."
                )
            ),
            MetricCardData(
                label: "Load average",
                value: cpu.map { String(format: "%.2f", $0.loadAverage1) },
                tint: loadTint(cpu),
                gauge: cpu.map {
                    MetricGauge(
                        fraction: coreCount > 0 ? min(1, $0.loadAverage1 / Double(coreCount)) : 0)
                },
                unit: .percent,
                detail: cpu.map {
                    String(format: "%.2f · %.2f", $0.loadAverage5, $0.loadAverage15)
                },
                help:
                    "Processes competing to run, averaged over 1 minute (5 and 15-minute alongside). Click for details.",
                explanation: MetricExplanation(
                    meaning:
                        "The run-queue length — roughly how many processes are competing to run — averaged over "
                        + "the last minute, with the 5 and 15-minute figures beside it. A load near your core count "
                        + "(\(coreCount > 0 ? String(coreCount) : "the number of cores")) means the CPU is fully "
                        + "subscribed; well above it means work is queuing.",
                    calculation:
                        "Read straight from the kernel's load averages (the same numbers `uptime` reports). The bar "
                        + "shows the 1-minute load relative to your logical core count, full at one process per core."
                )
            ),
        ]
    }

    /// Green/amber/red by 1-minute load relative to the core count: comfortable
    /// below ~0.7×, subscribed up to 1×, queuing above.
    private static func loadTint(_ cpu: CPUSample?) -> Color {
        guard let cpu, !cpu.cores.isEmpty else { return .secondary }
        switch cpu.loadAverage1 / Double(cpu.cores.count) {
        case ..<0.7: return .green
        case ..<1.0: return .orange
        default: return .red
        }
    }
}
