import Foundation
import Observation

/// "Automatically Load Remote GIFs" — off by default, for the same reason remote profile images
/// are: a received GIF is fetched from GIPHY's CDN, which tells GIPHY the viewer's IP address and
/// which GIF they are looking at. Until the viewer opts in, a received GIF waits for a click. Your
/// own sends always load, since you already asked GIPHY for that GIF when you picked it.
@MainActor
@Observable
final class RemoteGIFLoadingPreference {
    static let shared = RemoteGIFLoadingPreference()
    static let storageKey = "whitenoise.mac.automaticallyLoadRemoteGIFs"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var automaticallyLoads: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.automaticallyLoads = defaults.bool(forKey: Self.storageKey)
    }

    func setAutomaticallyLoads(_ enabled: Bool) {
        automaticallyLoads = enabled
        defaults.set(enabled, forKey: Self.storageKey)
    }

    /// Back to the new-install default, for Erase App Data.
    func reset() {
        automaticallyLoads = false
        defaults.removeObject(forKey: Self.storageKey)
    }
}
