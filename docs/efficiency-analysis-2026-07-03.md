# Efficiency analysis: recording + interactive analysis (2026-07-03)

Exhaustive performance analysis of build 108 (1.1.4, signed release, live on this
machine) covering the two hot areas: **recording to the database** and
**interactive analysis in the main window** (the Monitor-tab beachballs).
Sources: full code trace of the persistence layer, the tick pipeline, and the
main-window UI, plus live measurements against the production database
(445 MB) and query-planner verification.

## Ground rules (constraints on every fix below)

1. Full mode always logs to the database — recorded fidelity is untouchable.
2. Menu-bar menus update at 1 s while open.
3. The main app updates at the global refresh control's cadence
   (`tableIntervalKey`: 1 s–300 s, default 10 s).

None of the recommendations change what is recorded, the popover cadence, or
the refresh-control semantics. Several *restore* rule 3 (today an open popover
forces parts of the main window to re-render at 1 Hz regardless of the dial).

## Live measurements (this machine, 2026-07-03)

| Fact | Value |
|---|---|
| Database size | **445 MB** (WAL 9 MB, freelist 0) |
| `process_minute` | **3,720,155 rows**, 7.0-day span |
| `process_hour` | 539,408 rows, 19.5-day span |
| `process_samples` (raw) | 169,623 rows, ~24-min span |
| `processes` (dimension) | **188,136 rows — 147,596 not seen in >7 days** |
| Distinct processes in the minute tier | 40,570 per week (identity churn) |
| 1 h raw-tier aggregate (topConsumers shape) | 31 ms, 1,691 groups |
| 24 h minute-tier aggregate | **397 ms**, 6,600 groups |
| 30 d hour-tier aggregate | 183 ms, **187,504 groups returned** |
| 24 h minute series + `processes` JOIN | **512,529 rows returned** |
| Steady-state CPU (window open, 1 s dial) | 4–14 % bouncing |

`EXPLAIN QUERY PLAN` confirms both leaderboard shapes degenerate:

- Raw tier: `SCAN ... USING COVERING INDEX idx_process_samples_consumer` +
  `TEMP B-TREE FOR ORDER BY` — a **full scan of the whole 2 h tier** whatever
  the window, because `timestamp` is the index's *second* column.
- Minute tier: `SCAN ... USING INDEX sqlite_autoindex_process_minute_1` +
  temp b-tree — a **full scan of all 3.7 M rows** with a table lookup per row
  (no covering index exists on the aggregate tiers at all).

The headline: **SQLite is not the bottleneck — architecture is.** The worst
raw scan is ~0.4 s. The beachballs come from (a) every UI read serializing
behind sampling on one queue, (b) hundreds of thousands of rows being decoded
into Swift and re-crunched on the main thread per tick, and (c) Swift Charts
rebuilding ~12,000 mark views per body evaluation in the Monitor tab.

## Root causes (architecture level)

### RC1 — One serial queue carries everything

The sampler's serial queue (`SamplerModel.swift:162`) runs: the 1 Hz tick, the
heavy process scan, the ~600-row persist transaction, the once-a-minute
retention pass, the WAL checkpoint, **and every UI-triggered DB read** —
`loadSystemHistory`, `loadProcessHistories`, `loadTopConsumers`,
`loadInsightsBundle`, `loadGroupReport`, `loadOpenFiles` (syscall-per-FD!),
`loadTeamIDDirectory` (certificate reads) — `SamplerModel.swift:1100–1510`.
GRDB's `DatabasePool` supports fully concurrent WAL readers; the serialization
is purely GCD. Consequences:

- A long analysis read delays the tick → menubar heartbeat and window data
  stall together.
- Ticks/persist/retention delay analysis reads → tab loads feel sluggish and
  stack up at fast dials.

Only the leak scan already has its own queue (`leakScanQueue`,
`SamplerModel.swift:239`) — the pattern to generalize.

### RC2 — The Monitor tab re-reads and re-renders the world every tick

The exact beachball flow (`PerformanceMonitorView.swift`):

1. Every table tick in any historical span triggers a **full window re-read**
   for all selected processes (`:84–86`) — no incremental append, even though
   `loadNewProcessHistory` exists and `ProcessDetailView` uses it for raw
   ranges (`ProcessDetailView.swift:140–148`).
2. The completion merges and trims full arrays on the **main thread**
   (`:403–411`).
