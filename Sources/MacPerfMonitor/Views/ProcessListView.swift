import AppKit
import MacPerfMonitorCore
import SwiftUI

/// A live, sortable, filterable table of every visible process. Row identity is
/// the stable `ProcessIdentity` (pid + start time), so rows keep their place and
/// selection across re-sorts and live updates rather than flickering.
///
/// This view owns the data and the table's state (search, sort, hierarchy) and
/// prepares the sorted/filtered `rows` once per real change. The table itself is
/// the separate, `Equatable` `ProcessTable` child: the enclosing views re-render
/// once a second to keep the live system header moving, and isolating the table
/// behind `Equatable` stops SwiftUI re-laying-out its ~600 rows on every one of
/// those ticks — it re-renders only when the rows, selection, or row styling
/// actually change. (Re-laying-out the whole table every second was the
/// dominant CPU cost on this tab.)
struct ProcessListView: View {
    let processes: [ProcessSample]
    @Binding var selection: ProcessIdentity?

    @EnvironmentObject private var model: SamplerModel
    @State private var sortOrder = [
        KeyPathComparator(\ProcessNode.process.physFootprint, order: .reverse)
    ]
    @State private var search = ""

    /// When on, processes are shown as a tree keyed on parent PID (which process
    /// launched which) instead of one flat sorted list. Persisted so the choice
    /// survives relaunches.
    @AppStorage("processShowHierarchy") private var showHierarchy = false

    /// `launchd`, the ancestor of nearly every process. Hidden as a node in the
    /// hierarchy view since its parentage is implied.
    private static let launchdPID: Int32 = 1

    /// Multi-row selection backing the table. A `Set` makes the table support
    /// cmd-click (toggle one) and shift-click (extend a range) natively. The
    /// parent's single `selection`, which drives the detail inspector, is kept in
    /// sync inside `ProcessTable`.
    @State private var multiSelection: Set<ProcessIdentity> = []

    /// The prepared rows the table draws, memoized in `@State`. Rebuilt by
    /// `rebuildRows()` only when an input that affects them changes (the data
    /// version, sort order, search text, or hierarchy toggle) — never on the 1 s
    /// `latest` republish — so the O(n log n) filter+sort over ~600 processes does
    /// not run on every render.
    @State private var rows: [ProcessNode] = []

