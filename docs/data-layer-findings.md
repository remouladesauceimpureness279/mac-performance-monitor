# Data-layer findings (Milestone 0)

This document records what per-process and system memory data MacPerfMonitor can read
as a **regular, non-sandboxed user**, where the boundary is, and the resulting
decision on whether a privileged helper (PRD section 9) is required for v1. (It
is not, and the helper was later dropped entirely.)

It is generated from the `macperfmonitor-cli probe` harness so the reasoning is
auditable and reproducible.

## How to reproduce

```bash
swift build
.build/debug/macperfmonitor-cli probe
```

Run it as your normal login user (not under `sudo`). The percentages below are
machine-specific; what matters is the *shape* of the boundary, which is stable.

## Test environment

- Hardware: Apple Silicon (arm64), 18 GB RAM, 16 KB page size.
- OS: macOS 26.5.
- User: standard account (uid 501), not root, App Sandbox off.
- The machine was under genuine memory pressure during the run (level
  **Warning**, 87 MB free, 6.5 GB compressed, 24.6 GB swap used), so the system
  figures below are from a realistically loaded Mac rather than an idle one.

## Per-process read coverage

`n = 877` visible processes (`ps -A` reported 879; the small difference is the
header line plus pid churn between the two enumerations, and pid 0/kernel being
filtered). PID enumeration itself is complete and accurate.

| Capability | API | Result | Notes |
|---|---|---|---|
| Enumerate PIDs | `proc_listallpids` | 877/877 | Complete for all processes. |
| Basic task info | `proc_pidinfo(PROC_PIDTASKALLINFO)` | 610/877 (69.6%) | Succeeds only for processes the user owns. |
| Headline footprint | `proc_pid_rusage(RUSAGE_INFO_V6)` | 610/877 (69.6%) | Tracks task-info readability exactly. |
| File descriptors | `proc_pidinfo(PROC_PIDLISTFDS)` | call never errored | **But** returns an empty list (size 0) for processes the user cannot inspect, so it is not a reliable coverage signal on its own. |
| Rosetta flag | `sysctl(KERN_PROC_PID)` | 877/877 (100%) | `kinfo_proc` is world-readable; translation detection works for every process. |
| Executable path | `proc_pidpath` | 877/877 (100%) | Works for every process regardless of ownership, so we can always *name* a process even when we cannot read its memory. |

## Where the boundary actually is

The decisive result: **footprint readability is governed entirely by process
ownership.**

- Processes owned by the user (uid 501): **610**. Footprint read failures among
  them: **0**.
- Processes owned by other users (system daemons running as `root`,
  `_windowserver`, `_hidd`, and friends): **267**. Footprint read failures among
  them: **267** (all of them).

So as an unprivileged user MacPerfMonitor gets a **complete, accurate footprint for
100% of the processes the user owns**, which are exactly the processes a person
can actually act on (quit, restart). The ~30% it cannot read are system/other-
user processes that the user cannot quit anyway. `proc_pidpath`, the Rosetta
flag, and basic enumeration remain available for those, so they can still be
listed by name and marked as a coverage gap rather than shown as a misleading 0.

Spot-check: the top consumer in the run (Microsoft Word, 5.2 GB phys_footprint)
matched Activity Monitor's Memory column within rounding, confirming
`ri_phys_footprint` is the right headline figure.

### System-wide figures need no privilege

`host_statistics64(HOST_VM_INFO64)`, `hw.memsize`, `vm.swapusage`, and
`kern.memorystatus_vm_pressure_level` all read cleanly as the user. The entire
memory taxonomy and pressure model (PRD section 7) is fully available without a
helper.

## Decision: a privileged helper is **not required for v1** (and was later dropped entirely)

Rationale:

1. **Coverage where it counts is already complete.** Every user-owned process
   (the actionable set) reports an accurate Activity-Monitor-grade footprint
   through direct user-level reads. No helper is needed to fulfil the core value
   proposition (tell the user which of *their* apps is using memory and whether
   it matters).
2. **The unreadable set is non-actionable.** The processes that need root are
   system daemons the user cannot quit. MacPerfMonitor lists them by name (path is
   always readable) and honestly marks the footprint as unavailable using the
   `footprintReadable` flag already on `ProcessSample`.
3. **System taxonomy and pressure (the North Star) need no privilege at all.**
4. **The deep per-process breakdown** (`task_for_pid` + `task_info(TASK_VM_INFO)`
   for compressed/internal/external/dirty bytes) was later found to be
   unobtainable for other processes even with a root helper, because macOS gates
   `task_for_pid` on the target permitting debugging rather than on uid. It was
   evaluated and dropped (see PRD section 9); only MacPerfMonitor's own process can be
   read this way.

### Consequences carried into later milestones

- **M1+ model:** `ProcessSample.footprintReadable` and `dataSource` are populated
  per process. When footprint is unreadable and the helper is absent, the value
  is flagged, never faked as 0.
- **M2/M3 UI:** the process list and menubar show a coverage-gap affordance for
  unreadable processes instead of zeros.
- **Helper (evaluated, dropped):** a signed root XPC daemon was prototyped to add
  (a) footprint for non-owned/system processes and (b) the deep `TASK_VM_INFO`
  breakdown. It was removed once testing confirmed macOS denies `task_for_pid`
  for processes that do not permit debugging even to root, so the daemon added no
  real coverage. MacPerfMonitor runs entirely on direct user-level reads.

This satisfies the M0 acceptance criteria: the CLI prints accurate per-process
footprint matching Activity Monitor for readable processes, and the coverage
gaps and helper decision are documented here.
