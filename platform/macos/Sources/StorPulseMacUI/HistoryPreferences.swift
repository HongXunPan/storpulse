import Foundation

public protocol HistoryPreferences: Sendable {
    func load() async -> HistorySettings
    func save(_ settings: HistorySettings) async
}

public actor UserDefaultsHistoryPreferences: HistoryPreferences {
    private let defaults: UserDefaults
    private let key = "history-settings-v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() async -> HistorySettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(HistorySettings.self, from: data)
        else {
            return HistorySettings()
        }
        return settings
    }

    public func save(_ settings: HistorySettings) async {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
