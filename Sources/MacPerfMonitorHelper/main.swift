import Foundation
import MacPerfMonitorIPC
import os.log

// MacPerfMonitorHelper — the privileged root LaunchDaemon.
//
// Launched on demand by launchd (registered via SMAppService from the app) and
// running as root, it answers a single, read-only XPC interface: given a set of
// PIDs, return the privilege-gated process reads (task info, footprint, file
// descriptors) the unprivileged app cannot obtain for system and other-user
// processes. It never mutates system state.
//
// Every connection is pinned to the genuine app's code signature
// (HelperConstants.peerRequirement) before any request is served — the app must
// share this helper's own Apple Developer team, anchored to Apple.

let log = Logger(subsystem: "uk.co.bzwrd.macperfmonitor", category: "helper-main")

// Capture the BUILD (`CFBundleVersion`, bumped on every release — not the
// marketing version, which can stay the same across builds) this binary was
// launched from, ONCE, at startup. After an app update swaps the bundle on disk,
// this still-running (old) process keeps reporting the value it read here — which
// is how the app detects, via `ping`, that it is talking to a stale helper and
// needs to restart it so launchd demand-launches the new binary. Reading it
// per-call instead would pick up the swapped-in plist and the staleness would be
// invisible. Bundle.main is the enclosing .app bundle.
let launchBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
log.notice(
    "MacPerfMonitorHelper starting (uid \(getuid(), privacy: .public), build \(launchBuild, privacy: .public))"
)

let clientRequirement = HelperConstants.peerRequirement(
    forIdentifier: HelperConstants.appBundleIdentifier)
if clientRequirement == nil {
    log.warning(
        "client code-signing pin DISABLED: this build has no team identifier (ad-hoc/unsigned). Local development only."
    )
}
let delegate = HelperListenerDelegate(clientRequirement: clientRequirement, version: launchBuild)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

// Run forever, serving connections. launchd manages the lifetime; the daemon is
// idle-exited when no client is connected.
dispatchMain()
