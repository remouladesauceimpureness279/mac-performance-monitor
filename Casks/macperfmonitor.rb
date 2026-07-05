# Homebrew cask for Mac Performance Monitor.
#
# Secondary distribution channel (the primary is Sparkle auto-update; the manual
# download is the notarised DMG on GitHub Releases). Scripts/deploy.sh rewrites the
# `version` and `sha256` fields below on every release (to the built DMG's digest),
# so the cask always points at the current tagged release; commit the change after.
#
# `version` is the full <short>.<build> string, matching the release tag `v#{version}`
# and the per-tag DMG URL. Until the first real release these are placeholders.
cask "macperfmonitor" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Zesty0wl/mac-performance-monitor/releases/download/v#{version}/MacPerformanceMonitor.dmg",
      verified: "github.com/Zesty0wl/mac-performance-monitor/"
  name "Mac Performance Monitor"
  desc "Pressure-first memory analysis utility"
  homepage "https://github.com/Zesty0wl/mac-performance-monitor"

  # Mac Performance Monitor uses APIs that require macOS 15 Sequoia or newer.
  depends_on macos: :sequoia

  app "Mac Performance Monitor.app"

  # Quit the running app before replacing or removing it.
  uninstall quit: "uk.co.bzwrd.macperfmonitor"

  # zap clears the local data store and preferences, which never leave the
  # machine.
  zap trash: [
    "~/Library/Application Support/MacPerfMonitor",
    "~/Library/Caches/uk.co.bzwrd.macperfmonitor",
    "~/Library/Preferences/uk.co.bzwrd.macperfmonitor.plist",
  ]
end
