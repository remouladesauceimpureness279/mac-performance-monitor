import CMacPerfMonitor
import Darwin
import Foundation

/// Cumulative CPU tick counters for one logical core, as reported by
/// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`. The counters are monotonic
/// since boot; per-tick utilisation is the delta between two reads. Stored as
/// `UInt32` to match the kernel's `unsigned int cpu_ticks[]` so the rare 32-bit
/// wrap is handled by wrapping subtraction rather than producing a huge delta.
public struct CoreTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Reads system-wide CPU utilisation from Mach: per-core tick counters via
/// `host_processor_info`, plus the load averages via `getloadavg`. Like the
/// memory reader it is a thin, stateless wrapper — the inter-tick delta state
/// lives in the `Sampler`.
public struct CPUReader: Sendable {
    public init() {}

    /// The host's CPU topology (chip, core counts, P/E split).
    public var topology: CPUTopology { .current }

    /// Read the cumulative per-core tick counters, one entry per logical core.
    /// Returns nil on a Mach error. The kernel allocates the result array; we
    /// copy the counts out and free it with `vm_deallocate`.
    public func sampleCoreTicks() -> [CoreTicks]? {
        var cpuCount = natural_t(0)
        var info: processor_info_array_t? = nil
        var infoCount = mach_msg_type_number_t(0)
        let kr = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let cores = Int(cpuCount)
        let states = Int(CPU_STATE_MAX)
        var result: [CoreTicks] = []
        result.reserveCapacity(cores)
        for i in 0..<cores {
            let base = i * states
            // The values are unsigned tick counts transported through a signed
            // integer_t array, so reinterpret the bit pattern.
            func tick(_ state: Int32) -> UInt32 {
                UInt32(bitPattern: info[base + Int(state)])
            }
            result.append(
                CoreTicks(
                    user: tick(CPU_STATE_USER),
                    system: tick(CPU_STATE_SYSTEM),
                    idle: tick(CPU_STATE_IDLE),
                    nice: tick(CPU_STATE_NICE)))
        }
        return result
    }

    /// 1 / 5 / 15-minute load averages. Zeroes on error.
    public func loadAverage() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }
}
