import Foundation

/// Which performance tier a CPU core belongs to. Apple Silicon splits its cores
/// into high-performance ("P") and high-efficiency ("E") clusters; Intel reports
/// a single tier, which we label `.performance`.
public enum CoreKind: String, Codable, Sendable {
    case performance
    case efficiency
    case unknown
}

/// One logical core's utilisation over a single sampling tick — the delta
/// between the cumulative kernel tick counters of two consecutive samples. All
/// fractions are 0...1 of that one core's time over the interval.
public struct CoreUsage: Sendable, Codable, Identifiable {
    public var index: Int
    public var kind: CoreKind
    /// Busy fraction (user + system + nice) over the tick, 0...1.
    public var usage: Double
    /// User-mode fraction (including nice), 0...1.
    public var user: Double
    /// System-mode fraction, 0...1.
    public var system: Double

    public var id: Int { index }

    public init(index: Int, kind: CoreKind, usage: Double, user: Double, system: Double) {
        self.index = index
        self.kind = kind
        self.usage = usage
        self.user = user
        self.system = system
    }
}

/// A single system-wide CPU measurement for one sampling tick. Every utilisation
/// figure is delta-based — computed from the change in the kernel's cumulative
/// per-core tick counters since the previous sample — so it reflects the instant,
/// not a since-boot average. `totalUsage` and the per-cluster figures are 0...1
/// of the relevant capacity; multiply by 100 for a percentage of total capacity.
public struct CPUSample: Sendable, Codable {
    public var timestamp: Date

    /// Busy fraction across all logical cores, 0...1 (1.0 == every core pinned).
    public var totalUsage: Double
    /// System-wide user / system / idle split, as fractions of total capacity.
    public var userFraction: Double
    public var systemFraction: Double
    public var idleFraction: Double

    /// Per-core utilisation, one entry per logical core, in index order.
    public var cores: [CoreUsage]

    /// Mean busy fraction across the performance / efficiency clusters, 0...1.
    /// Zero when the machine has no cores of that kind (see the count fields).
    public var performanceUsage: Double
    public var efficiencyUsage: Double
    public var performanceCoreCount: Int
    public var efficiencyCoreCount: Int

    /// 1 / 5 / 15-minute load averages (run-queue length), best-effort.
    public var loadAverage1: Double
    public var loadAverage5: Double
    public var loadAverage15: Double

    public init(
        timestamp: Date,
        totalUsage: Double,
        userFraction: Double,
        systemFraction: Double,
        idleFraction: Double,
        cores: [CoreUsage],
        performanceUsage: Double,
        efficiencyUsage: Double,
        performanceCoreCount: Int,
        efficiencyCoreCount: Int,
        loadAverage1: Double,
        loadAverage5: Double,
        loadAverage15: Double
    ) {
        self.timestamp = timestamp
        self.totalUsage = totalUsage
        self.userFraction = userFraction
        self.systemFraction = systemFraction
        self.idleFraction = idleFraction
        self.cores = cores
        self.performanceUsage = performanceUsage
        self.efficiencyUsage = efficiencyUsage
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
        self.loadAverage1 = loadAverage1
        self.loadAverage5 = loadAverage5
        self.loadAverage15 = loadAverage15
    }

    /// A zeroed sample, used before the first inter-tick delta is available and
    /// as the `Sampler.Snapshot` default so call sites predating CPU sampling
    /// (the persistence tests) still build.
    public static let zero = CPUSample(
        timestamp: Date(timeIntervalSince1970: 0),
        totalUsage: 0, userFraction: 0, systemFraction: 0, idleFraction: 1,
        cores: [], performanceUsage: 0, efficiencyUsage: 0,
        performanceCoreCount: 0, efficiencyCoreCount: 0,
        loadAverage1: 0, loadAverage5: 0, loadAverage15: 0)
}
