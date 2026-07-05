#!/usr/bin/env bash
#
# build.sh — compile the MacPerfMonitor binary with Swift Package Manager.
#
# This is an Apple Silicon (arm64) only project: we build for the host arch and
# never produce a universal or x86_64 binary.
#
# Release by default. Flags:
#   --debug      faster, unoptimised build
#   --release    optimised build (default)
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
for arg in "$@"; do
  case "$arg" in
    --debug)     CONFIG="debug" ;;
    --release)   CONFIG="release" ;;
    --universal)
      echo "build.sh: --universal is not supported; this is an Apple Silicon (arm64) only project." >&2
      exit 2 ;;
    *) echo "build.sh: ignoring unknown argument '$arg'" >&2 ;;
  esac
done

echo "Building MacPerfMonitor ($CONFIG, arm64)..."
swift build -c "$CONFIG" --product MacPerfMonitor
# The privileged helper is a separate executable product (the app does not
# depend on it), so it must be built explicitly to be bundled alongside the app.
swift build -c "$CONFIG" --product MacPerfMonitorHelper

BIN="$(swift build --show-bin-path -c "$CONFIG")/MacPerfMonitor"
echo "Built: $BIN"
