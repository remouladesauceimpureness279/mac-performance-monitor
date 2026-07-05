# "N processes not readable" — usually the SIP baseline, NOT a helper drop

_Investigation, 2026-07-01. Deep-dive triage of the recurring "the helper isn't
communicating so we get N processes not readable" report. No code was changed;
this documents what's actually happening so a follow-up change can be scoped._

## TL;DR

On the host inspected, **the helper was not losing connection.** The
Processes-header "N not readable" figure has a **permanent, non-zero floor** —
a set of SIP-protected system processes that macOS refuses to let *anyone*
inspect, including root. That floor (~44 on a ~785-process Mac) is easy to
misread as "the helper dropped." The giveaway that the helper is actually
healthy: system/other-user processes such as **WindowServer** (owned by
`_windowserver`) are still visible — they are only readable *because* the root
helper served them.

## Why there is an irreducible floor

`phys_footprint` comes from `proc_pid_rusage` / task info, and the deep breakdown
needs `task_for_pid` + `task_info(TASK_VM_INFO)`. A set of SIP-protected system
processes (`kernel_task` plus hardened Apple daemons) **resist inspection
regardless of root** — see [../data-layer-findings.md](../data-layer-findings.md)
and [../../PRD.md](../../PRD.md).

In `Sampler.tickProcesses` the count only decrements for PIDs the helper actually
read:

```swift
// after the privileged (root helper) read of the user-level-unreadable PIDs:
for pid in unreadablePIDs {
    guard let raw = reads[pid], let info = raw.task else { continue } // still unreadable → stays counted
    processes.append(buildSample(... source: .privilegedHelper ...))
    unreadable -= 1
}
```

So the SIP residual is never decremented, and `unreadableProcessCount` sits at a
non-zero baseline **even with a perfectly healthy helper.**

## How to tell the BASELINE apart from a REAL disconnect

| Signal | Healthy baseline | Real disconnect |
|---|---|---|
| `unreadable` count | ~40–50 (the SIP set) | jumps to ~200–250 (all non-user processes) |
| WindowServer / system procs | **visible** | **gone** |
| logs (`subsystem == uk.co.bzwrd.macperfmonitor`) | quiet | `helper unreachable` / `helper read timed out` / `recovering helper` |
| persisted `process_samples` | ~fully readable | large gaps |

## Live-diagnosis commands (host on 2026-07-01: HEALTHY, not disconnected)

```sh
# helper process + mach service state
pgrep -x MacPerfMonitorHelper
launchctl print system/uk.co.bzwrd.macperfmonitor.helper | grep -iE "state =|pid =|last exit|endpoints"

# process population: total vs not-owned-by-me (the set the helper fills)
ps -axo user= | wc -l                 # total
ps -axo user= | grep -vc "$(id -un)"  # not owned by me

# how many distinct processes the app is actually reading right now
DB="$HOME/Library/Application Support/MacPerformanceMonitor/macperfmonitor.sqlite"
sqlite3 -readonly "$DB" "SELECT COUNT(DISTINCT process_id) FROM process_samples WHERE timestamp >= strftime('%s','now')-12;"

# real-disconnect signatures over 3 days (0 == no disconnect happened)
log show --last 3d --predicate 'subsystem == "uk.co.bzwrd.macperfmonitor"' --info --style compact \
  | grep -icE "recovering helper|helper unreachable|read timed out"
```

Measured on the host: **785** total processes, **244** not owned by the user,
app reading **747** → the ~38–44 gap is the SIP residual (= the reported "44").
App and helper are signed identically (Developer ID: team `<TEAMID>`), helper
`state = running` with active endpoints, and **0** disconnect/recovery log events
in 3 days.

## Real-disconnect code mechanism (for a later fix, if it genuinely occurs)

The helper is demand-launched by launchd and **idle-exits when no client is
connected** (menu-bar-only / window closed). On reopening the window, the first
privileged reads can exceed `HelperConnection`'s **2 s** timeout while the root
daemon cold-launches → 3 consecutive misses → `Sampler` sets a **20 s** quiet
window (`privilegedQuietUntil`) and fires `onPrivilegedReadFailure` →
`HelperManager.recoverHelper()` (guarded by `coverage == .enabled` and a 25 s
cooldown). During that ~20 s window *all* non-user processes read as unreadable
(a transient spike), then it self-heals.

Suspects to investigate for a genuine recurring disconnect:

1. **2 s timeout vs cold demand-launch latency** — a cold root-daemon launch can
   exceed 2 s, tripping the failure streak on every window reopen.
2. **macOS 26/27 duplicate app generations (BTM)** — the code comments in
   `HelperManager` already fight this; two app pids were observed in the logs
   (80700 then 20624).
3. **Frequent `refresh()`** — logs show `helper status: enabled` every ~20–80 s;
   worth confirming that isn't churning the connection/coverage state.

## UX fix idea (later)

Don't fold the irreducible SIP set into the alarming "not readable" count.
Distinguish **"OS-protected (normal)"** from an **actionable helper coverage
gap**, so a healthy state reads as healthy instead of permanently showing
"~44 not readable."
