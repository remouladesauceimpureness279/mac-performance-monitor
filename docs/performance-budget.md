# Performance budget report

MacPerfMonitor watches memory, so it must not be a memory hog itself. The PRD sets a
hard budget (section 3, "Performance budget"):

> Targets at the default 2-second sampling cadence with the menubar active and
> no main window open:
> - MacPerfMonitor memory under 60 MB.
> - CPU under 2% time-averaged on an M1.

This document records how MacPerfMonitor measures itself against that budget and the
results from the Milestone 8 measurement pass.

## How MacPerfMonitor monitors itself

MacPerfMonitor samples every process on the system, including its own. `SamplerModel`
exposes `selfUsage`, which looks up the current process (`getpid()`) in the
latest snapshot and returns its physical footprint and CPU. The Settings window
shows this live in the **About** section ("MacPerfMonitor itself: 19.2 MB · 0.4%
CPU"), so the budget is visible to the user, not just the developer.

For external verification the standard macOS tools are used against the release
build:

```sh
# The process is named "Mac Performance Monitor" (the bundle executable). Its
# name exceeds the kernel's 16-char accounting limit, so match the full bundle
# path with `pgrep -f` rather than `pgrep -x` on the truncated name.
PID="$(pgrep -f 'Mac Performance Monitor.app/Contents/MacOS/Mac Performance Monitor')"

# Physical footprint
vmmap --summary "$PID" | grep 'physical footprint'

# CPU, time-averaged over 60 s at the 2 s cadence (skip the first sample)
top -l 31 -s 2 -pid "$PID" -stats cpu \
  | awk '/^[0-9]+\.[0-9]+/ {n++; if(n>1){sum+=$1; if($1>max)max=$1}}
         END {printf "avg %.2f%%  peak %.2f%%\n", sum/(n-1), max}'
```

## Results (release build, M1, macOS 14+)

The canonical budget state is **menubar active, no main window open**.

| State | Metric | Budget | Measured | Result |
| --- | --- | --- | --- | --- |
| Launched, window never opened | Physical footprint | < 60 MB | 19.0 MB | PASS |
| After opening and closing the window | Physical footprint | < 60 MB | 47.4 MB (stable) | PASS |
| Menubar active, window closed | CPU, time-averaged | < 2% | 1.31% | PASS |

The CPU peak during a sample is higher (around 8%) for the brief moment MacPerfMonitor
walks all ~580 processes every two seconds; the budget is time-averaged, and the
average sits comfortably under 2%.

## The window-close reclaim

Opening the main window builds a lot of one-shot UI: Swift Charts, the full
process table (hundreds of rows and icons), and their backing stores. SwiftUI
keeps a closed `Window`'s view tree mounted by default, so without intervention
that machinery stays resident (and keeps re-rendering on every sample) long
after the window is gone, pushing the footprint well past the budget.

MacPerfMonitor addresses this in three ways:

1. **The window content is gated on an explicit open flag.** `AppState`
   publishes `mainWindowOpen`, driven by `NSWindow` key/close notifications.
   When the window closes, the heavy `ContentView` is unmounted and replaced by
   an empty background that holds no reference to the model, so it stops
   rendering entirely.
2. **The icon cache is bounded.** Process icons use an `NSCache` (count-limited
   and automatically evicted under pressure) rather than an unbounded
   dictionary, and it is purged when the window closes.
3. **Freed pages are returned to the OS.** After the view tree tears down,
   `malloc_zone_pressure_relief` hands the freed-but-retained heap pages back to
   the kernel, so the physical footprint actually drops rather than lingering.

Together these bring the post-close footprint from roughly 186 MB down to a
stable ~47 MB, back inside the budget.
