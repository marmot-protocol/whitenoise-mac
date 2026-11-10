import Foundation
import Observation

/// "Automatically Load Stickers": off by default. A received sticker's image is fetched from the
/// server its pack's author chose, which tells that server the viewer's IP address and which
/// sticker they are looking at. Off, a sticker loads by itself only when the viewer sent it or
/// installed its pack (`StickerLoadPolicy`); on, every received sticker does.
///
/// Separate from `RemoteGIFLoadingPreference` because the party learning about the viewer is
/// different: GIPHY there, any pack author's server here.
@MainActor
@Observable
final class StickerLoadingPreference {
    static let shared = StickerLoadingPreference()
    static let storageKey = "whitenoise.mac.automaticallyLoadStickers"

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
