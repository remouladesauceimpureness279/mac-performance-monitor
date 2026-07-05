import Foundation

/// A cheap GPU sample read from the IOAccelerator registry once per system tick.
/// On Apple silicon the integrated GPU is a single accelerator backed by unified
/// memory; the figures come straight from the driver's `PerformanceStatistics`.
public struct GPUSample: Sendable, Codable, Equatable {
    /// Overall GPU utilization, 0–100 (IOAccelerator "Device Utilization %").
    public var utilization: Double
    /// Renderer / tiler utilization, 0–100, when the driver reports them.
    public var renderUtilization: Double?
    public var tilerUtilization: Double?
    /// GPU in-use memory in bytes (unified memory on Apple silicon).
    public var inUseMemoryBytes: UInt64?
    /// GPU allocated (reserved) memory in bytes.
    public var allocatedMemoryBytes: UInt64?
    /// GPU core count, e.g. 16 (static).
    public var coreCount: Int?
    /// The GPU / chip name, e.g. "Apple M2 Pro" (static; read once).
    public var name: String?

    // --- IOReport "Energy Model" power (watts), filled by the Sampler ---
    public var gpuPowerWatts: Double?
    /// Apple Neural Engine power (watts). 0 when no ML workload is running.
    public var anePowerWatts: Double?
    public var cpuPowerWatts: Double?

    // --- SMC thermal, filled by the Sampler ---
    /// SoC die temperature (°C). The GPU shares the die, so this is its temperature.
    public var dieTemperatureC: Double?
    public var fanRPM: Int?
    public var fanMaxRPM: Int?

    /// Rough ANE utilization (0–100) = power / a per-platform max draw. The watts
    /// are exact; this percentage is an estimate for the bar.
    public var aneUtilization: Double? {
        guard let anePowerWatts else { return nil }
        return min(100, max(0, anePowerWatts / Self.maxANEPowerWatts * 100))
    }
    /// Approximate peak ANE power across the M-series (≈8.5 W); good enough for a
    /// utilization bar without a per-chip table.
    private static let maxANEPowerWatts = 8.5

    public init(
        utilization: Double, renderUtilization: Double? = nil, tilerUtilization: Double? = nil,
        inUseMemoryBytes: UInt64? = nil, name: String? = nil
    ) {
        self.utilization = utilization
        self.renderUtilization = renderUtilization
        self.tilerUtilization = tilerUtilization
        self.inUseMemoryBytes = inUseMemoryBytes
        self.name = name
    }
}
