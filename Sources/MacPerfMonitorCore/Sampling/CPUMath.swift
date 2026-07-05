import Foundation

/// Pure CPU-usage math, kept separate from the sampler so it can be unit tested.
public enum CPUMath {
    /// CPU usage as a percentage of a single core, from the CPU-time delta over
    /// a wall-clock interval. Can exceed 100 for multi-threaded processes, which
    /// matches Activity Monitor's convention.
    public static func percent(cpuDeltaNanos: UInt64, wallDeltaNanos: Double) -> Double {
        guard wallDeltaNanos > 0 else { return 0 }
        return Double(cpuDeltaNanos) / wallDeltaNanos * 100.0
    }

    /// Safe monotonic delta of two cumulative counters. Returns 0 if the new
    /// value is below the old one (counter reset / pid reuse).
    public static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 {
        new >= old ? new - old : 0
    }

    /// One logical core's utilisation from two cumulative tick reads, as
    /// fractions (0...1) of that core's time over the interval. `user` folds the
    /// kernel's "nice" bucket into user time, so `usage == user + system`.
    /// Wrapping subtraction (`&-`) keeps the rare 32-bit counter wrap to a small
    /// correct delta instead of a spurious huge one; an empty interval (no tick
    /// change) reports idle.
    public static func coreUsage(
        current: CoreTicks, previous: CoreTicks
    ) -> (usage: Double, user: Double, system: Double) {
        let deltaUser = Double(current.user &- previous.user)
        let deltaSystem = Double(current.system &- previous.system)
        let deltaIdle = Double(current.idle &- previous.idle)
        let deltaNice = Double(current.nice &- previous.nice)
        let userBusy = deltaUser + deltaNice
        let total = userBusy + deltaSystem + deltaIdle
        guard total > 0 else { return (0, 0, 0) }
        let user = userBusy / total
        let system = deltaSystem / total
        return (min(user + system, 1), user, system)
    }
}
