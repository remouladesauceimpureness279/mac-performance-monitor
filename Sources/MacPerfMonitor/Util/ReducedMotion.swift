import AppKit
import SwiftUI

extension View {
    /// Honour the system "Reduce Motion" accessibility setting by stripping
    /// animations from this view's updates. Applied to charts so their marks do
    /// not animate when the user has asked for reduced motion (PRD accessibility
    /// requirement), while leaving normal animation in place for everyone else.
    func reducedMotionAware() -> some View {
        modifier(ReducedMotionModifier())
    }
}

/// Whether the user has asked the system to reduce motion. Read from AppKit,
/// which exposes it directly and reliably.
enum Motion {
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

private struct ReducedMotionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.transaction { transaction in
            if Motion.reduced { transaction.animation = nil }
        }
    }
}
