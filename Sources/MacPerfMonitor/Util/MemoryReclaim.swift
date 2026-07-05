import Darwin
import Foundation

/// Best-effort memory reclamation, invoked when the main window closes. Opening
/// the window builds a lot of one-shot AppKit/SwiftUI/Charts machinery; once it
/// is gone the freed heap pages are not automatically returned to the OS, which
/// keeps the *physical footprint* high even though the live set is small. This
/// asks the allocator to hand those pages back so the menubar-only idle state
/// stays close to its launch footprint (the PRD performance budget).
@MainActor
enum MemoryReclaim {
    static func runAfterWindowClose() {
        ProcessIconProvider.shared.purge()
        AppLog.ui.notice("window closed; scheduling memory reclaim")
        // Let SwiftUI/AppKit finish tearing down the (now unmounted) view graph,
        // then ask every malloc zone to return the freed pages to the kernel.
        // `goal == 0` means "release as much as possible" — the same call the
        // system makes when responding to memory pressure.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            malloc_zone_pressure_relief(nil, 0)
            AppLog.ui.notice("reclaimed memory after window close")
        }
    }
}
