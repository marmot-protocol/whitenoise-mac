import Foundation
import Observation

/// The Settings switch for dictation in the composer, on unless the person turned it off.
@MainActor
@Observable
final class DictationPreference {
    static let shared = DictationPreference()
    static let storageKey = "whitenoise.mac.composer.dictation"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var isEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Self.storageKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.storageKey)
    }

    /// Back to the new-install default, for Erase App Data.
    func reset() {
        isEnabled = true
        defaults.removeObject(forKey: Self.storageKey)
    }
}
