import AppKit
import Combine

/// Shows or hides the app's Dock icon, driven by the "Show icon in the Dock"
/// Settings toggle.
///
/// The app is menubar-first (`LSUIElement`), so it launches as an accessory with
/// no Dock icon. Some users keep a very crowded menu bar — on notched Macs the
/// overflow can hide items entirely — and can't find our menu bar read-outs at
/// all. For them an opt-in Dock icon gives a second, always-visible way to open
/// the app. It's off by default so the unobtrusive menubar-only behaviour stays
/// the norm.
///
/// Toggling applies live, with no relaunch, by switching the process activation
/// policy: `.regular` adds the Dock icon (and the standard app menu while the app
/// is active), `.accessory` is the menubar-only default. Clicking the Dock icon
/// when no window is open is handled by `applicationShouldHandleReopen`, which
/// surfaces the main window — the same path the menubar label uses.
@MainActor
final class DockIconController: NSObject {
    /// UserDefaults key shared with the Settings toggle (`@AppStorage`). Reads as
    /// `false` when unset, so the Dock icon is off until the user opts in.
    static let defaultsKey = "showDockIcon"

    private var cancellables = Set<AnyCancellable>()

    /// Apply the stored preference now, then re-apply whenever defaults change so
    /// the Settings toggle takes effect immediately.
    func start() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)
        apply()
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    private func apply() {
        // `UserDefaults.didChangeNotification` fires for every defaults change
        // (other toggles, the db size cap, …), so only touch the policy when it
        // actually differs — re-setting the same policy would needlessly thrash
        // the Dock.
        let desired: NSApplication.ActivationPolicy = isEnabled ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
    }
}
