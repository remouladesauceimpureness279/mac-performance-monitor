import Foundation

/// Detects step changes in a process footprint series: a sudden jump that often
/// indicates a document load or a runaway operation, distinct from a gradual leak.
public enum ChangeDetector {
    public struct Config: Sendable {
        /// Window size (samples) on each side of a candidate boundary.
        public var window: Int
        /// Minimum absolute jump between window means (bytes).
        public var minimumJump: UInt64

        public init(window: Int = 5, minimumJump: UInt64 = 256 * 1024 * 1024) {
            self.window = window
            self.minimumJump = minimumJump
        }

        public static let `default` = Config()
    }

    public struct StepChange: Sendable, Equatable {
        public var at: Date
        public var beforeMean: UInt64
        public var afterMean: UInt64
        /// Positive for a jump up, negative for a drop.
        public var deltaBytes: Int64
    }

    /// Find the single most significant step change in the series, if any
    /// crosses the threshold.
    public static func analyze(series: [(Date, UInt64)], config: Config = .default) -> StepChange? {
        let sorted = series.sorted { $0.0 < $1.0 }
        guard sorted.count >= config.window * 2 else { return nil }

        var best: StepChange?
        var bestMagnitude: UInt64 = 0

        for boundary in config.window...(sorted.count - config.window) {
            let before = sorted[(boundary - config.window)..<boundary]
            let after = sorted[boundary..<(boundary + config.window)]
            let beforeMean = mean(before)
            let afterMean = mean(after)
            let magnitude = beforeMean > afterMean ? beforeMean - afterMean : afterMean - beforeMean
            if magnitude >= config.minimumJump, magnitude > bestMagnitude {
                bestMagnitude = magnitude
                best = StepChange(
                    at: sorted[boundary].0,
                    beforeMean: beforeMean,
                    afterMean: afterMean,
                    deltaBytes: Int64(afterMean) - Int64(beforeMean)
                )
            }
        }
        return best
    }

    private static func mean(_ slice: ArraySlice<(Date, UInt64)>) -> UInt64 {
        guard !slice.isEmpty else { return 0 }
        let total = slice.reduce(UInt64(0)) { $0 &+ $1.1 }
        return total / UInt64(slice.count)
    }
}
