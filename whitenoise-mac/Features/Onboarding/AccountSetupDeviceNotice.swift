import Foundation
import MarmotKit

/// Copy for the "Chats on this device" step, written for people who already use White Noise or
/// another Marmot app elsewhere. iOS's `AccountSetupDeviceNoticePresentation`, with the same keys.
///
/// The copy never says this device is added, linked or synced to the account: White Noise has no
/// multi-device support, so each sign-in is a separate installation with its own chats.
nonisolated struct AccountSetupDeviceNotice: Equatable {
    enum Evidence: Equatable {
        case noneFound, unknown
        /// MDK found messaging keys published by another installation of this account.
        case otherApps(latestPublication: Date?)
    }

    /// `nil` until MDK has checked for other installations (or while the check's failure hides
    /// its result).
    let evidence: Evidence?

    init(_ notice: OnboardingSingleDeviceNoticeFfi?, now: Date = .now) {
        switch notice?.discovery {
        case nil: evidence = nil
        case .noneFound: evidence = .noneFound
        case .unknown: evidence = .unknown
        case .otherInstallationPossible:
            // Relays supply these dates: skip a missing (0) one and a future one, which MDK flags
            // separately.
            let latest = notice?.otherPackages
                .map(\.publishedAt)
                .filter { $0 > 0 && TimeInterval(Int64(clamping: $0)) <= now.timeIntervalSince1970 }
                .max()
            evidence = .otherApps(
                latestPublication: latest.map { Date(timeIntervalSince1970: TimeInterval(Int64(clamping: $0))) }
            )
        }
    }

    /// The step's consent button: plain Continue only when nothing else was found.
    var actionKey: String {
        evidence == .noneFound ? "Continue" : "Continue anyway"
    }

    /// The catalog key of what the check found, or `nil` until MDK has checked. "Didn't find" is
    /// deliberate: finding nothing does not prove there is no other installation.
    var findingKey: String? {
        switch evidence {
        case nil: nil
        case .noneFound: "We didn’t find messaging keys from another app or device."
        case .unknown: "We couldn’t check whether this account uses another app or device for messaging."
        case .otherApps(.some):
            "We found messaging keys this account published from another app or device, most recently on %@."
        case .otherApps(nil): "We found messaging keys this account published from another app or device."
        }
    }

    /// What the check found, in `locale`, with the latest publication date filled in.
    func finding(locale: Locale) -> String? {
        guard let findingKey else { return nil }
        let format = L10n.string(findingKey, locale: locale)
        guard case .otherApps(let latest?) = evidence else { return format }
        let date = latest.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale))
        return String(format: format, locale: locale, date)
    }

    /// Catalog keys for what a separate installation means, one paragraph each. Nothing when no
    /// other app was found; a single conditional line when the check could not tell.
    var explanationKeys: [String] {
        switch evidence {
        case .noneFound: []
        case .otherApps:
            [
                "This device will have its own separate chats. Chats in the other app stay there and won’t appear here.",
                "When someone starts a new chat with you, it may arrive in either app.",
            ]
        // A failed or pending check makes no claim about other apps either way.
        case .unknown, nil: [Self.uncheckedExplanationKey]
        }
    }

    /// What a separate installation means when nobody knows yet whether there is another app.
    /// Also the step's description in `AccountSetupGuide`.
    static let uncheckedExplanationKey =
        "If you use another app for messaging, this device will have its own separate chats, and chats in that app won’t appear here."
}
