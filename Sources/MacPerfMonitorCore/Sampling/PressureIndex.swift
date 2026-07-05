import Foundation

/// Computes the continuous 0...100 pressure index that is MacPerfMonitor's North Star
/// metric. The full derivation and rationale live in docs/pressure-index.md;
/// the formula is reproduced here in comments so it is auditable at the call
/// site (and, being open source, it will be audited).
public enum PressureIndex {
    /// Each discrete level owns a 33-wide band; continuous signals position the
    /// index within the band so the chart glides instead of stepping.
    private static func levelFloor(_ level: PressureLevel) -> Double {
        switch level {
        case .normal: return 0
        case .warning: return 34
        case .critical: return 67
        }
    }

    private static let bandSpan: Double = 33

    /// Normalised compression load: half of RAM sitting in the compressor is
    /// treated as a fully loaded band contribution.
    static func compressionSignal(compressed: UInt64, totalRAM: UInt64) -> Double {
        guard totalRAM > 0 else { return 0 }
        let fraction = Double(compressed) / Double(totalRAM)
        return min(fraction / 0.5, 1.0)
    }

    /// Normalised swap load: swap equal to RAM is treated as fully loaded.
    static func swapSignal(swapUsed: UInt64, totalRAM: UInt64) -> Double {
        guard totalRAM > 0 else { return 0 }
        return min(Double(swapUsed) / Double(totalRAM), 1.0)
    }

    /// Combine the level (authoritative for the band) with the continuous
    /// compression, swap and trend signals (which position within the band).
    ///
    ///     signal = clamp(0.5*compression + 0.3*swap + 0.2*trend, 0, 1)
    ///     index  = levelFloor(level) + signal * 33
    ///
    /// - Parameters:
    ///   - trendSignal: 0...1 measure of how fast compressed+swap is rising,
    ///     supplied by the sampler from its inter-tick state.
    public static func compute(
        level: PressureLevel,
        compressed: UInt64,
        swapUsed: UInt64,
        totalRAM: UInt64,
        trendSignal: Double = 0
    ) -> Double {
        let compression = compressionSignal(compressed: compressed, totalRAM: totalRAM)
        let swap = swapSignal(swapUsed: swapUsed, totalRAM: totalRAM)
        let trend = max(0, min(trendSignal, 1))
        let signal = max(0, min(0.5 * compression + 0.3 * swap + 0.2 * trend, 1))
        let index = levelFloor(level) + signal * bandSpan
        return max(0, min(index, 100))
    }
}
