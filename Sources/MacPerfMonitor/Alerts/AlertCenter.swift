import Foundation
import MacPerfMonitorCore
import UserNotifications

/// Encodes and decodes the process identity carried in a notification's
/// `userInfo`, so clicking a per-process alert can reveal that exact process.
enum AlertUserInfo {
    private static let pidKey = "uk.co.bzwrd.macperfmonitor.alert.pid"
    private static let startKey = "uk.co.bzwrd.macperfmonitor.alert.start"

    /// The userInfo payload for an alert, identifying its process when it has
    /// one. System-wide alerts (pressure, swap) carry no identity.
    static func payload(for identity: ProcessIdentity?) -> [String: Any] {
        guard let identity else { return [:] }
        return [
            pidKey: Int(identity.pid),
            startKey: identity.startTime.timeIntervalSince1970,
        ]
    }

    /// The process identity in a notification payload, if it carried one.
    static func identity(from userInfo: [AnyHashable: Any]) -> ProcessIdentity? {
        guard let pid = userInfo[pidKey] as? Int,
            let start = userInfo[startKey] as? Double
        else { return nil }
        return ProcessIdentity(pid: Int32(pid), startTime: Date(timeIntervalSince1970: start))
    }
}

/// Delivers `Alert`s as user notifications (PRD section 8.7). Every fired alert
/// is also logged at `.notice` so a forced-pressure test can prove, from the
/// unified log alone, that the alert path fired — independent of whether the
/// system chose to present the banner.
///
/// Guards against running unbundled (`swift run`), where `UNUserNotificationCenter`
/// has no bundle to attach to: in that case it logs but does not attempt to
/// schedule, so the core app still runs.
final class AlertCenter {
    private let isBundled = Bundle.main.bundleURL.pathExtension == "app"
    private lazy var center: UNUserNotificationCenter? = isBundled ? .current() : nil

    /// Route notification interactions (clicks, foreground presentation) to the
    /// given delegate. No-op when unbundled, where there is no notification
    /// center to attach to. Set this once at launch, before authorization.
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        center?.delegate = delegate
    }

    /// Ask the user for permission to post notifications. Safe to call once at
    /// launch; the system only prompts the first time.
    func requestAuthorization() {
        guard let center else {
            AppLog.alerts.notice(
                "notifications unavailable (running unbundled); alerts will log only")
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.alerts.error(
                    "notification authorization error: \(String(describing: error), privacy: .public)"
                )
            } else {
                AppLog.alerts.notice(
                    "notification authorization granted=\(granted, privacy: .public)")
            }
        }
    }

    func deliver(_ alerts: [Alert]) {
        for alert in alerts { deliver(alert) }
    }

    func deliver(_ alert: Alert) {
        // Forensic evidence line for the forced-pressure test.
        AppLog.alerts.notice(
            "alert fired: \(alert.kind.rawValue, privacy: .public) — \(alert.title, privacy: .public)"
        )
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        // Carry the process identity (when the alert has one) so a click can
        // reveal that exact process in the detail inspector.
        content.userInfo = AlertUserInfo.payload(for: alert.identity)
        // Stable identifier per logical alert: re-delivering the same condition
        // replaces the existing notification rather than stacking duplicates.
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                AppLog.alerts.error(
                    "notification delivery failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
