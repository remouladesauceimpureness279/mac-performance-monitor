import Foundation
import MacPerfMonitorCore

/// Drives the deep-dive window: profile one process with `sample`, snapshot its
/// memory breakdown (`footprint`) and open files/sockets, and assemble a precise,
/// deterministic `ProcessProfileReport` — no language model. Captures run locally
/// for the user's own processes and via the root helper for protected ones. Owned
/// by `ProcessDeepDiveView` as a `@StateObject`.
@MainActor
final class ProcessDeepDiveModel: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        case done(ProcessProfileReport)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    var isWorking: Bool { if case .working = state { return true } else { return false } }

    func analyze(target: DeepDiveTarget, helper: HelperManager) {
        guard !isWorking else { return }
        let pid = target.pid
        state = .working("Checking for the latest checks…")
        Task {
            // Make sure we run the newest signed catalog (downloads + verifies, falls
            // back to the cached/built-in pack on any failure).
            await CheckCatalogStore.shared.refresh()
            let manifest = CheckCatalogStore.shared.manifest

            state = .working("Profiling \(target.name) for 5 seconds…")
            let sampleOutput = await captureTool(.sample, pid: pid, helper: helper)
            state = .working("Reading open files and connections…")
            let fds = await captureFileDescriptors(pid: pid, helper: helper)

            state = .working("Running \(manifest.checks.count) checks…")
            // Always produce a report: the CPU / memory / leak / I/O / thread checks
            // work from the live stats + trails even when sampling a protected process
            // fails — those checks just report "skipped".
            let report = ProcessProfileReport.make(
                stats: target.profileStats,
                systemRAMBytes: target.systemRAMBytes,
                sampleOutput: sampleOutput,
                fileDescriptors: fds,
                cpuTrail: target.cpuTrail,
                memoryTrail: target.memoryTrail,
                diskReadTrail: target.diskReadTrail,
                diskWriteTrail: target.diskWriteTrail,
                fdTrail: target.fdTrail,
                spanMinutes: target.spanMinutes,
                uptimeMinutes: target.uptimeMinutes,
                manifest: manifest)
            state = .done(report)
            FDWatchdog.check(after: "deep-dive")
        }
    }

    /// Run an allow-listed tool, local-first then via the root helper on a privilege
    /// failure. Returns nil when neither path can read the target.
    private func captureTool(
        _ tool: MemoryInspection.Tool, pid: Int32, helper: HelperManager
    )
        async -> String?
    {
        let local: String? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: try? MemoryToolRunner.run(tool, pid: pid).get())
            }
        }
        if let local, !MemoryInspection.indicatesPrivilegeFailure(local) { return local }
        guard helper.canEscalate else { return nil }
        return await withCheckedContinuation { cont in
            helper.runMemoryTool(tool, pid: pid) { cont.resume(returning: $0) }
        }
    }

    /// List the target's open files and sockets, local-first then via the helper.
    private func captureFileDescriptors(
        pid: Int32, helper: HelperManager
    )
        async -> [OpenFileDescriptor]
    {
        let local: [OpenFileDescriptor] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: ProcessReader().openFileDescriptors(pid) ?? [])
            }
        }
        if !local.isEmpty { return local }
        guard helper.canEscalate else { return [] }
        return await withCheckedContinuation { cont in
            helper.listOpenFiles(pid: pid) { cont.resume(returning: $0 ?? []) }
        }
    }
}
