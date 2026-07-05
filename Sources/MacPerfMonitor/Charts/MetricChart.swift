import Charts
import SwiftUI

/// One point on a process-detail metric chart. `id` is the timestamp, which is
/// unique within a raw series (the table's primary key prevents duplicates).
struct MetricSample: Identifiable, Equatable {
    var date: Date
    var value: Double
    var id: Date { date }
}

/// A compact, reusable area+line chart for a single per-process metric
/// (footprint, CPU, file descriptors, disk throughput). The Y axis is formatted
/// by the caller so each metric reads in its natural units. Hovering or dragging
/// over the plot scrubs the series, pinning a marker and a value read-out at the
/// nearest sample.
struct MetricChart: View, Equatable {
    let samples: [MetricSample]
    var tint: Color = .blue
    /// Floor for the Y domain's top, so a flat-at-zero series still renders a
    /// sensible axis rather than collapsing to a single line.
    var minTop: Double = 1
    /// Width in seconds of the window this chart represents (the selected range,
    /// for example 1800 for "30 min"). The downsampling bucket width is derived
    /// from this FIXED span — never from the data's own extent — so the buckets
    /// stay anchored to the clock as the live window advances. That is what
    /// keeps the chart from changing shape on every tick.
    var windowSeconds: TimeInterval = 30 * 60
    /// VoiceOver name for this chart, e.g. "Memory footprint". Supplied by the
    /// caller because only it knows which metric the series represents.
    var accessibilityTitle: String = "Trend"
    let yFormat: (Double) -> String

    /// Time the user is scrubbing over, or nil when the cursor is away.
    @State private var scrubDate: Date?

    /// Re-render (and so re-downsample + re-lay-out the Chart) only when the data
    /// or framing actually change — not on the 1 s tick that re-renders the
    /// enclosing detail view while this chart's `samples` are unchanged (they
    /// refresh on the ~2 s data cadence). The series is append-only or fully
    /// reloaded, so count + endpoints uniquely identify it without an O(n) scan;
    /// `yFormat` (a closure) and `scrubDate` (@State, handled separately) are
    /// excluded. Halves-or-better the chart layout cost on every live tab.
    static func == (lhs: MetricChart, rhs: MetricChart) -> Bool {
        lhs.windowSeconds == rhs.windowSeconds
            && lhs.tint == rhs.tint
            && lhs.minTop == rhs.minTop
            && lhs.samples.count == rhs.samples.count
            && lhs.samples.first == rhs.samples.first
            && lhs.samples.last == rhs.samples.last
    }

    /// Cap on the number of points actually drawn. A dense window (a 30-minute
    /// or longer span holds hundreds to thousands of 2-second samples) is
    /// collapsed to at most this many points, so the line stays a crisp trend
    /// instead of smearing into noise and the live edge does not shimmer.
    private static let maxPoints = 160

    /// Width of one downsampling bucket, fixed by the span and the point cap so
    /// it does not move as data accrues. Because it is anchored to the clock,
    /// past buckets are settled the moment they fall behind the live edge.
    private var bucketWidth: TimeInterval { windowSeconds / Double(Self.maxPoints) }

    /// The raw samples split into contiguous runs, broken wherever two samples
    /// are far enough apart to mean data is missing (the app was asleep, the
    /// process was briefly unreadable, or it was relaunched). Splitting the RAW
    /// series — before downsampling — is deliberate: the downsampled points sit
    /// at each bucket's peak, whose timestamps jitter within the bucket, so
    /// judging gaps on them would invent breaks in spiky metrics like CPU and
    /// disk I/O. Each run is then downsampled on its own, so a real gap is left
    /// blank rather than bridged by a misleading straight diagonal.
    private var segments: [[MetricSample]] {
        Self.split(samples, gapThreshold: gapThreshold)
            .map { Self.stableDownsample($0, bucketWidth: bucketWidth) }
    }

    /// Every drawn point, flattened. The Y domain, the scrub hit-testing and the
    /// X-axis range all read this, so they always agree with the line.
    private var plotted: [MetricSample] {
        segments.flatMap { $0 }
    }

