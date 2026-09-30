import Foundation

/// The GIPHY API key this build was configured with, if any. GIF search is only offered when one is
/// present; receiving and rendering a GIF sent from another client needs no key unless the sender
/// used the legacy MP4 envelope, which is resolved to its GIF rendition through the lookup API.
///
/// The key is a build setting (`GIPHY_API_KEY_WN_MAC`, see `Config/AppSecrets.xcconfig.example`)
/// surfaced through `Config/Info.plist`, the same way the telemetry tokens are.
nonisolated struct GiphyBuildConfig: Equatable, Sendable {
    static let infoDictionaryKey = "WhiteNoiseGiphyAPIKey"

    let apiKey: String?

    static func current(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> GiphyBuildConfig {
        let raw = infoDictionary[infoDictionaryKey] as? String
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset build setting reaches the plist as `$(NAME)` rather than as nothing.
        guard let key, !key.isEmpty, !(key.hasPrefix("$(") && key.hasSuffix(")")) else {
            return GiphyBuildConfig(apiKey: nil)
        }
        return GiphyBuildConfig(apiKey: key)
    }

    var isAvailable: Bool { apiKey != nil }
}
