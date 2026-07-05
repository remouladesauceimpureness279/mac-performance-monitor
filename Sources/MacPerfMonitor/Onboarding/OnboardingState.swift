import Combine
import Foundation

/// Tracks whether the user has seen the first-run education flow (PRD 8.9).
/// Persisted in `UserDefaults` so it shows once, but it can be replayed at any
/// time from the menu ("How MacPerfMonitor works…").
final class OnboardingState: ObservableObject {
    @Published var hasCompleted: Bool {
        didSet { defaults.set(hasCompleted, forKey: key) }
    }
    /// Whether the user has been through the first-run setup wizard (the
    /// interactive config steps that follow the education screens). Tracked
    /// separately from `hasCompleted` so users who already saw the older
    /// education-only onboarding still get the config steps once after updating.
    @Published var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: setupKey) }
    }
    /// Transient (not persisted): when the wizard is auto-shown to someone who has
    /// already seen the education screens, show only the config steps and skip
    /// re-teaching. Reset when the window closes or the flow finishes.
    @Published var autoConfigOnly = false

    private let key = "hasCompletedOnboarding"
    private let setupKey = "hasCompletedSetup"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompleted = defaults.bool(forKey: key)
        hasCompletedSetup = defaults.bool(forKey: setupKey)
    }

    /// Mark the whole flow as seen (called when the user finishes or skips it):
    /// both the education screens and the setup wizard.
    func complete() {
        hasCompleted = true
        hasCompletedSetup = true
    }

    /// Show the education flow again from the start (from the menu).
    func replay() {
        hasCompleted = false
    }
}
