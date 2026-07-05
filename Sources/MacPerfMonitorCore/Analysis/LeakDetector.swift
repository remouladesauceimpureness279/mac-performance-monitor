import Foundation

/// Flags a process whose footprint shows sustained, consistent upward growth
/// (a likely leak), while avoiding false positives from normal warm-up spikes.
public enum LeakDetector {
    public struct Config: Sendable {
        /// Minimum span of growth data required before judging (seconds).
        /// Deliberately long: a freshly launched app's memory climbs steeply and
        /// smoothly while it loads, caches warm and JIT settles — a near-perfect
        /// straight line that looks exactly like a leak over a short window.
        /// Requiring growth to be *sustained* over a long span lets that launch
        /// ramp plateau first, so the plateau breaks the linear fit and only a
        /// genuine, still-ongoing leak qualifies. It also means a process must
        /// have lived at least this long to be judged, so nothing is flagged
        /// mid-launch.
        public var minimumDuration: TimeInterval
        /// Minimum growth rate to care about (bytes/second).
        public var minimumSlope: Double
        /// Minimum R^2: growth must be consistent, not a one-off jump.
        public var minimumRSquared: Double
        /// Minimum number of samples.
        public var minimumSamples: Int
        /// Minimum total growth across the window (bytes), a noise floor.
        public var minimumTotalGrowth: UInt64

        public init(
            minimumDuration: TimeInterval = 20 * 60,  // 20 minutes — past warm-up
            minimumSlope: Double = 8 * 1024,  // ~8 KB/s
            minimumRSquared: Double = 0.85,
            minimumSamples: Int = 12,
            minimumTotalGrowth: UInt64 = 32 * 1024 * 1024  // 32 MB
        ) {
            self.minimumDuration = minimumDuration
            self.minimumSlope = minimumSlope
            self.minimumRSquared = minimumRSquared
            self.minimumSamples = minimumSamples
            self.minimumTotalGrowth = minimumTotalGrowth
        }

        public static let `default` = Config()
    }

    public struct Finding: Sendable, Equatable {
        /// Growth rate in bytes/second.
        public var slopeBytesPerSecond: Double
        /// Consistency of the trend (0...1).
        public var rSquared: Double
        /// Span of the analysed window in seconds.
        public var durationSeconds: TimeInterval
        /// Total growth across the window in bytes.
        public var totalGrowth: UInt64
        /// 0...1 confidence, blending consistency and how far above thresholds.
        public var confidence: Double
    }

    /// Analyse a footprint time-series. Returns a `Finding` when the series meets
    /// every threshold for a likely leak, otherwise nil.
    public static func analyze(series: [(Date, UInt64)], config: Config = .default) -> Finding? {
        guard series.count >= config.minimumSamples else { return nil }
        let sorted = series.sorted { $0.0 < $1.0 }
        guard let first = sorted.first, let last = sorted.last else { return nil }

        let duration = last.0.timeIntervalSince(first.0)
        guard duration >= config.minimumDuration else { return nil }

        let t0 = first.0.timeIntervalSince1970
        let points = sorted.map { (x: $0.0.timeIntervalSince1970 - t0, y: Double($0.1)) }
        guard let fit = LinearRegression.fit(points) else { return nil }

        guard fit.slope >= config.minimumSlope, fit.rSquared >= config.minimumRSquared else {
            return nil
        }

        let totalGrowth: UInt64 = last.1 > first.1 ? last.1 - first.1 : 0
        guard totalGrowth >= config.minimumTotalGrowth else { return nil }

        // Confidence: consistency weighted with how far slope exceeds the floor.
        let slopeHeadroom = min(fit.slope / (config.minimumSlope * 8), 1.0)
        let confidence = max(0, min(0.6 * fit.rSquared + 0.4 * slopeHeadroom, 1.0))

        return Finding(
            slopeBytesPerSecond: fit.slope,
            rSquared: fit.rSquared,
            durationSeconds: duration,
            totalGrowth: totalGrowth,
            confidence: confidence
        )
    }
}
