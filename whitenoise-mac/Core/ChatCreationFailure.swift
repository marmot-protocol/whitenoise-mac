//
//  ChatCreationFailure.swift
//  whitenoise-mac
//
//  Why a chat or group could not be created, and the invite copy the
//  compose flow offers instead of an error when the answer is "they
//  aren't on White Noise yet".
//

import Foundation
import MarmotKit

/// Failure taxonomy for the chat/group creation paths. The one distinction that matters to
/// the person composing is "someone here has no usable messaging setup" — not an error they
/// can retry away, but an invitation they have to send — versus everything else.
///
/// `MarmotKitError.errorDescription` is `String(reflecting:)`, so a raw core error reaching
/// `lastError` prints `MarmotKit.MarmotKitError.MissingKeyPackage(account: "…")` at the user.
/// Every creation path maps through here instead.
nonisolated enum ChatCreationFailure: Equatable {
    /// A recipient has no usable published KeyPackage. `account` is the single member the core
    /// named: `create_group` resolves members in order and stops at the first unreachable one, so
    /// a roster with several needs one attempt per refusal to enumerate (see
    /// `WorkspaceState.createGroupResolvingEveryRefusal`, which spends them all in one press).
    /// `nil` when the core reported the condition without naming anyone.
    case notOnWhiteNoise(account: String?)
    case other(message: String)

    init(_ error: Error) {
        guard let marmotError = error as? MarmotKitError else {
            self = .other(message: error.localizedDescription)
            return
        }
        switch marmotError {
        case .MissingKeyPackage(let account):
            let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .notOnWhiteNoise(account: trimmed.isEmpty ? nil : trimmed)
        // A KeyPackage event that exists but cannot be used, and an identity rejected *after*
        // the recipient already resolved through the new-chat lookup, mean the same thing on
        // this path: not reachable on White Noise yet. Neither names an account.
        case .InvalidKeyPackageEvent, .InvalidIdentity:
            self = .notOnWhiteNoise(account: nil)
        default:
            self = .other(message: marmotError.localizedDescription)
        }
    }

    /// The recipient the core refused, when the caller has them.
    ///
    /// `AppError::MissingKeyPackage` carries a free-form label — an account id hex everywhere on
    /// the member-resolution path — so it is matched against both identifiers a recipient carries
    /// rather than parsed into one. A label that matches neither yields `nil`, and every caller
    /// falls back to an unnamed message rather than showing the raw payload.
    static func refusedRecipient(named account: String?, among recipients: [NewChatRecipient])
        -> NewChatRecipient?
    {
        guard let account, !account.isEmpty else { return nil }
        return recipients.first {
            $0.accountIdHex.caseInsensitiveCompare(account) == .orderedSame
                || (!$0.npub.isEmpty && $0.npub.caseInsensitiveCompare(account) == .orderedSame)
        }
    }

    /// One-line message for a surface with no room to restage the composition — the add-member
    /// sheet on an existing group, where the user's fix is to deselect and retry. Names the
    /// recipient when the core named one and the caller knows them.
    static func message(for error: Error, candidates: [NewChatRecipient]) -> String {
        switch ChatCreationFailure(error) {
        case .notOnWhiteNoise(let account):
            guard let named = refusedRecipient(named: account, among: candidates) else {
                return L10n.string("Someone you picked isn't on White Noise yet, so they can't be added.")
            }
            return String(
                format: L10n.string("%@ isn't on White Noise yet, so they can't be added."),
                named.title)
        case .other(let message):
            return message
        }
    }
}

/// Which compose surface asked for the chat. The failure lands somewhere different on each, so
/// this is carried explicitly rather than inferred from the roster size — a group draft whose last
/// reachable member is refused is still a group draft, and its answer belongs in the panel that is
/// on screen, not in the direct-chat prompt.
nonisolated enum ChatCreationSurface {
    case directChat
    case groupDraft
}

/// Shown in place of an error when a one-to-one chat cannot start because the recipient has no
/// usable messaging setup. There is nothing to retry and nothing to fix in the composition, so
/// the panel offers the only useful next step: invite them.
nonisolated struct StartChatInvitePrompt: Equatable {
    let accountIdHex: String
    let recipientName: String?
    /// The trimmed compose query this prompt was raised under — empty when it came from a contact
    /// row rather than a typed identifier. Visibility is derived from this rather than cleared on
    /// change (`WorkspaceState.visibleStartChatInvitePrompt`): the resolution path it would have
    /// to hook is debounced and cancels itself on every keystroke, so an imperative clear does not
    /// land until typing stops, leaving one recipient's prompt over another's row in the meantime.
    let query: String

    var detail: String {
        WhiteNoiseInvite.detail(recipientName: recipientName)
    }
}

/// Invite copy shared by the direct-chat prompt and the group-draft notice. Deliberately worded
/// like the iOS and Flutter clients so someone who has seen one recognizes the other.
nonisolated enum WhiteNoiseInvite {
    static var message: String {
        L10n.string("Let's chat on White Noise — private, secure messaging. Get it at https://whitenoise.chat")
    }

    static func detail(recipientName: String?) -> String {
        guard let recipientName, !recipientName.isEmpty else {
            return L10n.string("They aren't on White Noise yet. Share the app so you can chat securely.")
        }
        return String(
            format: L10n.string("%@ isn't on White Noise yet. Share the app so you can chat securely."),
            recipientName)
    }
}
