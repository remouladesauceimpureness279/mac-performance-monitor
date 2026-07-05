import Foundation

/// One system-wide network measurement captured on a sampling tick, mirroring
/// `BatterySample`'s role for energy: it carries the chartable scalars (the
/// download/upload rates, also persisted via `SystemSample`) plus the live-only
/// detail that does not fit the scalar persistence model — the cumulative
/// session totals and the primary interface name.
///
/// Sourced from `NetworkReader` (the `getifaddrs` interface counters), which is
/// cheap enough to run on the fast system tick. The rates are computed
/// inter-tick from the cumulative counters, so the very first reading after a
/// reset reports a zero rate rather than a since-boot average spike.
public struct NetworkSample: Sendable, Codable, Equatable {
    public var timestamp: Date

    /// Download (received) throughput this tick, bytes/second.
    public var inBytesPerSec: Double
    /// Upload (sent) throughput this tick, bytes/second.
    public var outBytesPerSec: Double

    /// Total bytes received since the reader's baseline (first reading this
    /// session), for a "downloaded this session" read-out. Monotonic.
    public var sessionInBytes: UInt64
    /// Total bytes sent since the reader's baseline this session. Monotonic.
    public var sessionOutBytes: UInt64

    /// The busiest physical interface this tick (e.g. "en0"), for the menu's
    /// "via Wi-Fi" hint. Nil when nothing has moved or no interface is up.
    public var primaryInterface: String?

    /// The local IPv4 address of the active physical interface (e.g.
    /// "192.168.1.5"), for the network menu. Nil when no en* interface has an IPv4.
    public var localIPv4: String?

    public init(
        timestamp: Date,
        inBytesPerSec: Double = 0,
        outBytesPerSec: Double = 0,
        sessionInBytes: UInt64 = 0,
        sessionOutBytes: UInt64 = 0,
        primaryInterface: String? = nil,
        localIPv4: String? = nil
    ) {
        self.timestamp = timestamp
        self.inBytesPerSec = inBytesPerSec
        self.outBytesPerSec = outBytesPerSec
        self.sessionInBytes = sessionInBytes
        self.sessionOutBytes = sessionOutBytes
        self.primaryInterface = primaryInterface
        self.localIPv4 = localIPv4
    }
}
