import Combine
import Foundation
import MacPerfMonitorCore

/// The user's process groups shown on the Groups tab — all user-created, persisted
/// to JSON on disk. The app does not ship built-in preset groups (they're
/// impossible to get right across every environment); users define their own.
/// Mirrors `ProcessGlossaryStore`'s file-location + atomic-write approach, without
/// the Ed25519 signature gate (these definitions are user-authored).
@MainActor
final class ProcessGroupStore: ObservableObject {
    static let shared = ProcessGroupStore()

    /// All groups, in creation order.
    @Published private(set) var groups: [ProcessGroup] = []

    /// Only the enabled groups (what the Groups tab lists as cards).
    var enabledGroups: [ProcessGroup] { groups.filter(\.isEnabled) }

    /// Groups a process can be hand-added to from the Processes list.
    var addTargets: [ProcessGroup] { groups }

    /// Resilient JSON-backed storage (recovers/preserves on read failure rather
    /// than letting a hiccup wipe every group). Nil only if Application Support is
    /// unreachable.
    private let store: ResilientJSONFileStore<ProcessGroup>?

    init() {
        store = Self.makeStore()
        load()
    }

    // MARK: - Queries

    func group(id: ProcessGroup.ID) -> ProcessGroup? { groups.first { $0.id == id } }

    // MARK: - Mutations

    /// Create a new group.
    func add(_ group: ProcessGroup) {
        groups.append(group)
        persist()
    }

    /// Replace an existing group.
    func update(_ group: ProcessGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
        persist()
    }

    /// Delete a group.
    func delete(id: ProcessGroup.ID) {
        groups.removeAll { $0.id == id }
        persist()
    }

    /// Enable or disable a group.
    func setEnabled(_ id: ProcessGroup.ID, _ enabled: Bool) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].isEnabled = enabled
        persist()
    }

    /// OR a membership node into a group's rule (the "Add to group" action).
    func addRule(_ node: GroupRule, toGroup id: ProcessGroup.ID) {
        guard node.hasCondition, let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].add(node)
        persist()
    }

    // MARK: - Persistence

    /// UUIDs of the built-in presets that 1.1.0 briefly seeded. Purged on load so
    /// installs that already wrote them to disk don't keep them now that the app
    /// ships no preset groups.
    private static let formerPresetIDs: Set<UUID> = [
        UUID(uuidString: "0E5B1F00-0000-4000-A000-000000000001")!,
        UUID(uuidString: "0E5B1F00-0000-4000-A000-000000000002")!,
        UUID(uuidString: "0E5B1F00-0000-4000-A000-000000000003")!,
    ]

    /// Build the resilient store at Application Support/<bundleID>/groups.json. The
    /// recovery/backup/empty-guard logic lives in `ResilientJSONFileStore` (Core),
    /// where it is unit-tested.
    private static func makeStore() -> ResilientJSONFileStore<ProcessGroup>? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: true)
        else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "uk.co.bzwrd.macperfmonitor"
        let url =
            base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("groups.json")
        return ResilientJSONFileStore(url: url)
    }

    private func load() {
        guard let store else {
            groups = []
            return
        }
        // The store handles missing-vs-unreadable, backup recovery, and `.corrupt`
        // preservation. Here we only drop any leftover 1.1.0-seeded presets and
        // rewrite if that filtering changed anything.
        let loaded = store.load()
        let cleaned = loaded.filter { !Self.formerPresetIDs.contains($0.id) }
        groups = cleaned
        if cleaned.count != loaded.count { store.save(groups) }
    }

    private func persist() {
        store?.save(groups)
    }
}