    /// A gap is a jump well beyond the normal sampling cadence. Raw rows are
    /// change-gated, so a process's spacing is bimodal: ~1 s while it is changing,
    /// but up to a full heartbeat bucket (~60 s, the guaranteed idle cadence)
    /// while it sits flat. The median tracks the dense active spacing, so it would
    /// wrongly break the line across every idle heartbeat and scatter a flat
    /// process into dots. Use a high percentile instead — it tracks the idle
    /// heartbeat spacing — times a factor, with a floor comfortably above the
    /// default heartbeat, so an idle stretch stays a connected (flat) line and
    /// only a genuine hole (the Mac asleep, the app not running) reads as a gap.
    private var gapThreshold: TimeInterval {
        guard samples.count > 2 else { return .greatestFiniteMagnitude }
        var deltas: [TimeInterval] = []
        deltas.reserveCapacity(samples.count - 1)
        for i in 1..<samples.count {
            deltas.append(samples[i].date.timeIntervalSince(samples[i - 1].date))
        }
        deltas.sort()
        let p90 = deltas[min(deltas.count - 1, (deltas.count * 9) / 10)]
        return max(p90 * 3, 150)
    }

    /// Sit the tallest value near the top of the plot with a little headroom,
    /// rather than crushing the data onto the floor or jamming the peak into the
    /// ceiling. The floor only applies when the series is near zero.
    private var maxValue: Double {
        let peak = plotted.map(\.value).max() ?? minTop
        return max(peak * 1.12, minTop)
    }

    /// A spoken summary for VoiceOver: the latest value and the peak, formatted
    /// in the metric's own units via the caller-supplied `yFormat`.
    private var accessibilitySummary: String {
        guard let latest = samples.last?.value else { return "No data yet." }
        let peak = samples.map(\.value).max() ?? latest
        return "Currently \(yFormat(latest)). Peak \(yFormat(peak)) over the shown window."
    }

    /// The sample closest to the scrub time, used to pin the marker and label.
    private var scrubSample: MetricSample? {
        guard let scrubDate else { return nil }
        return plotted.min {
            abs($0.date.timeIntervalSince(scrubDate)) < abs($1.date.timeIntervalSince(scrubDate))
        }
    }

    /// Tick positions at round "time ago" offsets back from the live (right) edge,
    /// so the axis reads how long ago each point was — now, 15m, 30m, 1h — rather
    /// than absolute clock times. The old clock format was the confusing part: for
    /// a short window it was bare mm:ss ("30:45"), which reads like a stopwatch,
    /// not a time of day.
    private var xTicks: [Date] {
        guard let last = plotted.last?.date, let first = plotted.first?.date else { return [] }
        let step = Self.niceStep(windowSeconds)
        var ticks: [Date] = []
        var offset: TimeInterval = 0
        while true {
            let d = last.addingTimeInterval(-offset)
            if d < first.addingTimeInterval(-0.5) { break }
            ticks.append(d)
            offset += step
            if ticks.count >= 9 { break }  // safety bound
        }
        return ticks
    }

    /// A round tick interval giving roughly four labels across the window.
    private static func niceStep(_ window: TimeInterval) -> TimeInterval {
        let target = max(window, 1) / 4
        let candidates: [TimeInterval] = [
            15, 30, 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60,
            3600, 2 * 3600, 3 * 3600, 6 * 3600, 12 * 3600,
            86_400, 2 * 86_400, 7 * 86_400,
        ]
        return candidates.first { $0 >= target } ?? target
    }

    /// "now" / "15m" / "2h" / "3d": how far a tick sits behind the live edge.
    private static func agoLabel(_ date: Date, reference: Date) -> String {
        let delta = reference.timeIntervalSince(date)
        if delta < 45 { return "now" }
        if delta < 3600 { return "\(Int((delta / 60).rounded()))m" }
        if delta < 48 * 3600 { return "\(Int((delta / 3600).rounded()))h" }
        return "\(Int((delta / 86_400).rounded()))d"
    }

