# Onboarding and accessibility

This note records the Milestone 8 "polish" decisions: the first-run flow that
teaches MacPerfMonitor's mental model, and the accessibility work that makes the app
usable with VoiceOver, Dynamic Type, and Reduce Motion.

## First-run onboarding

The PRD (section 8.9) asks for a short first-run flow that teaches the
pressure-first mental model: "free RAM is not the metric, cached files are
good, compression and swap under sustained pressure are the real signals", kept
to two or three screens, skippable, and re-openable from Help.

MacPerfMonitor ships exactly three screens, one per idea:

1. **Watch pressure, not free RAM.** On Apple silicon almost no RAM is ever
   "free", and that is normal; what matters is memory pressure.
2. **Cached files are a good thing.** macOS keeps memory busy on purpose;
   cached file data is reclaimable, not waste.
3. **Compression and swap are the real signals.** Under sustained pressure macOS
   compresses and then swaps; a little is fine, a lot is the warning sign, and
   MacPerfMonitor points to the process responsible.

Design details:

- A dedicated `Window` scene (`WindowID.onboarding`, title "Welcome to
  MacPerfMonitor"), not a sheet, so it survives the menubar-only lifecycle and can be
  re-opened on demand.
- A custom paged container (not `TabView`) so macOS does not draw empty tab
  pills above the content. Pages slide-and-fade; the transition collapses to a
  plain cross-fade under Reduce Motion.
- **Skippable:** every screen except the last shows a Skip button; the last
  shows "Get started". Both call `OnboardingState.complete()`.
- **Re-openable:** the menubar menu has a "How MacPerfMonitor works…" item that opens
  the same scene, and re-opening is also wired to a notification so any future
  entry point can trigger it.
- Completion persists to `UserDefaults` (`hasCompletedOnboarding`). The flow
  only auto-appears when that flag is unset, so it shows once per user.
- Closing the onboarding window runs the same memory-reclaim path as the main
  window, so a mid-session replay from Help leaves no footprint bump behind.

## Accessibility

The PRD (section 8.13) asks for "full VoiceOver labels on charts and process
rows, Dynamic Type, sufficient contrast, reduced-motion honoured for chart
animation."

### VoiceOver

- **Charts.** Each chart (`PressureChart`, `SwapChart`, `MetricChart`) exposes an
  `accessibilityLabel` naming the chart and an `accessibilityValue` that speaks a
  live summary (the current value plus the range or peak over the visible
  window) so a blind user hears the trend without seeing it. For example:
  "Memory pressure timeline, currently warning at 45 percent, window range 20 to
  60 percent."
- **Process rows.** The `Table` reads each column value natively. Two ambiguous
  cells get explicit labels: the Rosetta badge reads "Running under Rosetta
  translation" rather than the bare word "Rosetta", and the unreadable-footprint
  placeholder reads "Memory not readable" rather than an em dash.

### Dynamic Type and contrast

The UI uses semantic text styles (`.caption`, `.subheadline`, body) rather than
fixed point sizes, so it tracks the system text-size setting. All colour comes
from semantic system colours (`.primary`, `.secondary`, `windowBackgroundColor`)
and the standard accent palette, which adapt automatically to light/dark
appearance and the Increase Contrast setting.

### Reduce Motion

`Motion.reduced` reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
(the SwiftUI `\.accessibilityReducedMotion` environment key does not resolve in
this SDK). The `.reducedMotionAware()` view modifier strips implicit animations
from a view's transactions, and is applied to every chart so live chart updates
do not animate when the user has asked for reduced motion. The onboarding page
transition uses the same flag to fall back to a cross-fade.
