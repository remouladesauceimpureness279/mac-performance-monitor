# Diagnosis: "1620 file descriptors" and general slowness (2026-07-02)

> **Status (2026-07-03):** actions 1, 2 and 4 implemented — `fdCount` now
> performs the fill call with a reused scratch buffer (`FDCountScratch`),
> nettop pacing is adaptive (`NetworkProcessReader.paceSleep`, total cycle
> `max(2 s, 3 × run duration)`), and `FDWatchdog` logs the app's own FD
> breakdown at error level when a UI-driven operation (deep-dive, open-files
> inspector, memory export, insights run) completes with ≥ 200 descriptors
> open. The watchdog ships in release builds (not debug-only as suggested
> below) because the bursts were observed on the installed release build.
> Action 3 (profiling the sampler against the 2 %/60 MB budget) is still open.

Live diagnosis of the installed release app (1.1.4 build 107, PID 3094, running
since Jul 1 11:00) on an 18 GB M-series machine. Investigated with `libproc`
probes, `sample`, `top`, the unified log, and the app's own SQLite history at
`~/Library/Application Support/MacPerformanceMonitor/macperfmonitor.sqlite`.

## TL;DR

1. **The app does not have 1620 open file descriptors — it has ~27.** The
   number shown is the kernel FD *table capacity* (1600) plus XNU's +20 sizing
   slop, caused by `ProcessReader.fdCount(_:)` using only the sizing call of
   `proc_pidinfo(PROC_PIDLISTFDS)`. The table is a high-water mark that never
   shrinks, so the display is stuck at 1620. **Display bug — fix in
   `Sources/MacPerfMonitorCore/System/ProcessReader.swift:257`.**
2. **Real, transient FD bursts do occur** — the table doubled twice today
   (15:52 → 800 slots, 17:47 → 1600 slots), so something briefly held 800+ and
   then 1600+ descriptors open simultaneously. Cause not yet identified; it is
   event-driven, correlates with interactive/working hours, and is *not* a
   steady leak. Needs in-app instrumentation (see below). Not dangerous by
   itself (`kern.maxfilesperproc` = 61440).
3. **The perceived slowness is mostly machine-wide memory pressure** — swap
   10.4 of 11.3 GB used, load average ~4, memory pressure 57–96 % all day —
   but **the app is a real contributor**: this run averaged **13.5 % CPU
   (peak 64 %) and 334 MB footprint (peak 804 MB)** against the PRD budget of
   **2 % CPU / 60 MB** (docs/performance-budget.md). The per-app-network
   `nettop` one-shot also respawns back-to-back forever on this machine
   because one run takes ~5 s against a 2 s pacing floor.

---

## Finding 1 — the 1620 is a misread of the sizing call (display bug)

`fdCount(_:)` (`ProcessReader.swift:257`) returns
`proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0) / stride` — deliberately
skipping the fill call as a per-tick optimisation. But the sizing call does not
return the open-descriptor count. In XNU (`proc_pidfdlist`) it returns
`(p_fd->fd_nfiles + 20) * sizeof(proc_fdinfo)`, where `fd_nfiles` is the
**allocated FD table size**. The table starts at 25 slots, doubles on demand
(25 → 50 → 100 → … → 1600), and **never shrinks**.

Direct measurement of PID 3094 (2026-07-02 ~22:20):

| Probe | Result |
|---|---|
| Sizing call (`buffer = NULL`) | 12 960 bytes = **1620** entries |
| Fill call (actual list) | **27** FDs: 23 vnode, 2 socket, 1 pipe, 1 channel |
| `lsof -p 3094` | 131 lines (incl. txt/cwd segments), consistent with 27 real FDs |

1620 = 1600 (table) + 20 (XNU sizing slop). Exact match.

The app's own database confirms the recorded `fd_total` walks the doubling
ladder and only ever goes up — these are `fd_nfiles + 20` plateaus, not counts:

| First seen (local) | Recorded `fd_total` | Implied table size |
|---|---|---|
| Jul 1 11:xx (launch) | 45 | 25 |
| Jul 1 12:xx | 70 | 50 |
| Jul 1 15:xx | 220 | 200 |
| Jul 1 16:00 → Jul 2 15:51 | 420 (flat ~24 h) | 400 |
| Jul 2 15:52 | 820 | 800 |
| Jul 2 17:47 | 1620 | 1600 |

Corroborating detail: recent `process_samples` rows for the app show
`fd_total = 1620` with `fd_vnode = fd_socket = fd_pipe = fd_other = 0` — the
per-tick sampler stores the sizing-call value while the breakdown (which counts
correctly via the fill call) is only populated on demand.

**Fix**: make `fdCount` perform the fill call and return
`ret / MemoryLayout<proc_fdinfo>.stride` (what `fdBreakdown` already does). To
keep the per-tick path cheap across ~500 processes, reuse a single scratch
buffer per reader instead of allocating per process. `fd.growthPct` in
`DiagnosticProbes` and the leak heuristics built on `fdTrail` currently see
table plateaus, not real counts, so FD-leak insights are unreliable until this
is fixed.

## Finding 2 — real transient FD bursts, source not yet identified

The table doublings are real events: growth to 1600 slots requires ≥800 (and
then ≥1600) descriptors **simultaneously open**, however briefly. Two episodes
today at 15:52 and 17:47.

What the bursts are **not** (all tested live):

- **Not a steady leak** — live count was flat at exactly 27 for 3+ minutes of
  0.2 s–5 s polling; type histogram unchanged.
- **Not per-new-process work** — spawning 300 short-lived processes (a
  synthetic storm, scanned across multiple 2 s process-scan ticks) moved the
  app's live FD count from 27 to at most 28.