    /// Bumped each time `rows` is rebuilt. Passed to `ProcessTable` as its
    /// `revision` so its `Equatable` conformance can detect a real row change
    /// without comparing the (non-`Equatable`) `rows` array element by element.
    @State private var rowsRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            ProcessTable(
                rows: rows,
                revision: rowsRevision,
                showHierarchy: showHierarchy,
                leakingIDs: model.leakingProcessIDs,
                terminatedIDs: model.terminatedProcessIDs,
                selection: $selection,
                multiSelection: $multiSelection,
                sortOrder: $sortOrder,
                model: model
            )
            .equatable()
            // Rebuild the rows only when something that affects them changes. The
            // data version covers the heavy-tick refresh and kills; the rest are
            // user actions. The 1 s header tick touches none of these.
            .onChange(of: model.displayProcessesVersion, initial: true) { _, _ in rebuildRows() }
            .onChange(of: sortOrder) { _, _ in rebuildRows() }
            .onChange(of: search) { _, _ in rebuildRows() }
            .onChange(of: showHierarchy) { _, _ in rebuildRows() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by name", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
            Divider()
                .frame(height: 16)
            Toggle(isOn: $showHierarchy) {
                Label("Hierarchy", systemImage: "list.bullet.indent")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Group processes by which launched which.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The visible processes after the search filter, before sorting or nesting.
    private var filteredSamples: [ProcessSample] {
        search.isEmpty
            ? processes
            : processes.filter {
                $0.displayName.localizedCaseInsensitiveContains(search)
                    || $0.name.localizedCaseInsensitiveContains(search)
            }
    }

    /// Recompute the table's rows from the current inputs and bump the revision.
    /// Flat mode is a single sorted level; hierarchy mode nests each process under
    /// the visible process that launched it, with every level sorted by the active
    /// column.
    private func rebuildRows() {
        if showHierarchy {
            rows = buildForest(from: filteredSamples)
        } else {
            rows =
                filteredSamples
                .map { ProcessNode(process: $0, children: nil) }
                .sorted(using: sortOrder)
        }
        rowsRevision &+= 1
    }

    /// Build a parent/child forest from the visible processes, nesting each one
    /// under the visible process whose PID matches its parent PID. Processes
    /// whose parent is not in the visible set become roots, and every level is
    /// sorted by the active sort order. A visited set plus a final sweep for any
    /// unvisited process keep the build safe against PID reuse or cycles, so no
    /// process is ever dropped or shown twice.
    ///
    /// `launchd` (PID 1) is dropped from the tree: it is the ancestor of almost
    /// everything, so showing it adds a layer of indentation with no information.
    /// Removing it promotes its direct children to top-level roots.
    private func buildForest(from samples: [ProcessSample]) -> [ProcessNode] {
        let samples = samples.filter { $0.pid != Self.launchdPID }
        let byPID = Dictionary(
            samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenByPPID: [Int32: [ProcessSample]] = [:]
        var childPIDs: Set<Int32> = []
        for sample in samples where sample.ppid != sample.pid && byPID[sample.ppid] != nil {
            childrenByPPID[sample.ppid, default: []].append(sample)
            childPIDs.insert(sample.pid)
        }

        var visited: Set<Int32> = []
        func makeNode(_ sample: ProcessSample) -> ProcessNode {
            visited.insert(sample.pid)
            let kids =
                (childrenByPPID[sample.pid] ?? [])
                .filter { !visited.contains($0.pid) }
                .map(makeNode)
                .sorted(using: sortOrder)
            return ProcessNode(process: sample, children: kids.isEmpty ? nil : kids)
        }

        var forest =
            samples
            .filter { !childPIDs.contains($0.pid) }
            .map(makeNode)
            .sorted(using: sortOrder)

        // Anything left unvisited (only possible under a PID cycle) is surfaced
        // as a root so a process is never silently dropped.
        let orphans = samples.filter { !visited.contains($0.pid) }
        if !orphans.isEmpty {
            forest +=
                orphans
                .map { ProcessNode(process: $0, children: nil) }
                .sorted(using: sortOrder)
        }
        return forest
    }
}

/// The process table proper, isolated behind `Equatable` so SwiftUI re-evaluates
/// and re-lays-out its rows only when the data, selection, or row styling
/// actually change — not on the once-a-second re-render that the live system
/// header forces on the enclosing views. `model` is held as a plain (unobserved)
/// reference: it is used only for on-demand row actions, so it never drives a
/// render. All render-affecting inputs are compared in `==`.
private struct ProcessTable: View, Equatable {
    let rows: [ProcessNode]
    /// Stands in for comparing the non-`Equatable` `rows` array; bumped whenever
    /// the parent rebuilds the rows.
    let revision: Int
    let showHierarchy: Bool
    let leakingIDs: Set<ProcessIdentity>
    let terminatedIDs: Set<ProcessIdentity>
    @Binding var selection: ProcessIdentity?
    @Binding var multiSelection: Set<ProcessIdentity>
    @Binding var sortOrder: [KeyPathComparator<ProcessNode>]
    let model: SamplerModel

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var monitor: MonitorSelection
    @EnvironmentObject private var groupStore: ProcessGroupStore
    @Environment(\.openWindow) private var openWindow

    /// Re-render only on a genuine change. Bindings, closures, and the unobserved
    /// `model` are deliberately excluded; everything that affects what the table
    /// draws is a value compared here. `revision` proxies for the row contents.
    static func == (lhs: ProcessTable, rhs: ProcessTable) -> Bool {
        lhs.revision == rhs.revision
            && lhs.showHierarchy == rhs.showHierarchy
            && lhs.selection == rhs.selection
            && lhs.multiSelection == rhs.multiSelection
            && lhs.leakingIDs == rhs.leakingIDs
            && lhs.terminatedIDs == rhs.terminatedIDs
    }

    var body: some View {
        tableContent
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: ProcessIdentity.self) { ids in
                if ids.count > 1 {
                    multiSelectionMenu(ids)
                } else if let id = ids.first {
                    ProcessActionMenu(
                        live: model.currentSample(for: id),
                        showCodesign: {
                            if let live = model.currentSample(for: id) {
                                ProcessRowIntent.showCodesign(
                                    sample: live, appState: appState, bringWindowForward: false)
                            }
                        },
                        requestKill: { appState.pendingForceQuit = id },
                        inspectMemory: inspectAction(for: id),
                        openFiles: openFilesAction(for: id),
                        deepDive: deepDiveAction(for: id),
                        addToMonitor: { monitor.add(id) },
                        isMonitored: monitor.contains(id),
                        monitorHasRoom: !monitor.isFull,
                        addToGroup: { gid in
                            if let s = model.currentSample(for: id) {
                                groupStore.addRule(Self.groupRule(for: s), toGroup: gid)
                            }
                        },
                        newGroupFromProcess: {
                            if let s = model.currentSample(for: id) {
                                groupStore.add(
                                    ProcessGroup(
                                        name: s.displayName, rule: .any([Self.groupRule(for: s)])))
                            }
                        },
                        groupTargets: groupStore.addTargets
                    )
                }
            } primaryAction: { ids in
                if let id = ids.first { selection = id }
            }
            .onChange(of: multiSelection) { _, ids in
                // Drive the single-row inspector from the table selection. An
                // EMPTY set is deliberately ignored: in hierarchy mode the Table
                // cannot materialise a row nested under a collapsed parent, so
                // when an external selection (a notification or a click from
                // another view) sets `selection` and we mirror it into
                // `multiSelection` below, the Table rejects it and writes the set
                // back to empty. Clearing `selection` on that echo snapped the
                // inspector straight shut, so a navigation target "didn't
                // select". Leaving `selection` untouched on empty keeps the
                // target open; a multi-row selection still clears the single-row
                // inspector for the batch action.
                if ids.count == 1 {
                    selection = ids.first
                } else if ids.count > 1 {
                    selection = nil
                }
            }
            .onChange(of: selection) { _, newValue in
                // Reflect an external selection (the auto-selected top row, or a
                // notification's navigation target) back into the table highlight.
                if let id = newValue, multiSelection != [id] {
                    multiSelection = [id]
                }
            }
            .onAppear {
                if let id = selection { multiSelection = [id] }
            }
    }

    /// The table itself. The flat case uses a plain `Table` (no `children:`),
    /// which is materially cheaper to diff and lay out than the outline table the
    /// `children:` initializer produces — the outline form was previously used
    /// even in flat mode, where every row's children are `nil`. The hierarchy
    /// case keeps the outline table for its disclosure rows.
    @ViewBuilder
    private var tableContent: some View {
        if showHierarchy {
            Table(rows, children: \.children, selection: $multiSelection, sortOrder: $sortOrder) {
                processColumns()
            }
        } else {
            Table(rows, selection: $multiSelection, sortOrder: $sortOrder) {
                processColumns()
            }
        }
    }

    /// The shared column set, so the flat and hierarchical tables stay identical.
    @TableColumnBuilder<ProcessNode, KeyPathComparator<ProcessNode>>
    private func processColumns()
        -> some TableColumnContent<ProcessNode, KeyPathComparator<ProcessNode>>
    {
        TableColumn("Process", value: \.process.displayName) { node in
            let process = node.process
            ProcessNameCell(
                process: process,
                isLeaking: leakingIDs.contains(process.id),
                descendantLeaking: hasLeakingDescendant(node),
                isTerminated: isTerminated(process))
        }
        .width(min: 160, ideal: 260)

        TableColumn("Memory", value: \.process.physFootprint) { node in
            let process = node.process
            Text(process.footprintReadable ? ByteFormat.string(process.physFootprint) : "—")
                .monospacedDigit()
                .foregroundStyle(process.footprintReadable ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(
                    process.footprintReadable
                        ? ""
                        : "Footprint not readable at the user level for this process."
                )
                .accessibilityLabel(
                    process.footprintReadable
                        ? ByteFormat.string(process.physFootprint)
                        : "Memory not readable"
                )
                .dimmedIfTerminated(isTerminated(process))
        }
        .width(min: 84, ideal: 104)

        TableColumn("CPU", value: \.process.cpuPercent) { node in
            let process = node.process
            Text(String(format: "%.1f%%", process.cpuPercent))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .dimmedIfTerminated(isTerminated(process))
        }
        .width(min: 58, ideal: 70)

        TableColumn("Threads", value: \.process.threadCount) { node in
            let process = node.process
            Text("\(process.threadCount)")
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .dimmedIfTerminated(isTerminated(process))
        }
        .width(min: 60, ideal: 72)

        TableColumn("FDs", value: \.process.fdTotal) { node in
            let process = node.process
            Text("\(process.fdTotal)")
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .dimmedIfTerminated(isTerminated(process))
        }
        .width(min: 50, ideal: 62)

        TableColumn("Arch", value: \.process.architecture.label) { node in
            let process = node.process
            Text(process.architecture.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .dimmedIfTerminated(isTerminated(process))
        }
        .width(min: 60, ideal: 72)

        TableColumn("PID", value: \.process.pid) { node in
            let process = node.process
            Text("\(process.pid)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .dimmedIfTerminated(isTerminated(process))
        }
        .width(min: 52, ideal: 72)
    }

    /// The batch context menu shown when more than one row is selected. Pins the
    /// selected processes to the Monitor in their on-screen order, stopping at the
    /// eight-process limit and skipping any already pinned.
    @ViewBuilder
    private func multiSelectionMenu(_ ids: Set<ProcessIdentity>) -> some View {
        let addable = addableCount(ids)
        Button {
            addSelectionToMonitor(ids)
        } label: {
            Label(
                addable > 0
                    ? "Add \(addable) \(addable == 1 ? "Process" : "Processes") to Analytics"
                    : "Analytics Full",
                systemImage: "chart.xyaxis.line"
            )
        }
        .disabled(addable == 0)
        .help(
            addable == 0
                ? "Remove a process from Analytics first (eight maximum)."
                : "Pin the selected processes to the Analytics tab."
        )
    }

    /// The most durable membership rule for a process: prefer its code-signing
    /// Team ID, then bundle id, then executable path, then name.
    static func groupRule(for s: ProcessSample) -> GroupRule {
        GroupMatcher.condition(for: GroupMatcher.Candidate(sample: s))
    }

    /// How many of the selected processes can still be pinned: those not already
    /// monitored, capped by the Monitor's remaining slots.
    private func addableCount(_ ids: Set<ProcessIdentity>) -> Int {
        let notMonitored = ids.filter { !monitor.contains($0) }.count
        let room = monitor.capacity - monitor.identities.count
        return max(0, min(notMonitored, room))
    }

    /// Build the Inspect Memory action for a row, seeding a self-contained
    /// `InspectorTarget` (pid, start time, name, uid) from the *live* sample so
    /// the inspector window never has to subscribe to the sample stream. Returns
    /// nil when the row has no live sample (a just-exited process), which omits
    /// the menu item rather than opening an inspector on a dead pid.
    private func inspectAction(for id: ProcessIdentity) -> (() -> Void)? {
        guard let sample = model.currentSample(for: id) else { return nil }
        let target = InspectorTarget(
            pid: sample.pid,
            startTime: sample.startTime,
            name: sample.displayName,
            uid: UInt32(sample.uid)
        )
        return {
            openWindow(value: target)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Build the Open Files & Sockets action for a row, seeding a self-contained
    /// `OpenFilesTarget` from the *live* sample so the window never subscribes to
    /// the sample stream. Returns nil when the row has no live sample (a
    /// just-exited process), which omits the menu item rather than opening a
    /// window on a dead pid.
    private func openFilesAction(for id: ProcessIdentity) -> (() -> Void)? {
        guard let sample = model.currentSample(for: id) else { return nil }
        let target = OpenFilesTarget(
            pid: sample.pid,
            startTime: sample.startTime,
            name: sample.displayName,
            uid: UInt32(sample.uid)
        )
        return {
            openWindow(value: target)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Build the AI Deep Dive action for a row, seeding a self-contained
    /// `DeepDiveTarget` from the *live* sample. Returns nil for a just-exited
    /// process (no live sample), which omits the menu item rather than profiling a
    /// dead pid.
    private func deepDiveAction(for id: ProcessIdentity) -> (() -> Void)? {
        guard let sample = model.currentSample(for: id) else { return nil }
        let model = self.model
        let openWindow = self.openWindow
        return {
            // Uptime distinguishes a young process warming up from an old one still
            // growing (the leak check uses it).
            let uptimeMinutes = max(0, Date().timeIntervalSince(sample.startTime) / 60)
            // Pull the persisted DB history (a long window) so the trends/leak check
            // see real long-run behaviour, not just the short in-memory trail.
            model.loadProcessHistory(id, window: .sixHours) { history in
                let points = history.count >= 2 ? history : model.trailSamples(for: id)
                let span: Int = {
                    guard let first = points.first?.date, let last = points.last?.date, last > first
                    else { return 0 }
                    return max(1, Int(last.timeIntervalSince(first) / 60))
                }()
                let target = DeepDiveTarget(
                    pid: sample.pid,
                    startTime: sample.startTime,
                    name: sample.displayName,
                    uid: UInt32(sample.uid),
                    arch: sample.architecture.label,
                    isTranslated: sample.isTranslated,
                    cpuPercent: sample.cpuPercent,
                    footprintBytes: sample.physFootprint,
                    peakFootprintBytes: sample.lifetimeMaxFootprint,
                    threadCount: Int(sample.threadCount),
                    systemRAMBytes: ProcessInfo.processInfo.physicalMemory,
                    uptimeMinutes: uptimeMinutes,
                    cpuTrail: points.map(\.cpuPercent),
                    memoryTrail: points.map { Double($0.footprint) },
                    diskReadTrail: points.map { Double($0.diskRead) },
                    diskWriteTrail: points.map { Double($0.diskWritten) },
                    fdTrail: points.map { Double($0.fdTotal) },
                    spanMinutes: span
                )
                openWindow(value: target)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Pin the selected processes to the Monitor in their current sorted order,
    /// stopping once the Monitor is full.
    private func addSelectionToMonitor(_ ids: Set<ProcessIdentity>) {
        for process in flatten(rows) where ids.contains(process.id) {
            if monitor.isFull { break }
            monitor.add(process.id)
        }
    }

    /// Flatten a forest into depth-first display order.
    private func flatten(_ nodes: [ProcessNode]) -> [ProcessSample] {
        nodes.flatMap { [$0.process] + flatten($0.children ?? []) }
    }

    /// Whether any process nested beneath `node` is a suspected leak. Used to
    /// surface the leak warning on a parent row so a leaking child hidden under a
    /// collapsed parent is still visible at the top level (the hierarchical table
    /// gives no expansion state, so the parent keeps the hint even once expanded,
    /// where the child shows its own).
    private func hasLeakingDescendant(_ node: ProcessNode) -> Bool {
        guard let children = node.children else { return false }
        for child in children {
            if leakingIDs.contains(child.process.id) { return true }
            if hasLeakingDescendant(child) { return true }
        }
        return false
    }

    /// Whether a row is a recently force-quit process, kept greyed out as
    /// confirmation that the kill took effect (see `SamplerModel`).
    private func isTerminated(_ process: ProcessSample) -> Bool {
        terminatedIDs.contains(process.id)
    }
}

extension View {
    /// Dim a process-row cell when its process was recently force-quit, so the
    /// greyed-out "stopped" rows read as inactive at a glance.
    fileprivate func dimmedIfTerminated(_ isTerminated: Bool) -> some View {
        opacity(isTerminated ? 0.5 : 1)
    }
}

/// A process plus the processes it launched, for the optional hierarchy view.
/// Identity is the wrapped process's stable identity, so table selection, row
/// expansion, and the detail inspector all key on the same value as flat mode.
private struct ProcessNode: Identifiable {
    let process: ProcessSample
    var children: [ProcessNode]?
    var id: ProcessIdentity { process.id }
}

/// The Process-column cell: the process name, a Rosetta badge when translated,
/// and, for a suspected leak, a leading warning badge plus an orange name so the
/// problem process stands out in the list at a glance (PRD section 8.5). A
/// recently force-quit process is shown struck through with a "Stopped" badge so
/// the kill reads as done even before the row ages out of the list.
private struct ProcessNameCell: View {
    let process: ProcessSample
    let isLeaking: Bool
    /// True when this row itself is healthy but a process it launched (hidden
    /// under it while collapsed) is a suspected leak, so the warning still shows
    /// at the parent level.
    var descendantLeaking: Bool = false
    let isTerminated: Bool

    private var nameColor: Color {
        if isTerminated { return .secondary }
        return isLeaking ? .orange : .primary
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: ProcessIconProvider.shared.icon(forPath: process.executablePath))
                .resizable()
                .frame(width: 16, height: 16)
                .opacity(isTerminated ? 0.5 : 1)
                .accessibilityHidden(true)
            if isLeaking && !isTerminated {
                LeakIndicator()
            } else if descendantLeaking && !isTerminated {
                // A child leaks: use the SAME solid filled triangle as a real
                // leak so a collapsed parent is impossible to miss in a long
                // list. The distinction stays in the tooltip and in the name
                // colour — this process itself is healthy, so its name is not
                // orange (only the leaking child's is).
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("A process started by this one looks like it's leaking memory.")
                    .accessibilityLabel("A child process is a possible memory leak")
            }
            Text(process.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(isTerminated, color: .secondary)
                .foregroundStyle(nameColor)
                .help(process.displayName)
            if isTerminated {
                StoppedBadge()
            } else if process.isTranslated {
                Text("Rosetta")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Running under Rosetta translation")
            }
        }
    }
}

/// A small badge marking a row whose process MacPerfMonitor force-quit, so the greyed,
/// struck-through row is unmistakably "we stopped this" rather than just idle.
private struct StoppedBadge: View {
    var body: some View {
        Text("Stopped")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Force quit by \(AppInfo.displayName)")
    }
}
