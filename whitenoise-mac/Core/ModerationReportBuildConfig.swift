import Foundation
import MarmotKit

/// IPF's private moderation-report destination for this build, ported from whitenoise-ios.
///
/// "Report" and "Block and Report" also reach the White Noise team through MDK's
/// `submitModerationReport`: a NIP-56 report, NIP-59 gift-wrapped to this key and published only
/// to the White Noise seed relays, which IPF operates. The key is a build setting
/// (`WN_MODERATION_REPORT_PUBKEY`, see `Config/AppBuild.xcconfig`) surfaced through
/// `Config/Info.plist`; Debug builds use the staging key so test reports never reach the
/// production queue.
///
/// A missing key leaves reporting unconfigured, which hides every report-to-White-Noise
/// affordance rather than failing. MDK validates the key itself (hex or `npub`) when it is
/// installed, so a malformed one is rejected there and reporting stays unconfigured.
nonisolated struct ModerationReportBuildConfig: Equatable, Sendable {
    static let infoDictionaryKey = "WhiteNoiseModerationReportPubkey"

    let recipientPubkey: String
    let relays: [String]

    static func current(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        relays: [String] = MarmotClient.seedRelays
    ) -> ModerationReportBuildConfig? {
        let raw = (infoDictionary[infoDictionaryKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset build setting reaches the plist as `$(NAME)` rather than as nothing.
        guard let raw, !raw.isEmpty, !(raw.hasPrefix("$(") && raw.hasSuffix(")")) else { return nil }
        return ModerationReportBuildConfig(recipientPubkey: raw, relays: relays)
    }

    var ffi: ModerationReportConfigFfi {
        ModerationReportConfigFfi(recipientPubkey: recipientPubkey, relays: relays)
    }
}
