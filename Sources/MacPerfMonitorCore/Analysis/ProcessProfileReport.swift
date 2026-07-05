import Foundation

/// A precise, deterministic profile of ONE process for the deep-dive window: CPU
/// and memory metrics with trends, plus a battery of diagnostic checks (see
/// `ProcessDiagnostics`) that say plainly whether the process is healthy, stuck in
/// a loop, not responding, leaking memory, hammering the disk, and so on — each
/// with a short, specific finding. No language model; every figure is measured, so
/// identical input gives identical output. Pure, so it lives in Core and is tested.
public struct ProcessProfileReport: Sendable, Equatable {
    /// The headline verdict (the worst check's severity).
    public var overallStatus: DiagnosticCheck.Status
    public var headline: String

    public var cpuPercent: Double
    public var cpuTrail: [Double]
    public var cpuTrend: String  // "5% → 41%, rising"

    public var memoryBytes: UInt64
    public var memoryTrail: [Double]
    public var memoryTrend: String  // "2.1 → 2.4 GB, growing ~50 MB/min"
    public var memoryPeakBytes: UInt64

    public var checks: [DiagnosticCheck]

    public static func make(
        stats: ProcessProfileStats,
        systemRAMBytes: UInt64,
        sampleOutput: String?,
        fileDescriptors: [OpenFileDescriptor],
        cpuTrail: [Double],
        memoryTrail: [Double],
        diskReadTrail: [Double],
        diskWriteTrail: [Double],
        fdTrail: [Double],
        spanMinutes: Int,
        uptimeMinutes: Double = 0,
        manifest: CheckManifest = CheckCatalog.builtIn
    ) -> ProcessProfileReport {
        let sample = sampleOutput.flatMap(SampleDigest.parse)
        let input = ProcessDiagnostics.Input(
            name: "", cpuPercent: stats.cpuPercent, footprintBytes: stats.footprintBytes,
            threadCount: stats.threadCount, systemRAMBytes: systemRAMBytes,
            uptimeMinutes: uptimeMinutes, sample: sample,
            fileDescriptors: fileDescriptors, cpuTrail: cpuTrail, memoryTrail: memoryTrail,
            diskReadTrail: diskReadTrail, diskWriteTrail: diskWriteTrail, fdTrail: fdTrail,
            spanMinutes: spanMinutes)
        let checks = ProcessDiagnostics.run(input, manifest: manifest)
        let (status, headline) = overall(checks)

        return ProcessProfileReport(
            overallStatus: status, headline: headline,
            cpuPercent: stats.cpuPercent, cpuTrail: cpuTrail,
            cpuTrend: cpuTrendText(cpuTrail, current: stats.cpuPercent),
            memoryBytes: stats.footprintBytes, memoryTrail: memoryTrail,
            memoryTrend: memoryTrendText(
                memoryTrail, current: stats.footprintBytes, spanMinutes: spanMinutes),
            memoryPeakBytes: stats.peakFootprintBytes,
            checks: checks)
    }

    /// The overall verdict, taken from the most severe check.
    public static func overall(_ checks: [DiagnosticCheck]) -> (DiagnosticCheck.Status, String) {
        let worst = checks.map(\.status).max { $0.severity < $1.severity } ?? .ok
        switch worst {
        case .critical:
            let titles = checks.filter { $0.status == .critical }.map(\.title)
            return (.critical, "Problem detected — \(titles.joined(separator: ", ")).")
        case .warning:
            let n = checks.filter { $0.status == .warning }.count
            return (.warning, "\(n) thing\(n == 1 ? "" : "s") worth a look.")
        default:
            return (.ok, "No problems detected — this process looks healthy.")
        }
    }

    // MARK: - Trends

    private static func cpuTrendText(_ trail: [Double], current: Double) -> String {
        guard trail.count >= 4 else { return String(format: "%.0f%% now", current) }
        let dir = direction(trail)
        let first = trail.first ?? current
        let last = trail.last ?? current
        return String(format: "%.0f%% → %.0f%%, %@", first, last, dir)
    }

    private static func memoryTrendText(
        _ trail: [Double], current: UInt64, spanMinutes: Int
    )
        -> String
    {
        guard trail.count >= 4 else { return "\(ByteFormat.string(current)) now" }
        let dir = direction(trail)
        let first = trail.first ?? Double(current)
        let last = trail.last ?? Double(current)
        let word = dir == "rising" ? "growing" : dir  // memory phrasing
        var text =
            "\(ByteFormat.string(UInt64(max(0, first)))) → "
            + "\(ByteFormat.string(UInt64(max(0, last)))), \(word)"
        if dir == "rising", spanMinutes > 0 {
            let perMin = (last - first) / Double(spanMinutes)
            if perMin > 0 { text += " (~\(ByteFormat.string(UInt64(perMin)))/min)" }
        }
        return text
    }

    /// Coarse direction over a trail: first third vs last third, with a dead-band.
    private static func direction(_ trail: [Double], deadband: Double = 0.15) -> String {
        guard trail.count >= 4 else { return "steady" }
        let third = max(1, trail.count / 3)
        let start = avg(Array(trail.prefix(third)))
        let end = avg(Array(trail.suffix(third)))
        let rel = (end - start) / max(abs(start), 1)
        if rel > deadband { return "rising" }
        if rel < -deadband { return "falling" }
        return "steady"
    }

    private static func avg(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }
}

/// The live headline stats captured at deep-dive time.
public struct ProcessProfileStats: Sendable, Equatable {
    public var cpuPercent: Double
    public var footprintBytes: UInt64
    public var peakFootprintBytes: UInt64
    public var threadCount: Int

    public init(
        cpuPercent: Double, footprintBytes: UInt64, peakFootprintBytes: UInt64, threadCount: Int
    ) {
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.peakFootprintBytes = peakFootprintBytes
        self.threadCount = threadCount
    }
}
