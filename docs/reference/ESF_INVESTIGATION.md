# Endpoint Security Framework (ESF) — Investigation

> **Status:** research only — no code changes. Goal: understand what Apple's
> Endpoint Security Framework can give Mac Performance Monitor (MPM), what it
> would cost to get access, and where it could plausibly help someone
> troubleshoot a macOS performance problem.
>
> **Sourcing:** the technical mechanics below are backed by primary Apple sources
> (the EndpointSecurity docs, WWDC 2020 #10159, the SDK headers) cross-checked by
> an adversarial multi-source verification pass. Two commonly-repeated claims were
> checked and **refuted** — see [Corrections](#corrections-myths-that-didnt-survive-verification).
> Where a point is an inference rather than a documented fact (notably the
> entitlement-approval odds), it is labelled as such.

---

## TL;DR / verdict

ESF is a **behavioural event stream, not a metrics API.** It tells you *what
happened* (a process executed, forked, exited; a file opened; a signal was sent)
with rich provenance — but it has **no event for CPU%, memory, energy, or disk
bytes.** It therefore can't replace or augment any of MPM's existing sampling.

Its **one genuinely valuable contribution** to a perf tool is **reliable,
real-time process-lifecycle notification** — `EXEC` / `FORK` / `EXIT` delivered
as discrete kernel messages, so even a process that lives <1 s is captured with
full launch metadata (path, argv, code-signing/Team ID, parent + responsible
PID, audit token). That is exactly the blind spot in MPM's 1–2 s polling sampler,
which cannot see short-lived processes at all.

The **catch is access**, and it is a hard one:

- ESF requires the restricted `com.apple.developer.endpoint-security.client`
  entitlement, which **you cannot self-assign** — it must be requested from and
  granted by Apple, then baked into an Apple-issued provisioning profile.
- Every Apple description frames the entitlement as *"monitoring system events
  for potentially malicious activity"* — i.e. for **security/EDR vendors.**
  Whether Apple would grant it to a general-purpose **performance** tool is the
  make-or-break question, and it is **unverified / uncertain → likely a hard
  sell** (see [Feasibility](#21-feasibility-the-make-or-break-question)).
- On top of the entitlement, a shipping client must **run as root**, hold **Full
  Disk Access (TCC)**, and — if packaged as the recommended System Extension —
  get **explicit user approval** in Privacy & Security.

**Bottom line:** the data is interesting and fills a real gap, but the entitlement
gate makes ESF a high-risk, high-friction dependency for an indie Developer-ID
app. The pragmatic path is to treat ESF as the *aspirational* implementation of a
"process-launch timeline" feature, **prototype the feature first on a
lower-friction signal** (see [Alternatives](#6-alternatives-getting-the-signal-without-esf)),
and only pursue the entitlement if the feature proves its worth and we're willing
to take on a security-extension posture.

---

## 1. How ESF works (implementation model)

ESF (`EndpointSecurity.framework`, since macOS 10.15 Catalina) is Apple's
**sanctioned user-space replacement** for the old in-kernel security hooks. WWDC
2020 #10159 states it supersedes the **Kauth KPI**, third-party **kernel
extensions (KEXTs)**, and the **OpenBSM audit trail**. (OpenBSM is now deprecated
since macOS 11, **disabled since macOS 14**, and slated for removal — relevant
because some "no-ESF" alternatives are built on it; see §6.)

### 1.1 The client + event model

- **Client lifecycle.** You create a client with **`es_new_client()`**, which
  connects to the ES subsystem and returns an `es_new_client_result_t`. Success
  is `ES_NEW_CLIENT_RESULT_SUCCESS`; the failure cases are individually named and
  map exactly to the three things that can be missing —
  `…_ERR_NOT_ENTITLED`, `…_ERR_NOT_PRIVILEGED` (not root),
  `…_ERR_NOT_PERMITTED` (no TCC/Full Disk Access) — plus `…_ERR_INVALID_ARGUMENT`
  and `…_ERR_INTERNAL`. You tear down with `es_delete_client()`.
- **Subscription.** After creating the client you call **`es_subscribe()`** with
  the specific `es_event_type_t` values you want. You receive only what you
  subscribe to.
- **Two action classes, and only two.** Every event is either:
  - **`NOTIFY`** — fires *after the fact*, asynchronously, no response required.
    This is what a perf tool wants.
  - **`AUTH`** — fires *before* the operation completes; **the kernel holds the
    operation** until the client responds allow/deny (`es_respond_auth_result`,
    or `es_respond_flags_result` for `AUTH_OPEN`) **or a per-message deadline
    expires.**
  Each event type is one or the other, signalled by its name
  (`ES_EVENT_TYPE_NOTIFY_*` vs `ES_EVENT_TYPE_AUTH_*`).

### 1.2 AUTH is synchronous and dangerous for a perf tool

AUTH events sit in the critical path of real system operations. Per WWDC 2020:
if the client misses the deadline, **the client process is terminated** (a System
Extension's launchd job is auto-restarted), and an implicit **ALLOW** is applied
*but not cached*. So a slow/struggling AUTH client degrades the whole machine —
the opposite of what a performance tool should do.

> **Design rule for MPM:** if we ever use ESF, subscribe **NOTIFY-only.** We have
> no reason to authorise/deny anything, and AUTH adds latency + a self-inflicted
> stability risk.

### 1.3 Packaging: System Extension vs root daemon

- **Apple's recommended model** is a **System Extension**: the ESF client is a
  sysext bundled inside a host app, installed/upgraded via the System Extensions
  framework. This is **distributable via Developer ID** (does *not* require the
  Mac App Store).
- **But a System Extension is not strictly required.** An Apple DTS engineer
  (Developer Forums thread 125508) confirms an ESF client **can run as a root
  `LaunchDaemon`** instead — Apple just recommends the sysext as "easier."

> **MPM relevance:** we *already ship a root-privileged XPC helper LaunchDaemon.*
> Architecturally, the root-daemon ESF path is the closer fit — we wouldn't have
> to introduce a System Extension at all. (Trade-off: the sysext path gets you
> Apple's managed install/approve/upgrade UX and inherits the app's Full Disk
> Access; the root-daemon path reuses machinery we already have but means we own
> more of the lifecycle. This interaction with Sparkle updates is an open
> question — see §8.)

---

## 2. What we'd need to get access (the hard part)

To go from "works on my SIP-disabled dev Mac" to "ships to users," **all** of the
following must hold simultaneously:

| Requirement | Detail | Failure mode if missing |
|---|---|---|
| **Entitlement** `com.apple.developer.endpoint-security.client` | **Cannot be self-assigned.** Request from Apple via the System Extensions & DriverKit request process; once granted, authorised through an **Apple-issued provisioning profile** (created on the developer portal, not in Xcode). | `es_new_client()` → `ERR_NOT_ENTITLED` |
| **Run as root** | The hosting process must be running as root. | `ERR_NOT_PRIVILEGED` |
| **TCC: Full Disk Access** | The user must grant Full Disk Access to the hosting process in Privacy & Security. | `ERR_NOT_PERMITTED` |
| **System Extension extras** (only if using the sysext model) | Host app needs `com.apple.developer.system-extension.install`, and the **user must approve** the extension in Privacy & Security. | Extension won't activate |
| **Notarization** | Standard for Developer-ID distribution (we already do this). | Gatekeeper rejects |

**Dev-only shortcut (not shippable):** during development you can self-grant the
entitlement and **disable SIP** so it's honoured without a real provisioning
profile. This is useful for prototyping but is **not a distribution path** — SIP
is enforced on end-user machines, so a real build *must* have the Apple-granted
entitlement.

### 2.1 Feasibility: the make-or-break question

This is where the investigation lands its biggest caveat.

- **What's documented (high confidence):** the entitlement exists, is restricted,
  is manually gated by Apple, and is framed *everywhere* as a **security**
  capability — Apple's own words: *"the entitlement required to monitor system
  events for potentially malicious activity."* The framework is literally named
  *Endpoint Security* and positioned for EDR/antivirus.
- **What's NOT documented (the risk):** there is **no primary source stating
  Apple's actual approval criteria or success rate for a non-security,
  general-purpose performance tool.** No verified example of a perf/observability
  app (as opposed to an EDR/security product) being granted it surfaced in the
  research.

> **Honest read:** approval for MPM as currently positioned is **uncertain and
> plausibly unlikely.** Apple gates this entitlement on a security justification;
> "I want to draw a nicer process-launch timeline" is not the use case the gate
> was built for. We should assume we'd need a credible security-adjacent framing
> (e.g. "surface suspicious process-spawn behaviour that also harms performance")
> and still budget for rejection. **This is the single biggest reason not to build
> MPM's roadmap around ESF.**

### 2.2 Distribution implications for our setup (Developer ID + Sparkle)

- Developer ID distribution is **compatible** with ESF — it does not require MAS.
- **Open concern:** how a **Sparkle** auto-update interacts with a packaged
  System Extension (does the OS re-prompt for extension approval and/or Full Disk
  Access on each extension version bump?) was not resolved by the research. If we
  went the **root-daemon** route instead, this largely reduces to our existing
  helper-update handshake (which we already solved — see the helper auto-recovery
  work), sidestepping sysext re-activation entirely. That's a point in favour of
  the root-daemon path for us specifically.

---

## 3. What data we'd get

### 3.1 The event catalog

`es_event_type_t` enumerates everything subscribable — on the order of **130–150+
cases** in the SDK headers (`ESTypes.h`), version-gated as macOS adds more.
Grouped by what matters here:

- **Process lifecycle (the useful part for us):**
  `NOTIFY_EXEC` (a process exec'd an image), `NOTIFY_FORK` (forked a child),
  `NOTIFY_EXIT` (terminated). Delivered as **discrete real-time messages**, so a
  sub-second process fires both EXEC and EXIT and is **not missed.**
- **File system:** `OPEN`, `CLOSE`, `CREATE`, `RENAME`, `UNLINK`, `CLONE`,
  `LINK`, `MMAP`, `MPROTECT`, `TRUNCATE`, `WRITE`, … (mostly *firehose* volume —
  see §4).
- **System / kernel:** `MOUNT` / `UNMOUNT`, `SIGNAL`, `KEXTLOAD` / `KEXTUNLOAD`,
  `IOKIT_OPEN`, `GET_TASK` (a process obtained another's task port), `PROC_CHECK`.
- **Security / higher-level (newer macOS):** `BTM_LAUNCH_ITEM_ADD`
  (Background Task Management — login/launch items), `TCC_MODIFY` (added
  **macOS 15.4**), `SUDO`, `OPENSSH_LOGIN`, `SCREENSHARING_ATTACH`,
  `XP_MALWARE_DETECTED`, authentication events, etc.

> **Versioning matters:** newer event types and even newer *fields* on existing
> events are gated by macOS version / message version. If we ever target a range
> of OSes we'd have to feature-detect. MPM is already on a recent minimum
> (macOS 15), which helps.

### 3.2 The rich metadata on a process launch

The reason `EXEC` is the crown jewel: the `es_event_exec_t` payload carries deep
provenance about *every* launch:

- **`target` → `es_process_t`:** the executable file + process metadata,
  **code-signing info and Team ID**, **parent PID and *responsible* PID**, and the
  **audit token**.
- **`cwd`** — working directory at exec time (message version ≥ 3).
- **`dyld_exec_path`** — the dynamic loader path (message version ≥ 7).
- **argv** and the **environment**.
- **`image_cputype` / `image_cpusubtype`** — CPU type/subtype, i.e. Rosetta /
  translated detection (message version ≥ 6).

> **Don't oversell the metadata for us:** MPM **already** detects Rosetta cheaply
> via `cmacperfmonitor_is_translated`, already reads parent PID, code path, etc.
> via libproc. The *new* thing ESF adds isn't most of these fields — it's that we
> get them **for processes we'd otherwise never see**, **at the instant they
> launch**, with **exact timestamps and an exit event to pair them with.**

### 3.3 What ESF does NOT give (decision-critical)

There is **no event type and no payload field** for:

- **CPU %, CPU time**
- **memory / footprint**
- **energy / power**
- **disk bytes read/written**
- **network throughput**
- any **resource-usage / metrics** telemetry at all.

ESF does **behavioural** monitoring, full stop. So it **cannot** feed any of
MPM's charts directly. Its role can only ever be **correlation and attribution**:
"a burst of *these launches* coincided with *that* CPU/memory spike you measured
the normal way."

---

## 4. Performance & overhead

Ironic but real: a *performance* tool using ESF must be careful not to *cause* a
performance problem.

- **Firehose / silent drops.** Independent research (WithSecure "ESFang")
  found that subscribing to many event types at once can cause ESF to **silently
  drop events** — they measured *less* data with many subscriptions than with a
  single type, with some events lost. The bottleneck is the client keeping up.
- **Drop detection exists.** `es_message_t` carries `seq_num` / `global_seq_num`
  precisely so a consumer can *detect* gaps. (Used by osquery's ES backend.)
- **Mitigations** (and they're mandatory for sane behaviour):
  - **Subscribe minimally** — for us, ideally just `EXEC` / `FORK` / `EXIT`,
    never the file firehose.
  - **NOTIFY-only** — never pay AUTH latency.
  - **Mute aggressively** — `es_mute_path()` / `es_mute_process()` and muting
    *inversion* (allow-list instead of deny-list) to scope what's delivered.
  - **Keep the handler fast** — offload work off the delivery queue.

> Even with all that, ESF is heavier than our current libproc sampling. The
> "negligible overhead for EXEC/FORK/EXIT-only" claim is **plausible but
> unverified** for our exact setup — it's listed as an open question (§8) and
> would need measurement on a signed build, the way we measure everything else
> (per our perf-measurement discipline).

---

## 5. Hypothetical usage scenarios (where this could actually help troubleshooting)

These are framed around MPM's real gap: **we sample every 1–2 s, so anything that
lives and dies between ticks is invisible to us today.** ESF's process-lifecycle
stream is the thing that closes that gap. Ideas, roughly best-to-most-speculative:

1. **"Short-lived process storm" detector — the flagship use.**
   A 1–2 s poll completely misses a script/build/cron job that spawns thousands
   of sub-second processes, yet that churn can dominate CPU and thrash the
   scheduler. With `EXEC`/`EXIT` we could surface *"~4,300 processes launched in
   the last minute, 92% lived <200 ms, 78% spawned by `make`"* — a class of
   problem MPM literally cannot see now. This is the most defensible reason to
   want ESF.

2. **Process-launch timeline / "what just happened?" view.**
   A precise, timestamped feed of every launch and exit, overlaid on the existing
   CPU/memory timelines. When a user sees a spike at 14:32:07, they could scrub to
   that instant and see *"`Spotlight`/`mdworker_shared` ×12 launched here"* —
   turning an anonymous spike into an attributable cause.

3. **Crash-loop / relaunch-storm detection.**
   A daemon that keeps crashing and being relaunched (launchd respawn loop) is a
   classic silent battery/CPU drain. Pairing `EXIT` (with exit status) and `EXEC`
   for the same executable path lets us spot *"`com.foo.helper` has relaunched
   38 times in 5 minutes"* — invisible to polling because each instance is
   short-lived.

4. **Parent → child attribution for runaway processes.**
   When MPM flags a runaway process today, we can show its parent PID — but the
   parent may already be gone. ESF's `responsible PID` + the captured spawn tree
   answers *"what actually spawned this?"* even after the ancestor exits, making
   "who do I blame / what do I quit?" answerable.

5. **Build-system / toolchain fan-out insight (developer audience).**
   MPM's users skew technical. An "exec tree for the last build" — compiler /
   linker / test-runner fan-out, counts and durations — is a genuinely novel
   developer-facing performance view that polling can't produce.

6. **Correlating non-process events with spikes (more speculative).**
   `MOUNT` (a disk image/network volume mounting), `KEXTLOAD`, `IOKIT_OPEN`, or
   `BTM_LAUNCH_ITEM_ADD` (a new login item) are all discrete events we could pin
   on the timeline next to a measured spike — e.g. *"disk I/O jumped right when a
   DMG mounted."*

7. **Login-item / persistence hygiene (adjacent to perf).**
   `BTM_LAUNCH_ITEM_ADD` could power a *"what's been added to launch at login"*
   view — startup bloat is a real perceived-performance issue. (This also happens
   to be the most "security-flavoured" framing, which is relevant if we ever
   write the entitlement justification.)

**Reality check on all of the above:** every one is an *attribution/correlation*
feature layered on top of metrics we already collect the normal way. None of them
need ESF's AUTH side, the file firehose, or most of the catalog — they need
`EXEC`/`FORK`/`EXIT` (plus maybe a handful of system events). That narrowness is
good news for overhead, but it also means **we're paying an enormous access cost
(a restricted security entitlement) for a very thin slice of ESF.** That economics
mismatch is the heart of the recommendation.

---

## 6. Alternatives: getting the signal without ESF

Since the *only* part of ESF we actually want is process-lifecycle events, it's
worth knowing the non-ESF ways to get them. (Confidence varies — the research
verified the ESF and OpenBSM/ProcInfo facts strongly; the kqueue/DTrace specifics
below lean on general platform knowledge and are flagged for validation in §8.)

| Approach | Catches short-lived procs? | Privilege | Verdict for MPM |
|---|---|---|---|
| **`proc_listallpids` polling (current)** | **No** — anything born+dead between ticks is missed | none | What we do now; the gap ESF would fill |
| **kqueue `EVFILT_PROC` (`NOTE_EXEC`/`EXIT`/`FORK`)** | Only for a **PID you already know** — you must register interest in a specific pid, so it can't catch *arbitrary new* processes you haven't seen yet | none | Good for *watching* a known process's children/exit; **not** a system-wide "any new process" feed |
| **`NSWorkspace` launch notifications** | Only **GUI apps** — not terminal/daemon/background processes | none | Too narrow (misses exactly the churn we care about) |
| **OpenBSM / audit pipe (e.g. Objective-See `ProcInfo`)** | Yes (when root) | root | **Dead end on modern macOS** — OpenBSM deprecated macOS 11, **disabled macOS 14**; Objective-See itself migrated to ESF |
| **DTrace / `execsnoop`** | Yes | root; **constrained by SIP** | Diagnostic/manual, not a shippable embedded data source |
| **ESF `EXEC`/`FORK`/`EXIT`** | **Yes**, reliably, with rich metadata | root + entitlement + FDA | The "right" answer technically; the access cost is the problem |

**Key takeaway:** there is **no free, fully-equivalent substitute** for ESF's
system-wide short-lived-process capture on current macOS. OpenBSM (the historical
user-mode route) is gone. kqueue helps only when you already know the PID. So the
honest options are: **(a)** accept the polling blind spot, **(b)** build a narrow
feature on kqueue for *watched* processes only, or **(c)** take on ESF with all
its access friction. The choice depends on how much we value the short-lived-storm
class of insight.

---

## 7. Recommendation

1. **Do not put ESF on the critical path of the roadmap.** The entitlement gate
   is a real possibility of "no," and Apple frames it for security products, not
   perf tools. Building features that *require* it risks a dead end.
2. **Validate demand and design on a cheaper signal first.** Prototype a
   "process-launch timeline / short-lived-process" feature using kqueue (for
   watched processes) and tighter polling where it helps, to learn whether the
   insight is compelling enough to justify the ESF cost. Most of the *UI/UX* work
   (timeline overlay, exec-tree, relaunch detection) is reusable regardless of the
   underlying data source.
3. **If the feature proves its worth, pursue ESF deliberately** — via the
   **root-daemon** path (reuses our existing privileged-helper architecture and
   sidesteps the Sparkle-vs-System-Extension unknowns), **NOTIFY-only**,
   subscribed to **`EXEC`/`FORK`/`EXIT`** plus a small set of system events, with
   aggressive muting. Write the entitlement request with the most security-adjacent
   honest framing we can (suspicious spawn behaviour, persistence/login-item
   hygiene) and budget for rejection.
4. **Keep ESF strictly opt-in and heavyweight-gated** if shipped, consistent with
   our "expensive attribution is opt-in" principle — it would be the most
   privileged, highest-friction capability in the app (root + FDA + a security
   entitlement + possibly a user-approved extension).

---

## 8. Open questions to resolve before committing

1. **Will Apple actually grant `…endpoint-security.client` to a non-security perf
   tool?** Unverified and make-or-break. *Action: find any precedent of a
   non-EDR/observability app being granted it; consider an informal DTS/TSI
   inquiry describing our exact use case before investing.*
2. **kqueue / polling / DTrace specifics** for short-lived capture on Apple
   Silicon were not independently verified here — confirm `EVFILT_PROC` really
   does require a known PID (no wildcard), and exactly what SIP blocks for DTrace.
3. **Sparkle + System Extension upgrade UX** — does a Sparkle update re-prompt the
   user for extension approval / Full Disk Access on each extension bump? (Avoided
   entirely by the root-daemon path — worth confirming that's true.)
4. **Real overhead** of a NOTIFY-only, `EXEC`/`FORK`/`EXIT`-only ESF root daemon
   vs our current polling — measure on a *signed release build* per our standard
   perf methodology before believing "negligible."

---

## 9. Corrections (myths that didn't survive verification)

Two plausible-sounding claims were specifically checked and **refuted** (0-3) — do
not repeat them:

- ❌ *"There's a configurable deadline-miss mode (`ES_DEADLINE_MISS_MODE_KILL`)
  with selectable fail-open/fail-closed behaviour."* The only verified behaviour
  on a missed AUTH deadline is **process termination + an implicit, uncached
  ALLOW.** It is not configurable.
- ❌ *"When an AUTH deadline is missed, the kernel starts dropping events for that
  client."* Not supported. Event drops are a **firehose/throughput** phenomenon
  (too many subscriptions / a slow consumer), not a deadline-miss penalty.

---

## Sources

Primary (Apple):
- Endpoint Security — https://developer.apple.com/documentation/endpointsecurity
- `es_event_type_t` — https://developer.apple.com/documentation/endpointsecurity/es_event_type_t
- `es_event_exec_t` — https://developer.apple.com/documentation/endpointsecurity/es_event_exec_t
- `com.apple.developer.endpoint-security.client` entitlement — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client
- WWDC 2020 #10159, *"Build an Endpoint Security app"* — https://developer.apple.com/videos/play/wwdc2020/10159/
- System Extensions — https://developer.apple.com/system-extensions/
- `audit.log(5)` man page (OpenBSM deprecation/removal) — https://www.manpagez.com/man/5/audit.log/

Engineering write-ups & corroboration:
- Objective-See, *Writing a Process Monitor with ESF* — https://objective-see.org/blog/blog_0x47.html
- Objective-See `ProcInfo` (OpenBSM-based, pre-ESF) — https://github.com/objective-see/ProcInfo
- Red Canary `mac-monitor` — Endpoint Security Overview — https://github.com/redcanaryco/mac-monitor/wiki/5.-Endpoint-Security-Overview
- Omar Ikram, minimal ESF client gist — https://gist.github.com/Omar-Ikram/8e6721d8e83a3da69b31d4c2612a68ba
- WithSecure Labs, *ESFang* (firehose/drop research) — https://labs.withsecure.com/publications/esfang-exploring-the-macos-endpoint-security-framework-for-threat-detection
- Trail of Bits, *osquery 5 with EndpointSecurity* — https://blog.trailofbits.com/2021/11/10/announcing-osquery-5-now-with-endpointsecurity-on-macos/

*Investigation compiled 2026-06-30 from a verified multi-source research pass
(18 sources fetched, 84 claims extracted, 25 adversarially verified, 2 refuted).*
