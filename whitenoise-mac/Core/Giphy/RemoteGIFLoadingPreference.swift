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
    /// GIFs the viewer clicked to load, remembered for the session. A transcript cell recycled for
    /// the same message starts with fresh view state, so a per-view flag put the "Load GIF" button
    /// back on a GIF the viewer had already opened. Never persisted: a click consents to one load
    /// of one GIF, not to GIPHY learning about it on every later launch.
    private var requestedURLs: Set<URL> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.automaticallyLoads = defaults.bool(forKey: Self.storageKey)
    }

    func setAutomaticallyLoads(_ enabled: Bool) {
        automaticallyLoads = enabled
        defaults.set(enabled, forKey: Self.storageKey)
    }

    func recordLoadRequest(for url: URL) {
        requestedURLs.insert(url)
    }

    func wasLoadRequested(for url: URL) -> Bool {
        requestedURLs.contains(url)
    }

    /// Back to the new-install default, for Erase App Data.
    func reset() {
        automaticallyLoads = false
        requestedURLs = []
        defaults.removeObject(forKey: Self.storageKey)
    }
}