3. `chartSeries` (`:375–383`) re-transforms up to 5 metrics × 8 processes ×
   1,900 points ≈ **76k point transforms per body evaluation** — and the body
   re-evaluates on every model publish *and every legend hover*.
4. `PerformanceChart` builds per-point `LineMark`s — ~2,400 marks × 5 charts ≈
   **12,000 SwiftUI views per evaluation** (`PerformanceChart.swift:143–212`).
   Scrubbing updates `scrubDate` per mouse-move (`:262–276`) → full chart
   re-layout **per mouse event**.

`MetricChart` (`MetricChart.swift:44–51`) already shows the cure: a 160-point
cap plus an `Equatable` gate.

### RC3 — Aggregate tiers have no covering index; window queries scan whole tiers

- Raw covering index leads with `process_id`, so windowed GROUP BYs filter the
  entire tier (`HistoryQuery.swift:197–225`). Worst: `topEnergyConsumers(60s)`
  pays a full-tier scan for a 60-second window every 15 s while Energy is
  visible (~130 ms each, acknowledged in code).
- Minute/hour leaderboards (6 h/24 h/7 d) scan up to 3.7 M rows with per-row
  lookups (`HistoryQuery.swift:229–257`) — confirmed by EXPLAIN above.
- No `ANALYZE`/`PRAGMA optimize` anywhere, so the planner has no statistics to
  choose better plans (`Database.swift`).

### RC4 — The recording path does avoidable per-tick work

- **~600 `sqlite3_prepare`s per persist tick**: rows insert via
  `db.execute(sql:)`, which bypasses GRDB's statement cache
  (`SampleStore.swift:84, 142`). One transaction per tick is already right;
  the prepares and ~22 boxed arguments per row are pure overhead.
- **`clearProcessIDCache()` after every retention pass**
  (`SamplerModel.swift:872`) → the next persist re-upserts all ~600
  `processes` rows, every minute.
- **Retention runs inside the sampler queue's tick chain**
  (`SamplerModel.swift:867–871`): roll-ups, six DELETEs (3 index b-trees
  each), a tri-tier `DISTINCT` sub-scan for the dimension prune
  (`Retention.swift:293–300`), incremental vacuum — and the size-cap path can
  delete up to 500k rows in one transaction. This is the known once-a-minute
  CPU spike, and it delays ticks.
- `process_samples` maintains **4 b-trees per insert/delete** (table + PK
  index + timestamp index + 6-column covering index).

### RC5 — Main-thread work with no consumer, and publisher fan-out

- In full mode with window and popovers closed, every heavy tick still runs
  `updateTrails` + `smoothedCPUMap` + `refreshMenuLists` (3–4 O(n log n)
  sorts) + `rebuildDisplayProcesses` on the **main thread for zero observers**
  (`SamplerModel.swift:632–670`). Recording needs the *scan*, not the UI
  rebuilds.
- An occluded/minimized window keeps its process consumer (registration
  follows open/close only, `MacPerfMonitorApp.swift:568–596`).
- `SamplerModel` is one `ObservableObject` observed by ~20 views: while a
  popover is open, the four `menuTop*` `@Published` writes fire at 1 Hz and
  re-evaluate every mounted main-window body at 1 Hz — defeating the global
  refresh dial (ground rule 3) whenever a popover and the window are open
  together. All four top lists are computed even when one popover needs one.

### RC6 — Repeat-query storms the caches don't cover

- **Insights bundle** re-runs every table tick while visible
  (`InsightsView.swift:66`, `SamplerModel.swift:1437–1510`): leak board
  (cached 55 s) + `pressureEvents` (**uncached**, and an N+1: one
  `dominantProcess` query per pressure event over ~600 rowid lookups each,
  `PressureEvents.swift:39–91`) + full 2 h raw system history (**uncached**,
  ~3,800 rows × 33 by-name column decodes) + 8 × 30-min raw histories
  (**uncached**) — all serialized on the sampler queue.
- `SystemHeaderView` re-reads the full 2 h raw system history and downsamples
  on main **every table tick** (`SystemHeaderView.swift:56–66`).
- `ProcessDetailView` aggregate ranges do `fullReload()` of the whole window
  every heavy tick for data that changes once a minute
  (`ProcessDetailView.swift:128–139`).
