import Combine
import Foundation
import MacPerfMonitorCore
import MacPerfMonitorIPC

/// A self-contained description of the process the memory inspector targets,
/// resolved once when the inspector window is opened (from the live sample under
/// the cursor) and carried as the window's value.
///
/// It is deliberately a plain `Codable`/`Hashable` value rather than a reference
/// to the live `SamplerModel`: the inspector must NOT subscribe to the 2-second
/// sample stream (doing so would re-execute its view tree every tick — the exact
/// re-render storm that leaked memory elsewhere). On-demand tool runs are the
/// only data source here.
struct InspectorTarget: Codable, Hashable, Identifiable {
    var pid: Int32
    var startTime: Date
    var name: String
    var uid: UInt32

    var id: ProcessIdentity { ProcessIdentity(pid: pid, startTime: startTime) }
}

/// Drives the memory inspector: detects what we can read for the target, runs
/// the Apple tools on demand (directly for the user's own process, via the root
/// helper for system / other-user processes), parses their output, and computes
/// the leak-hunt diff between two heap snapshots.
final class MemoryInspectorModel: ObservableObject {
    /// What the app can do for this particular target, decided from ownership
    /// and whether elevated coverage is active.
    enum Capability: Equatable {
        /// The target is owned by the current user: run the tools directly.
        case ownProcess
        /// Not owned, but the root helper is active: run the tools as root.
        case privileged
        /// Not owned and no elevated coverage: we cannot inspect it.
        case needsCoverage
    }

    let target: InspectorTarget

    // Snapshot results.
    @Published var isLoadingSnapshot = false
    @Published var footprint: MemoryInspection.FootprintSnapshot?
    @Published var heap: MemoryInspection.HeapSnapshot?
    @Published var leaks: MemoryInspection.LeaksSummary?
    @Published var snapshotMessage: String?
    @Published var privilegeDenied = false
    @Published var lastSnapshotDate: Date?

    // Raw, unparsed tool output retained for export (the "dump"). NOT @Published:
    // it's read only on demand when the user saves a report, so it never drives a
    // re-render of the inspector window.
    private(set) var rawFootprint: String?
    private(set) var rawHeap: String?
    private(set) var rawLeaks: String?

    // Leak hunt.
    @Published var baseline: MemoryInspection.HeapSnapshot?
    @Published var baselineDate: Date?
    @Published var deltas: [MemoryInspection.HeapClassDelta]?
    @Published var isCapturingBaseline = false
    @Published var isComparing = false
    @Published var leakHuntMessage: String?

    init(target: InspectorTarget) {
        self.target = target
    }

    /// Decide the capability now, given the current coverage state.
    func capability(canEscalate: Bool) -> Capability {
        if target.uid == UInt32(getuid()) { return .ownProcess }
        return canEscalate ? .privileged : .needsCoverage
    }

    // MARK: - Snapshot

    /// Run footprint, then heap, then leaks in sequence (each `heap`/`leaks`
    /// briefly suspends the target, so they are never overlapped) and publish the
    /// parsed results.
    func loadSnapshot(helper: HelperManager) {
        let cap = capability(canEscalate: helper.canEscalate)
        guard cap != .needsCoverage else {
            snapshotMessage =
                "Enable Full Coverage in Settings to inspect processes owned by another user."
            return
        }
        guard !isLoadingSnapshot else { return }
        isLoadingSnapshot = true
        snapshotMessage = nil
        privilegeDenied = false
        rawFootprint = nil
        rawHeap = nil
        rawLeaks = nil

        runTool(.footprint, helper: helper, capability: cap) { [weak self] text in
            guard let self else { return }
            self.applyFootprint(text)
            self.runTool(.heap, helper: helper, capability: cap) { [weak self] text in
                guard let self else { return }
                self.applyHeap(text)
                self.runTool(.leaks, helper: helper, capability: cap) { [weak self] text in
                    guard let self else { return }
                    self.applyLeaks(text)
                    self.isLoadingSnapshot = false
                    self.lastSnapshotDate = Date()
                    if self.footprint == nil && self.heap == nil && self.leaks == nil
                        && self.snapshotMessage == nil
                    {
                        self.snapshotMessage =
                            self.privilegeDenied
                            ? "The system denied access to this process."
                            : "No data was returned. The process may have just exited."
                    }
                }
            }
        }
    }

    private func applyFootprint(_ text: String?) {
        guard let text else { return }
        rawFootprint = text
        if MemoryInspection.indicatesPrivilegeFailure(text) { privilegeDenied = true }
        if let parsed = MemoryInspection.parseFootprint(text) { footprint = parsed }
    }

    private func applyHeap(_ text: String?) {
        guard let text else { return }
        rawHeap = text
        if MemoryInspection.indicatesPrivilegeFailure(text) { privilegeDenied = true }
        if let parsed = MemoryInspection.parseHeap(text) { heap = parsed }
    }

    private func applyLeaks(_ text: String?) {
        guard let text else { return }
        rawLeaks = text
        if MemoryInspection.indicatesPrivilegeFailure(text) { privilegeDenied = true }
        if let parsed = MemoryInspection.parseLeaks(text) { leaks = parsed }
    }

    // MARK: - Export

    /// Whether any captured tool output exists to export.
    var hasExportableSnapshot: Bool {
        rawFootprint != nil || rawHeap != nil || rawLeaks != nil
    }

