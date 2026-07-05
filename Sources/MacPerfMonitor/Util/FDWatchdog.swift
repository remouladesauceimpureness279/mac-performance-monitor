import Darwin
import Foundation
import MacPerfMonitorCore
import os

/// Instrumentation for the transient FD bursts described in
/// docs/fd-count-1620-diagnosis.md: the app's kernel FD table doubled twice in
/// one afternoon (to 800, then 1600 slots), so something briefly held 800+
/// descriptors open simultaneously — yet the steady live count is ~27 and the
/// burst has never been caught in the act. The bursts correlate with
/// interactive use, so each UI-driven operation (deep-dive, open-files
/// inspector, memory export, insights run) reports here when it finishes; if
/// the app's own descriptor count is at or above the threshold, the full
/// breakdown and the operation that preceded it are logged at error level
/// (persisted, so a later `log show` query finds it). One libproc self-read
/// per user action — cheap enough to keep in release builds, which is where
/// the bursts were observed.
enum FDWatchdog {
    /// Well above the app's steady ~27 FDs plus the transient spawn wobble,
    /// well below the first suspicious table doubling to 800 slots.
    static let threshold: Int32 = 200

    private static let log = Logger(subsystem: AppLog.subsystem, category: "fdwatchdog")

    /// Serial queue: keeps the libproc read off the main thread and keeps
    /// overlapping reports from interleaving.
    private static let queue = DispatchQueue(
        label: "uk.co.bzwrd.macperfmonitor.fdwatchdog", qos: .utility)

    /// Call when a UI-driven operation completes. Reads the app's own FD
    /// breakdown and logs it only when the total is at or above `threshold`.
    static func check(after operation: String) {
        queue.async {
            guard let fd = ProcessReader().fdBreakdown(getpid()),
                fd.total >= threshold
            else { return }
            log.error(
                """
                FD burst after \(operation, privacy: .public): \
                total \(fd.total) (vnode \(fd.vnode), socket \(fd.socket), \
                pipe \(fd.pipe), other \(fd.other))
                """)
        }
    }
}
