import Foundation
import MacPerfMonitorCore

/// The canonical list of processes pinned to the Performance Monitor overlay,
/// shared across the app so any surface can add to it. Holding it here (rather
/// than as local state inside `PerformanceMonitorView`) lets the Processes-tab
/// list add a process with a right-click and have it appear on the Monitor tab,
/// and keeps the selection alive while the Monitor tab is not on screen.
///
/// This owns only the ordered identities. The Monitor view still derives the
/// per-process colour, captured name and chart series from these, reconciling
/// whenever the list changes.
final class MonitorSelection: ObservableObject {
    /// The pinned processes, in the order they were added. The Monitor view
    /// draws and colours them in this order.
    @Published private(set) var identities: [ProcessIdentity] = []

    /// The most processes that can be overlaid at once, matching the Monitor's
    /// eight-slot colour palette.
    let capacity = 8

    /// True when no more processes can be added until one is removed.
    var isFull: Bool { identities.count >= capacity }

    /// Whether a process is already pinned to the Monitor.
    func contains(_ id: ProcessIdentity) -> Bool { identities.contains(id) }

    /// Pin a process to the Monitor. No-op (returns false) when it is already
    /// pinned or the eight-slot capacity is reached.
    @discardableResult
    func add(_ id: ProcessIdentity) -> Bool {
        guard !identities.contains(id), identities.count < capacity else { return false }
        identities.append(id)
        return true
    }

    /// Unpin a process from the Monitor.
    func remove(_ id: ProcessIdentity) {
        identities.removeAll { $0 == id }
    }

    /// Pin the process if it is not pinned, otherwise unpin it.
    func toggle(_ id: ProcessIdentity) {
        if identities.contains(id) {
            remove(id)
        } else {
            add(id)
        }
    }
}
