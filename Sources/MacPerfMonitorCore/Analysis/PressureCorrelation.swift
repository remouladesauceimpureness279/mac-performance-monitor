import Foundation

/// Correlates pressure spikes with the processes that grew the most beforehand,
/// to attribute likely cause (PRD section 8.6).
public enum PressureCorrelation {
    /// Timestamps at which the system pressure crossed up into `threshold` or
    /// higher from a lower level.
    public static func crossings(system: [SystemSample], threshold: PressureLevel) -> [Date] {
        let sorted = system.sorted { $0.timestamp < $1.timestamp }
        var result: [Date] = []
        var previous: PressureLevel?
        for sample in sorted {
            if let prev = previous, prev < threshold, sample.pressureLevel >= threshold {
                result.append(sample.timestamp)
            }
            previous = sample.pressureLevel
        }
        return result
    }

    public struct Attribution: Sendable, Equatable {
        public var identity: ProcessIdentity
        public var startFootprint: UInt64
        public var endFootprint: UInt64
        public var growthBytes: Int64
    }

    /// Rank processes by footprint growth over `window`. Series are
    /// (timestamp, footprint) pairs keyed by process identity.
    public static func topGrowers(
        series: [ProcessIdentity: [(Date, UInt64)]],
        window: ClosedRange<Date>,
        limit: Int
    ) -> [Attribution] {
        var attributions: [Attribution] = []
        for (identity, points) in series {
            let inWindow =
                points
                .filter { window.contains($0.0) }
                .sorted { $0.0 < $1.0 }
            guard let first = inWindow.first, let last = inWindow.last else { continue }
            let growth = Int64(last.1) - Int64(first.1)
            attributions.append(
                Attribution(
                    identity: identity,
                    startFootprint: first.1,
                    endFootprint: last.1,
                    growthBytes: growth
                ))
        }
        return
            attributions
            .sorted { $0.growthBytes > $1.growthBytes }
            .prefix(limit)
            .map { $0 }
    }
}