- **Not logged** — zero error-level entries in the unified log for subsystem
  `uk.co.bzwrd.macperfmonitor` over the last 2 days (so no nettop timeouts
  either).
- **Not the nettop/ping/memory-tool spawners leaking steadily** — all three
  wrap Process/Pipe in `autoreleasepool` and their transient pipe FDs appear
  and vanish within a tick (the 28–33 wobble observed during spawns).

What is known about the pattern:

- Bursts happen **only during interactive working hours**: table was flat at
  420 slots from Jul 1 16:00 through the whole night and next morning, then
  doubled twice within 2 h of afternoon use.
- Both of today's episodes coincide with heavy system activity in the DB
  (iOS-Simulator `xpcproxy_sim` processes, `mdworker_shared` floods), i.e.
  times the user was actively working — and plausibly actively *using the
  app's UI* on a struggling machine.
- No unusual child processes of the app at either timestamp (only the routine
  `nettop` every ~17 s under load, occasional `ping`).

**Recommended instrumentation** (cheap, debug-only): a watchdog that calls
`fdBreakdown(getpid())` after each UI-driven operation (deep-dive open, files
inspector, export, insights run) and `os_log`s the breakdown whenever the total
crosses, say, 200. Until then, an external watcher can catch the next burst:

```sh
PID="$(pgrep -f 'Mac Performance Monitor.app/Contents/MacOS/Mac Performance Monitor')"
while sleep 0.5; do
  n=$(lsof -p "$PID" 2>/dev/null | wc -l)
  if [ "$n" -gt 250 ]; then lsof -p "$PID" > "/tmp/fd-burst-$(date +%H%M%S).txt"; fi
done
```

Impact if left alone: cosmetic (the display bug is what makes it look scary);
the per-process limit is 61 440. But whatever opens 1600 files/sockets in a
burst is also doing 1600 opens' worth of I/O on a machine that is already
thrashing, so it is worth finding.

## Finding 3 — the slowness itself

**Machine-wide (dominant cause).** From `sysctl`/`memory_pressure` and the
app's own `system_minute` history for today:

- Swap: **10.4 GB used of 11.3 GB** total.
- Memory pressure: 57–63 % all day, **peak 96 %** at 10:00.
- Load average ~3.7–4.2 with Chrome, iOS Simulator, and mdworker storms in the
  process record. An 18 GB machine deep into swap will feel slow regardless of
  this app.

**The app's contribution (significant, and over budget).** The PRD budget is
**≤ 2 % CPU, ≤ 60 MB** (docs/performance-budget.md; budget assumes menubar
only, no main window — the main window was likely open for much of this run,
so treat the comparison as indicative, not a straight violation):

| Metric (this 35 h run, from its own DB) | Measured | Budget |
|---|---|---|
| CPU, lifetime average | 13.5 % (274 min total) | 2 % |
| CPU, minute peak | 64 % | — |
| Footprint, average | 334 MB | 60 MB |
| Footprint, peak | 804 MB (641–768 MB observed live) | 60 MB |

Helper (`MacPerfMonitorHelper`, root): 1:19 CPU total over 35 h — negligible.
Threads (16) and Mach ports (~1015–1077) are stable — no runaway there.

**nettop respawn loop degenerates on slow machines.** One
`nettop -P -x -J bytes_in,bytes_out -L 1` takes **5.1 s** on this machine idle
(and ~17 s during this afternoon's load, per spawn intervals recorded in the
DB) against `minRefreshInterval = 2` s
(`NetworkProcessReader.swift:37`). The refresh loop's sleep is therefore never
taken — the app spawns nettop back-to-back, ~500–700 times per hour,
continuously (confirmed by `sample`: the nettop serial queue spent an entire
3 s sample inside `runOneShot`). Each run is only ~0.06 s CPU, but it is
constant process-spawn churn and a full system socket walk, applied hardest
exactly when the machine is already struggling. Consider (a) an adaptive floor,
e.g. `max(2 s, 3 × last run duration)`, and/or (b) one persistent
`nettop -L 0 -s <n>` stream parsed incrementally instead of one-shot spawns.

## Suggested actions, in order

1. **Fix `fdCount` to count, not size** (ProcessReader.swift:257) — removes
   the false "1620", and makes `fdTrail`/`fd.growthPct` insights meaningful.
2. **Adaptive nettop pacing or a persistent stream** — stops the always-on
   spawn loop on machines where a run exceeds the 2 s floor.
3. **Profile the sampler against budget on this machine** — 13.5 % average CPU
   and 334 MB average footprint are far above the 2 %/60 MB targets even
   allowing for the open main window; the 0.5 s system tick / 2 s process scan
   split (already tuned once) is the place to look.
4. **Add the FD-burst watchdog** and catch the next burst in the act.

## Appendix — key evidence commands

```sh
# True FD count vs sizing call (the bug, demonstrated)
python3 -c 'import ctypes; lp=ctypes.CDLL("/usr/lib/libproc.dylib"); ...'
# sizing: 12960 bytes -> 1620 "entries"; fill: 27 actual FDs

# One nettop run with the app's exact arguments
/usr/bin/time nettop -P -x -J bytes_in,bytes_out -L 1 > /dev/null
# 5.10 real / 0.03 user / 0.03 sys

# FD-table history from the app's own DB
sqlite3 "file:$HOME/Library/Application Support/MacPerformanceMonitor/macperfmonitor.sqlite?mode=ro" \
  "SELECT datetime(bucket,'unixepoch','localtime'), fd_max FROM process_minute
   WHERE process_id = (SELECT id FROM processes WHERE pid=3094 ORDER BY start_time DESC LIMIT 1)
   ORDER BY bucket"
```