- Per-body-evaluation recomputation on main: `leakFinding` runs
  `LeakDetector.analyze` (which **sorts the series**) per evaluation
  (`ProcessDetailView.swift:97–100`); Insights re-downsamples 3,800→360 per
  evaluation (`InsightsView.swift:288–290`); `rosettaSummary()` scans ~600
  processes per evaluation (`InsightsView.swift:56`); `TrendChart` allocates a
  `DateFormatter` inside the Canvas draw closure per redraw
  (`TrendChart.swift:202–204`).

## Prioritized implementation plan

### Phase 1 — Unblock the pipes (structural; biggest beachball win)

1. **Dedicated reader queue for all UI-triggered DB reads** (concurrent or
   utility serial; the `leakScanQueue` pattern). Move the queue-confined TTL
   caches with them (lock or actor). Also moves `loadOpenFiles` and
   `loadTeamIDDirectory` off the tick path. *Ticks never wait on analysis;
   analysis never waits on ticks.*
2. **Move `Retention.run` (and the checkpoint) off the sampler queue**; split
   the size-cap trim into bounded transactions. Kills the once-a-minute tick
   stall.
3. **Covering indexes on the aggregate tiers** (v9 migration), e.g.
   `process_minute(bucket, process_id, samples, footprint_avg, footprint_max,
   cpu_avg, energy_avg, net_avg)` and the hour equivalent, plus a one-time
   `ANALYZE` and periodic `PRAGMA optimize`. Expect the same ~7× the raw
   covering index delivered; my 397 ms / 24 h scan should drop well under
   100 ms with no row decode change.

### Phase 2 — The Monitor tab (interactive smoothness)

4. **Equatable-gate + memoize `PerformanceChart`** (the `MetricChart`
   pattern): hoist `segments`/`yMax` out of body; recompute `chartSeries` into
   `@State` only when `rawSeries`/selection change, not per evaluation/hover.
5. **Throttle scrubbing**: update `scrubDate` only when the nearest bucket
   changes (or replace the 5 charts with the Canvas `TrendChart` approach —
   larger but eliminates the 12k-mark rebuilds entirely).
6. **Incremental appends for historical spans**: on `displayProcessesVersion`
   fetch only rows since the last point (API already exists); aggregate ranges
   refresh at most once per minute bucket. Same for `ProcessDetailView`
   aggregate ranges.
7. **Downsample on the reader queue**, not main: Dashboard/Battery
   `rebuildPoints`, SystemHeader completion, Monitor merge/trim.

### Phase 3 — Recording cost

8. **Cached prepared statements** for the per-row INSERT (GRDB
   `cachedStatement`), reused across the ~600 rows and across ticks.
9. **Stop clearing the process-ID cache wholesale** after retention; evict
   only identities absent from the current snapshot.
10. **Gate the dimension prune** (tri-tier DISTINCT scan) to every Nth pass or
    to passes where deletes actually removed rows.
11. **Batch the `pressureEvents` N+1** into one query for all event
    timestamps, selecting only needed columns positionally.

### Phase 4 — Idle waste and publisher granularity

12. **Gate the main-thread rebuild block on real consumers** (window visible
    or popover open); in full mode with nothing open, recording continues on
    the sampler queue and the main thread does nothing per tick.
13. **Release the window's process consumer on occlusion** (with a few
    seconds' hysteresis), not just on close.
14. **Split the popover publishers out of `SamplerModel`** (small
    `ObservableObject` for `menuTop*`) so popover 1 Hz refreshes stop
    invalidating main-window bodies; compute only the open popover's list
    (per-kind consumer registration).
15. Small stuff: cache `TrendChart`'s `DateFormatter` and `runs()` median;
    memoize `leakFinding` and Insights downsampling; NetworkView poll off
    main + memoized `chartPoints`; async Settings DB-size read; don't purge
    the icon cache on window close; fix stale cadence/QoS comments
    (`SamplerModel.swift:118–123, 154–162, 301–307`).

## What this buys (estimates)

- **Beachballs**: Phases 1–2 remove the three multiplicative causes (queue
  contention × full re-reads × 12k-mark re-layout). Scrubbing and span
  changes become O(new data) + O(300 points drawn).
- **Recording**: Phase 3 removes ~600 statement preparations and (once a
  minute) ~600 dimension upserts per tick, and takes the retention spike off
  the tick path — flatter CPU at fast dials, headroom the ground rules
  require at 1 s popover cadence.
