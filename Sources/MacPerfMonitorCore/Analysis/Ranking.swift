import Foundation

/// Ranking and aggregate insights over a set of process samples from one tick.
public enum Ranking {
    /// Top processes by phys_footprint, descending. Only readable footprints
    /// are ranked.
    public static func topByFootprint(_ samples: [ProcessSample], limit: Int) -> [ProcessSample] {
        samples
            .filter { $0.footprintReadable }
            .sorted { $0.physFootprint > $1.physFootprint }
            .prefix(limit)
            .map { $0 }
    }

    /// Top processes by CPU percentage, descending.
    public static func topByCPU(_ samples: [ProcessSample], limit: Int) -> [ProcessSample] {
        samples
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(limit)
            .map { $0 }
    }
}

/// The aggregate memory cost of Rosetta-translated processes (PRD section 8.6).
public struct RosettaCost: Sendable, Equatable {
    public var processCount: Int
    public var totalFootprint: UInt64

    public static func compute(_ samples: [ProcessSample]) -> RosettaCost {
        let translated = samples.filter { $0.isTranslated }
        let total = translated.reduce(UInt64(0)) { $0 &+ $1.physFootprint }
        return RosettaCost(processCount: translated.count, totalFootprint: total)
    }
}