    /// A suggested file name for a saved report, e.g.
    /// "Safari-1234-memory-2026-06-11-095930.txt".
    func suggestedReportFileName(date: Date = Date()) -> String {
        let stamp = Self.fileStampFormatter.string(from: date)
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let safe = target.name.components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        let base = safe.isEmpty ? "process" : safe
        return "\(base)-\(target.pid)-memory-\(stamp).txt"
    }

    /// Build a full text "dump" of the current snapshot: a header and summary,
    /// then the raw, unparsed output of each Apple tool that was captured.
    /// Returns nil if no snapshot has been taken yet.
    func buildReport() -> String? {
        guard hasExportableSnapshot else { return nil }
        let captured = lastSnapshotDate ?? Date()
        let title = "\(AppInfo.displayName) — Memory Inspection Report"
        var out = title + "\n"
        out += String(repeating: "=", count: title.count) + "\n"
        out += "Process:   \(target.name)\n"
        out += "PID:       \(target.pid)\n"
        out += "UID:       \(target.uid)\n"
        out += "Captured:  \(Self.headerDateFormatter.string(from: captured))\n\n"
        out += "Summary\n-------\n"
        if let footprint {
            out += "Footprint (phys. memory):  \(ByteFormat.string(footprint.totalBytes))\n"
        }
        if let heap {
            out +=
                "Heap (all zones):          \(ByteFormat.string(heap.totalBytes)) across \(heap.totalNodes.formatted()) nodes\n"
        }
        if let leaks {
            let note: String
            if leaks.leakCount == 0 {
                note = "none"
            } else if !leaks.isDebuggable {
                note =
                    "conservative estimate — leaks can't fully inspect this hardened process, so this is very likely over-reported"
            } else if leaks.significance == .notable {
                note = "notable — worth investigating (debuggable build)"
            } else {
                note = "minor — likely normal one-time allocations"
            }
            out +=
                "Leaks:                     \(leaks.leakCount.formatted()) blocks · \(ByteFormat.string(leaks.leakedBytes)) (\(note))\n"
        }
        out += "\n"
        out += rawSection(
            title: "footprint", command: "/usr/bin/footprint \(target.pid)", body: rawFootprint)
        out += rawSection(title: "heap", command: "/usr/bin/heap \(target.pid)", body: rawHeap)
        out += rawSection(title: "leaks", command: "/usr/bin/leaks \(target.pid)", body: rawLeaks)
        return out
    }

    private func rawSection(title: String, command: String, body: String?) -> String {
        guard let body else { return "" }
        let rule = String(repeating: "─", count: 60)
        var s = rule + "\n\(title)  —  \(command)\n" + rule + "\n"
        s += body
        if !body.hasSuffix("\n") { s += "\n" }
        return s + "\n"
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f
    }()

    // MARK: - Leak hunt

    /// Capture the first heap snapshot to diff against.
    func captureBaseline(helper: HelperManager) {
        let cap = capability(canEscalate: helper.canEscalate)
        guard cap != .needsCoverage else {
            leakHuntMessage =
                "Enable Full Coverage in Settings to inspect processes owned by another user."
            return
        }
        guard !isCapturingBaseline else { return }
        isCapturingBaseline = true
        leakHuntMessage = nil
        deltas = nil
        runTool(.heap, helper: helper, capability: cap) { [weak self] text in
            guard let self else { return }
            self.isCapturingBaseline = false
            guard let text, let parsed = MemoryInspection.parseHeap(text) else {
                self.leakHuntMessage =
                    MemoryInspection.indicatesPrivilegeFailure(text ?? "")
                    ? "The system denied access to this process."
                    : "Couldn't capture a baseline. The process may have just exited."
                return
            }
            self.baseline = parsed
            self.baselineDate = Date()
        }
    }

    /// Take a second heap snapshot and rank the classes that grew since the
    /// baseline — the leak suspects.
    func compareNow(helper: HelperManager) {
        guard let baseline else { return }
        let cap = capability(canEscalate: helper.canEscalate)
        guard cap != .needsCoverage else { return }
        guard !isComparing else { return }
        isComparing = true
        leakHuntMessage = nil
        runTool(.heap, helper: helper, capability: cap) { [weak self] text in
            guard let self else { return }
            self.isComparing = false
            guard let text, let current = MemoryInspection.parseHeap(text) else {
                self.leakHuntMessage = "Couldn't capture a comparison snapshot."
                return
            }
            self.deltas = MemoryInspection.diffHeap(baseline: baseline, current: current)
            if self.deltas?.isEmpty ?? true {
                self.leakHuntMessage =
                    "No class grew between the two snapshots — nothing looks like it's leaking right now."
            }
        }
    }

    /// Throw away the baseline and any comparison so the user can start over.
    func resetLeakHunt() {
        baseline = nil
        baselineDate = nil
        deltas = nil
        leakHuntMessage = nil
    }

    // MARK: - Tool dispatch

    /// Run one tool by the appropriate route and deliver its text on the main
    /// thread. For the user's own process the tool runs in-app as the user; for
    /// another user's / a system process it is routed through the root helper.
    private func runTool(
        _ tool: MemoryInspection.Tool,
        helper: HelperManager,
        capability: Capability,
        completion: @escaping (String?) -> Void
    ) {
        switch capability {
        case .ownProcess:
            let pid = target.pid
            DispatchQueue.global(qos: .userInitiated).async {
                let text = try? MemoryToolRunner.run(tool, pid: pid).get()
                DispatchQueue.main.async { completion(text) }
            }
        case .privileged:
            helper.runMemoryTool(tool, pid: target.pid, completion: completion)
        case .needsCoverage:
            completion(nil)
        }
    }
}