- **Idle full mode**: Phase 4 makes "window closed, recording on" cost the
  scan + insert only — no main-thread work — while popovers/window get
  identical data the moment they open.

## Verification methodology

Measure on a **signed release build only** (dev builds mis-measure; see
docs/perf history): average `ps`/`top` over minutes, plus Instruments Time
Profiler for the Monitor-tab scrub before/after Phase 2. The app's own DB
gives lifetime CPU/footprint averages per run for A/B comparison. Query wins
are verifiable headlessly via `sqlite3 .timer` + `EXPLAIN QUERY PLAN` (the
30 d/24 h shapes above are the regression benchmarks).

## Implementation status (2026-07-03)

All four phases implemented; 259 tests pass. A high-effort code review of
the full diff (8 finder angles, each finding verified against the code)
surfaced 10 real defects in the first cut, all fixed:

1. **`last_seen` freeze (top severity)** — the id-cache prune meant a
   continuously-live process was never re-upserted, so `processes.last_seen`
   froze at first persist and Groups membership (`WHERE last_seen >= now -
   window`) silently dropped long-running processes. Fixed with
   `SampleStore.touchLastSeen(keeping:)` — one batched UPDATE per retention
   pass (regression-tested).
2. **`requestImmediateTick` forced the heavy path for every caller** — each
   popover open republished the main window off-dial, reset the dial phase,
   and at slow dials fired a checkpoint + retention pass. Reverted to a plain
   tick; surfaces still refresh instantly because consumers register first
   (MenuClock order / `addProcessConsumer`'s 0→1 forces the table due).
3. **Network list republished at 1 Hz while any popover was open** — the
   `.network` menu kind is now computed on table-due ticks only.
4. **Tracking-off network popover forced the 1 Hz scan** — an open `.network`
   popover no longer demands the scan while per-app attribution is off
   (gated in `tick()`, self-heals if the toggle flips mid-open).
5. **Frozen trails contaminated smoothed CPU after idle** — trails reset when
   the UI-feeding scan resumes after a real gap (> 3 dial intervals).
6. **Reopened popovers flashed dead rows** — a list not recomputed within the
   dial interval is cleared on popover open; table-due ticks now refresh all
   kinds so lists stay ≤ one interval stale while anything scans.
7. **Leak badge lagged the chart by one interval** — verdict now recomputed
   in the append completion, after the rows land.
8. **Phantom network-rate spikes** — NetworkView polls now stamp time at
   read time on the poll queue, not at schedule time on main.
9. **Unbounded `incremental_vacuum` in the size-cap step** — bounded to 2000
   pages per batch, matching the pass design.
10. **TeamID directory blocked the read funnel** — SecStaticCode resolution
    hops to a global queue; only the seed query stays on `readQueue`.
Plus (unreported, trivial): the dimension-prune watermark now self-heals
after a backward clock correction, and `MenuListsModel.update` skips no-op
publishes (`ProcessSample` is now `Equatable`).

### Live verification (signed build 110, 2026-07-03)

- **Recording (ground rule 1)**: menubar-only, everything closed — system
  rows land exactly at the 10 s dial cadence, ~736 process rows per persist,
  latest row seconds old. ✓
- **v9 indexes**: present on the production DB with fresh `sqlite_stat1`
  (migration + ANALYZE ran on first launch). 24 h minute-tier consumer
  query: ~0.4–0.5 s user CPU warm on the grown DB, on `readQueue` — off the
  UI and sampler paths either way. ✓
- **`last_seen` fix**: WindowServer's row was 28 s fresh minutes after
  launch, while its id sat in the cache the whole time — only
  `touchLastSeen` can have advanced it (the pre-fix code left it frozen at
  launch). ✓
- **Steady-state CPU (menubar-only, per-app nettop ON)**: 6.4% of one core
  over 120 s, RSS ~150 MB. A 30 s `sample` attributes the cost to the
  nettop one-shot loop (the opt-in per-app attribution feature), the ~20 s
  WAL TRUNCATE checkpoint, and the periodic leak board — the sampler is
  near-idle between bursts. No like-for-like build-108 baseline exists for
  this state; profiling against the 2%/60 MB budget (fd-count doc, item 3)
  remains the open follow-up, and per-app tracking off is the first lever.

Hands-on checks that need a human: popover 1 Hz while open, dial-paced main
window with a popover open simultaneously, Monitor-tab scrub on a 30 d
window (the beachball scenario).