    var body: some View {
        Chart {
            // A single crisp line, no fill: a clean instrument-style plot rather
            // than a decorative shaded area. Linear segments join the samples
            // honestly, so the live edge never hooks into the smoothed "curve"
            // that monotone interpolation drew through the last few points. Each
            // contiguous run is its own series so the line breaks — rather than
            // bridging a straight diagonal — wherever data is missing.
            ForEach(Array(segments.enumerated()), id: \.offset) { segmentIndex, segment in
                ForEach(Array(segment.enumerated()), id: \.offset) { _, sample in
                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Value", sample.value),
                        series: .value("Segment", segmentIndex)
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(tint)
                }

                // A lone sample stranded between two gaps would draw no line at
                // all, so mark it with a dot to keep isolated readings visible.
                if segment.count == 1, let point = segment.first {
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(tint)
                    .symbolSize(18)
                }
            }

            if let scrubSample {
                RuleMark(x: .value("Time", scrubSample.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top,
                        spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        scrubLabel(scrubSample)
                    }

                PointMark(
                    x: .value("Time", scrubSample.date),
                    y: .value("Value", scrubSample.value)
                )
                .foregroundStyle(tint)
                .symbolSize(40)
            }
        }
        .chartYScale(domain: 0...maxValue)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.28))
                AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(yFormat(v))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.14))
                AxisTick(length: 4, stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                AxisValueLabel {
                    if let d = value.as(Date.self), let ref = plotted.last?.date {
                        Text(Self.agoLabel(d, reference: ref))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.border(Color.secondary.opacity(0.22), width: 0.5)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateScrub(at: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            scrubDate = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                updateScrub(at: value.location, proxy: proxy, geometry: geometry)
                            }
                            .onEnded { _ in scrubDate = nil }
                    )
            }
        }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilitySummary)
        .reducedMotionAware()
    }

    /// Map a cursor location in the overlay to a time on the X axis.
    private func updateScrub(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geometry[plotFrame].origin
        let x = location.x - origin.x
        guard let date: Date = proxy.value(atX: x) else { return }
        scrubDate = date
    }

    /// Floating read-out pinned above the scrub marker.
    private func scrubLabel(_ sample: MetricSample) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(sample.date, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(yFormat(sample.value))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
        .fixedSize()
    }

    /// Collapse a dense series to one point per fixed time bucket by keeping the
    /// bucket's peak sample. The bucket width is fixed by the caller (derived
    /// from the span, not the data), and the buckets are anchored to absolute
    /// time (epoch / bucketWidth), not to the array index, so they stay put as
    /// the live window advances: appending the newest sample only ever changes
    /// the rightmost bucket while the rest of the line holds perfectly still
    /// instead of changing shape. Keeping each bucket's maximum preserves spikes
    /// (a climbing leak, a CPU burst) rather than averaging them away. A series
    /// already coarser than the bucket width passes straight through untouched.
    private static func stableDownsample(
        _ samples: [MetricSample], bucketWidth: TimeInterval
    )
        -> [MetricSample]
    {
        guard bucketWidth > 0, samples.count > 2 else { return samples }
        func bucketIndex(_ d: Date) -> Int {
            Int((d.timeIntervalSince1970 / bucketWidth).rounded(.down))
        }
        var result: [MetricSample] = []
        result.reserveCapacity(samples.count)
        var currentBucket = bucketIndex(samples[0].date)
        var peak = samples[0]
        for sample in samples.dropFirst() {
            let bucket = bucketIndex(sample.date)
            if bucket == currentBucket {
                if sample.value > peak.value { peak = sample }
            } else {
                result.append(peak)
                currentBucket = bucket
                peak = sample
            }
        }
        result.append(peak)
        return result
    }

    /// Break a series into contiguous runs wherever two consecutive points are
    /// more than `gapThreshold` apart, so a stretch of missing data is left
    /// blank instead of being joined by a straight line across the hole.
    private static func split(
        _ samples: [MetricSample], gapThreshold: TimeInterval
    )
        -> [[MetricSample]]
    {
        guard !samples.isEmpty else { return [] }
        var segments: [[MetricSample]] = []
        var current: [MetricSample] = [samples[0]]
        for sample in samples.dropFirst() {
            if let last = current.last,
                sample.date.timeIntervalSince(last.date) > gapThreshold
            {
                segments.append(current)
                current = [sample]
            } else {
                current.append(sample)
            }
        }
        segments.append(current)
        return segments
    }
}
