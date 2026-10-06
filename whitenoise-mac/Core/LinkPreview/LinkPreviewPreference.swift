import Foundation
import Observation

/// "Show Link Previews" — off by default, like every other switch that makes the app fetch
/// something a peer chose: loading a preview tells the linked website the viewer's IP address and
/// that they are reading the chat right now. Until the viewer opts in, a link is just a link.
@MainActor
@Observable
final class LinkPreviewPreference {
    static let shared = LinkPreviewPreference()
    static let storageKey = "whitenoise.mac.showLinkPreviews"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var showsPreviews: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showsPreviews = defaults.bool(forKey: Self.storageKey)
    }

    func setShowsPreviews(_ enabled: Bool) {
        showsPreviews = enabled
        defaults.set(enabled, forKey: Self.storageKey)
    }

    /// Back to the new-install default, for Erase App Data.
    func reset() {
        showsPreviews = false
        defaults.removeObject(forKey: Self.storageKey)
    }
}
