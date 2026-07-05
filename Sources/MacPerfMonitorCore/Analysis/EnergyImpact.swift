import Foundation

/// A relative "energy impact" score for a process, in the spirit of Activity
/// Monitor's Energy tab. macOS exposes no clean public per-process wattage
/// without root (powermetrics), so this is a heuristic derived from data the
/// sampler already collects: CPU usage and idle/interrupt wakeups (the classic
/// battery-drain signal, since they keep the CPU out of its low-power state),
/// with a small penalty for Rosetta-translated processes (which burn more energy
/// per unit of work). The absolute number is not meaningful in physical units;
/// it is a consistent relative measure for ranking and trend, identical in scale
/// across every process so the leaderboard is honest.
public enum EnergyImpact {
    /// Weight applied to each idle wakeup per second. Tuned so a process waking
    /// the CPU ~100 times a second contributes roughly as much as 10% sustained
    /// CPU — wakeups matter for battery, but sustained CPU dominates.
    static let wakeupWeight = 0.1

    /// Extra fraction of energy a translated (Rosetta) process is assumed to burn
    /// for the same observed CPU, reflecting the translation overhead.
    static let rosettaPenalty = 1.2

    /// Estimate the relative energy impact for one tick.
    /// - cpuPercent: CPU usage as a percentage of one core (may exceed 100).
    /// - idleWakeupsPerSec: idle + interrupt wakeups per second over the tick.
    /// - isTranslated: whether the process runs under Rosetta.
    public static func estimate(
        cpuPercent: Double, idleWakeupsPerSec: Double, isTranslated: Bool
    ) -> Double {
        let cpu = max(0, cpuPercent) * (isTranslated ? rosettaPenalty : 1.0)
        let wakeups = max(0, idleWakeupsPerSec) * wakeupWeight
        return cpu + wakeups
    }
}
