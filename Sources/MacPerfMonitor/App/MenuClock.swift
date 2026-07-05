import Combine
import Foundation

/// A 1 Hz refresh signal that ticks ONLY while a menu-bar popover is open.
///
/// The menu-bar dropdowns show live read-outs (CPU %, network rates, memory) that
/// should update every second while visible — but they must do no work when
/// closed, or a hidden popover would re-render 1 Hz forever and raise the app's
/// idle CPU (exactly the cost we work to avoid). `TimelineView(.periodic)` does
/// not pause for an `NSPopover`/`MenuBarExtra` that is merely closed, so instead
/// each popover refcounts itself open/closed and only then is the underlying
/// heartbeat (`SamplerModel.liveTick`) forwarded as `objectWillChange`.
///
/// A content view that observes this object re-renders once per heartbeat while
/// its popover is open, and not at all while closed.
///
/// While open it also (a) fires `onOpen` once so the just-shown panel refreshes
/// immediately instead of waiting up to a full tick, and (b) holds a `userInitiated`
/// activity so App Nap can't throttle the 1 Hz sampler timer out to a multi-second
/// cadence while the menubar-only app is otherwise idle — which made the first
/// update after opening lag by several seconds.
///
/// All access is on the main thread (popover delegate callbacks, SwiftUI
/// `onAppear`/`onDisappear`, and the sink, which receives on the main run loop),
/// so the type needs no actor annotation.
final class MenuClock: ObservableObject {
    /// Bumped once per source tick while open; observers re-render on the change.
    @Published private(set) var tick: UInt64 = 0

    private let source: AnyPublisher<Void, Never>
    /// Called when the first popover opens — kicks an immediate refresh so the
    /// panel shows fresh data at once (e.g. `model.requestImmediateTick()`).
    private let onOpen: () -> Void
    /// Called with `true` when the first popover opens and `false` when the last
    /// closes, so a panel that shows top processes can register/unregister itself
    /// as a per-process consumer (gating the heavy scan to when it is visible).
    private let onActiveChange: (Bool) -> Void
    /// Whether a popover is currently open. A plain flag, NOT a refcount: each
    /// clock serves exactly one popover, and an integer count silently leaks the
    /// "open" state — and with it the 1 Hz per-process scan and `menuTop*`
    /// republish — if SwiftUI fires a duplicate `onAppear` or drops an
    /// `onDisappear` (both are documented quirks for `NSPopover`-hosted content).
    /// A leaked consumer re-renders the whole main window at 1 Hz long after the
    /// dropdown has closed, regardless of the global refresh interval.
    private var isOpen = false
    private var cancellable: AnyCancellable?
    /// Held while any popover is open to keep App Nap from throttling sampling.
    private var activity: NSObjectProtocol?

    /// - Parameters:
    ///   - source: the 1 Hz heartbeat (e.g. `model.liveTick`).
    ///   - onOpen: fired once when the first popover opens, for an immediate refresh.
    init(
        source: AnyPublisher<Void, Never>, onOpen: @escaping () -> Void = {},
        onActiveChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.source = source
        self.onOpen = onOpen
        self.onActiveChange = onActiveChange
    }

    /// Mark a popover shown. Idempotent: a duplicate `onAppear` is ignored, so a
    /// second open cannot leave the consumer registered after a single close.
    /// Starts forwarding the heartbeat, holds off App Nap, and kicks one
    /// immediate refresh.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        // Keep App Nap from coalescing the sampler's 1 Hz timer while the popover
        // is visible — otherwise the menubar-only app naps and the live read-outs
        // update only every few seconds. `userInitiatedAllowingIdleSystemSleep`
        // disables App Nap without keeping the Mac awake. Released on the last close.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Menu-bar popover live read-out")
        }
        // Deliver on the GCD main queue, NOT `RunLoop.main`: while a menu-bar
        // popover is open the main run loop sits in a tracking mode, and a
        // `RunLoop.main` (default-mode) subscriber's blocks are deferred until the
        // popover closes — so the dropdown's live read-outs froze while open even
        // though the icon (and the underlying data) kept ticking. The GCD main
        // queue drains in every run-loop mode, so the panel re-renders at 1 Hz
        // while visible.
        cancellable =
            source
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.tick &+= 1 }
        // Register the per-process demand BEFORE the immediate refresh below, so the
        // tick `onOpen` kicks already sees a consumer and runs the heavy scan.
        onActiveChange(true)
        // Refresh now so the freshly opened panel shows current read-outs at once,
        // rather than the up-to-several-seconds-old sample left by a napped timer.
        onOpen()
    }

    /// Mark a popover hidden. Idempotent and safe to call from any close path
    /// (`onDisappear`, the popover-closed delegate, an explicit dismiss): the
    /// heartbeat is dropped (nothing re-renders while closed), the per-process
    /// consumer is released, and App Nap is allowed again.
    func close() {
        guard isOpen else { return }
        isOpen = false
        cancellable = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        onActiveChange(false)
    }
}
