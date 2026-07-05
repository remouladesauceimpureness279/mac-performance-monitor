# Changelog

All notable changes to MacPerfMonitor are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-06-10

The first tagged, notarised public release.

### Added

- **Sampling core.** Periodic, low-overhead sampling of every process and of
  system-wide memory, built on `libproc`, `mach`, and `sysctl` through a thin C
  shim, including Rosetta translation detection.
- **Local persistence.** A bounded, retention-managed SQLite store (via GRDB)
  for process and system history. No data leaves the machine.
- **Memory taxonomy.** A breakdown of where memory goes (app memory, cached
  files, compressed, wired, and more), with the formulas documented for audit.
- **Pressure-first dashboard.** A plain-language verdict, headline tiles, a hero
  pressure timeline (0 to 100 index) with selectable ranges, a taxonomy stacked
  bar, and a swap trend.
- **Process explorer.** A live, sortable, filterable process table with a detail
  inspector charting footprint, CPU, file descriptors, and disk I/O over time.
- **History and leak detection.** Top consumers over time, a leak board for
  steadily climbing processes, and a pressure-event log.
- **Insights and alerts.** Quiet-by-default notifications for critical pressure,
  sustained swap, per-process ceilings, and suspected leaks, with edge-triggering
  and hysteresis. Configurable in Settings.
- **Menu bar presence.** A pressure-tinted template glyph with a popover summary,
  built for a menu-bar-first lifecycle.
- **First-run onboarding.** A short, skippable, re-openable flow teaching the
  pressure-first mental model.
- **Accessibility.** VoiceOver labels and live value summaries on charts and
  process rows, Dynamic Type and semantic colours, and Reduce Motion honoured for
  chart animation.
- **Self-monitoring.** MacPerfMonitor samples its own process and shows its footprint
  in Settings, staying well under a 60 MB idle budget.
- **Repository hygiene.** Project documentation, license, contribution guidance,
  code of conduct, security policy, and a strict formatter configuration.
- **Continuous integration.** A GitHub Actions workflow that builds, tests, and
  lints on every push and pull request with no secrets, so any fork gets green
  CI. A separate, tag-triggered release workflow builds a universal binary,
  signs it with a Developer ID, notarises and staples it, builds a DMG, and
  publishes it to GitHub Releases, with all signing credentials confined to
  encrypted secrets used only on the release job.
- **Homebrew cask.** A `Casks/macperfmonitor.rb` cask, as a secondary install channel,
  pointing at the GitHub Release DMG.

[Unreleased]: https://github.com/Zesty0wl/mac-performance-monitor/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Zesty0wl/mac-performance-monitor/releases/tag/v1.0.0
