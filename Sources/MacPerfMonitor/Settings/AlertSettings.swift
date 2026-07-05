import Combine
import Foundation
import MacPerfMonitorCore

/// The user's alert preferences, persisted across launches in `UserDefaults`
/// (PRD section 8.8). Published so the Settings UI binds directly and the
/// sampler reads the latest `config` each tick.
final class AlertSettings: ObservableObject {
    @Published var config: AlertConfig {
        didSet { save() }
    }

    private let key = "alertConfig"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(AlertConfig.self, from: data)
        {
            config = decoded
        } else {
            config = .default
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}
