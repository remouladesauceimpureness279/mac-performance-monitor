#!/usr/bin/env bash
#
# diagnose-power.sh — gather battery/power diagnostics on a Mac so we can fix
# desktop (no-battery) detection in Mac Performance Monitor.
#
# Run it on the affected Mac (e.g. the Mac mini):
#     bash diagnose-power.sh
#
# It prints everything AND saves a copy to the Desktop; just send me the file.
#
set -u

OUT="$HOME/Desktop/macperfmon-power-diagnostics.txt"
# Mirror all output to the file as well as the screen.
exec > >(tee "$OUT") 2>&1

echo "============================================================"
echo " Mac Performance Monitor — power/battery diagnostics"
echo " $(date)"
echo "============================================================"

echo
echo "### Hardware model"
sysctl -n hw.model 2>/dev/null || true
system_profiler SPHardwareDataType 2>/dev/null \
  | grep -iE "Model Name|Model Identifier|Chip|Processor" | sed 's/^[[:space:]]*//' || true

echo
echo "### Installed app build (want 26 or newer)"
defaults read "/Applications/Mac Performance Monitor.app/Contents/Info.plist" CFBundleVersion 2>/dev/null \
  || echo "(app not found in /Applications)"

echo
echo "### AppleSmartBattery IORegistry entry  (should be EMPTY on a desktop)"
asb="$(ioreg -rc AppleSmartBattery 2>/dev/null)"
if [ -n "$asb" ]; then echo "PRESENT:"; echo "$asb" | head -80; else echo "(none — good)"; fi

echo
echo "### AppleSmartBatteryManager IORegistry entry"
asbm="$(ioreg -rc AppleSmartBatteryManager 2>/dev/null)"
if [ -n "$asbm" ]; then echo "PRESENT:"; echo "$asbm" | head -30; else echo "(none)"; fi

echo
echo "### pmset -g ps   (power sources, as macOS reports them)"
pmset -g ps 2>/dev/null || true
echo
echo "### pmset -g batt"
pmset -g batt 2>/dev/null || true

echo
echo "### system_profiler SPPowerDataType"
system_profiler SPPowerDataType 2>/dev/null || true

echo
echo "### Exact IOKit view the app uses (the decisive check)"
if command -v swift >/dev/null 2>&1; then
  TMP="$(mktemp -t mpmpower)" && mv "$TMP" "$TMP.swift" && TMP="$TMP.swift"
  cat > "$TMP" <<'SWIFT'
import Foundation
import IOKit
import IOKit.ps

let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
print("AppleSmartBattery service -> \(svc != 0 ? "MATCH (non-zero) — app treats this as 'has battery'" : "no match (0)")")
if svc != 0 { IOObjectRelease(svc) }

guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
else {
    print("IOPSCopyPowerSourcesList -> nil / none")
    exit(0)
}
print("IOPSCopyPowerSourcesList -> \(sources.count) source(s)")
for (i, s) in sources.enumerated() {
    guard let d = IOPSGetPowerSourceDescription(blob, s)?.takeUnretainedValue() as? [String: Any]
    else { continue }
    let type = d[kIOPSTypeKey] as? String ?? "(no Type key)"
    let present = d[kIOPSIsPresentKey] as? Bool
    let name = d[kIOPSNameKey] as? String ?? "?"
    print("  [\(i)] Type=\(type)  IsPresent=\(String(describing: present))  Name=\(name)")
    print("       all keys: \(d.keys.sorted().joined(separator: ", "))")
}
print("(for reference, the internal-battery type string is \"\(kIOPSInternalBatteryType)\")")
SWIFT
  swift "$TMP" 2>&1 || echo "(swift run failed)"
  rm -f "$TMP"
else
  echo "(swift toolchain not installed — skipping; the ioreg/pmset output above is enough)"
fi

echo
echo "============================================================"
echo "Saved to: $OUT"
echo "Send me the contents of that file."
echo "============================================================"
