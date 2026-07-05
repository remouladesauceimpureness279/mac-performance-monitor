import CMacPerfMonitor
import Darwin
import Foundation

/// Static CPU topology, read once from sysctl: the chip name, the logical and
/// physical core counts, and the performance/efficiency split. On Apple Silicon
/// `hw.nperflevels` is 2 (level 0 = performance, level 1 = efficiency).
///
/// The topology cannot change while the process runs, so it is detected once.
public struct CPUTopology: Sendable, Equatable {
    public var brand: String
    public var logicalCores: Int
    public var physicalCores: Int
    public var performanceCoreCount: Int
    public var efficiencyCoreCount: Int
    /// The kind of each logical core, in `host_processor_info` index order.
    public var coreKinds: [CoreKind]

    public init(
        brand: String,
        logicalCores: Int,
        physicalCores: Int,
        performanceCoreCount: Int,
        efficiencyCoreCount: Int,
        coreKinds: [CoreKind]
    ) {
        self.brand = brand
        self.logicalCores = logicalCores
        self.physicalCores = physicalCores
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
        self.coreKinds = coreKinds
    }

    /// Detected once at first use; the topology is fixed for the process.
    public static let current = CPUTopology.detect()

    static func detect() -> CPUTopology {
        let logical = Sysctl.integer("hw.logicalcpu", as: Int32.self).map(Int.init) ?? 1
        let physical = Sysctl.integer("hw.physicalcpu", as: Int32.self).map(Int.init) ?? logical
        let brand = Sysctl.string("machdep.cpu.brand_string") ?? "CPU"
        let levels = Sysctl.integer("hw.nperflevels", as: Int32.self).map(Int.init) ?? 1

        var performance = logical
        var efficiency = 0
        if levels >= 2 {
            // perflevel0 is the highest-performing cluster (P), perflevel1 the
            // efficiency cluster (E). Higher indices, if any, fold into E.
            performance =
                Sysctl.integer("hw.perflevel0.logicalcpu", as: Int32.self).map(Int.init) ?? logical
            efficiency = max(0, logical - performance)
        }
        performance = max(0, min(performance, logical))
        efficiency = max(0, min(efficiency, logical - performance))

        return CPUTopology(
            brand: brand,
            logicalCores: logical,
            physicalCores: physical,
            performanceCoreCount: performance,
            efficiencyCoreCount: efficiency,
            coreKinds: coreKinds(
                logical: logical, performance: performance, efficiency: efficiency)
        )
    }

    /// Map each logical core index to a kind. `host_processor_info` does not say
    /// which index belongs to which cluster, but on Apple Silicon the efficiency
    /// cores occupy the low indices and the performance cores the high ones
    /// (matching how the kernel and tools like powermetrics group "E-Cluster"
    /// before "P-Cluster"). When the P/E counts don't cleanly reconcile, every
    /// core falls back to `.performance` so nothing is mislabelled. Pure and
    /// explicit so the ordering assumption is unit-testable.
    static func coreKinds(
        logical: Int, performance: Int, efficiency: Int
    ) -> [CoreKind] {
        guard logical > 0 else { return [] }
        guard efficiency > 0, performance > 0,
            efficiency + performance == logical
        else {
            return Array(repeating: .performance, count: logical)
        }
        return Array(repeating: .efficiency, count: efficiency)
            + Array(repeating: .performance, count: performance)
    }
}
