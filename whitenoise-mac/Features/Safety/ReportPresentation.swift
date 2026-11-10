import Foundation
import MarmotKit

/// Copy for the report flows, shared by the message sheet, Block and Report, and their feedback.
nonisolated enum ReportPresentation {
    static let reasons: [ReportReasonFfi] = [
        .spam, .nudity, .malware, .profanity, .illegal, .impersonation, .other,
    ]

    static func title(_ reason: ReportReasonFfi) -> String {
        switch reason {
        case .spam: L10n.string("Spam")
        case .nudity: L10n.string("Nudity")
        case .malware: L10n.string("Malware")
        case .profanity: L10n.string("Profanity")
        case .illegal: L10n.string("Illegal content")
        case .impersonation: L10n.string("Impersonation")
        case .other: L10n.string("Other")
        }
    }

    /// The in-group report's status. A retained send is still on its way, never "sent".
    static func groupOutcome(_ disposition: SendAcceptDispositionFfi) -> String {
        switch disposition {
        case .published: L10n.string("Sent to the group.")
        case .acceptedPending: L10n.string("Saved and waiting to send.")
        case .completionUnknown: L10n.string("Saved; delivery confirmation is pending.")
        }
    }

    /// The White Noise copy's status. MDK queues a retained report and retries it on catch-up, so
    /// it reads as waiting and is never offered for resubmission.
    static func teamOutcome(_ disposition: SendAcceptDispositionFfi) -> String {
        switch disposition {
        case .published: L10n.string("Sent to the White Noise team.")
        case .acceptedPending: L10n.string("Saved and waiting to send to the White Noise team.")
        case .completionUnknown: L10n.string("Saved; delivery to the White Noise team is pending confirmation.")
        }
    }

    static func outcome(groupOutcome: String?, teamDisposition: SendAcceptDispositionFfi?) -> String? {
        let parts = [groupOutcome, teamDisposition.map(teamOutcome)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Keeps the group report's real status (it may only be queued) beside the failed White Noise
    /// copy, so the retry copy never claims more than happened.
    static func teamFailure(groupOutcome: String?, failure: String) -> String {
        guard let groupOutcome else { return failure }
        return groupOutcome + " " + L10n.string("The copy to White Noise couldn't be sent. Try again.")
    }

    static func errorMessage(for error: Error) -> String {
        UserFacingError.message(for: error)
    }
}
