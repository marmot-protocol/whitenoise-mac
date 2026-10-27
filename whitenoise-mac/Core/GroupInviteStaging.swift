//
//  GroupInviteStaging.swift
//  whitenoise-mac
//
//  Folds a resolved identifier into an invite roster, refusing one that names nobody or someone
//  already in the group.
//

import Foundation

enum GroupInviteStaging {
    enum Outcome: Equatable {
        /// The roster to invite, with the resolved recipient appended unless already staged.
        case staged([NewChatRecipient])
        /// The identifier resolved to nobody; nothing is invited.
        case invalidIdentifier
        /// The identifier is someone already in the group; nothing is invited.
        case alreadyMember
        /// The identifier is someone the account blocked; nothing is invited.
        case blocked
        /// The invite was abandoned while the identifier resolved (the sheet closed); nothing is
        /// invited and there is no one left to tell.
        case cancelled

        /// The sheet's error line for a rejected identifier, or `nil` when it was staged.
        var errorMessage: String? {
            switch self {
            case .staged, .cancelled:
                return nil
            case .invalidIdentifier:
                return L10n.string("Enter a valid NIP-05, npub, profile link, or hex public key.")
            case .alreadyMember:
                return L10n.string("That person is already in this group.")
            case .blocked:
                return L10n.string("You blocked this user")
            }
        }
    }

    /// Whether Return commits the invite. Not while a name search is in the field: Return there
    /// reads as "add this one", and inviting the staged roster without them would drop the person
    /// silently. Clicking Invite still commits, with the name search ignored.
    static func returnInvites(query: String, isIdentifier: Bool) -> Bool {
        query.isEmpty || isIdentifier
    }

    /// Fold whatever is still typed in the search field into `staged` before an invite commits.
    ///
    /// `query` is the trimmed field text and `isIdentifier` whether it reads as an npub / NIP-05 /
    /// profile link / hex key. Empty text or a name search folds nothing in: the roster is
    /// `staged` unchanged. An identifier uses `resolved` when the field's lookup already finished,
    /// and only otherwise calls `resolve`. `isBlocked` takes an account id hex.
    ///
    /// `shouldCommit` is asked once `resolve` returns: the resolve is a relay round-trip, and the
    /// sheet can close while it runs. Nothing guards the resolve itself, so without this a Cancel
    /// pressed mid-resolve would still send the invite.
    static func foldPending(
        query: String,
        isIdentifier: Bool,
        resolved: NewChatRecipient?,
        resolve: (String) async -> NewChatRecipient?,
        into staged: [NewChatRecipient],
        lockedMemberIds: Set<String>,
        isBlocked: (String) -> Bool,
        shouldCommit: () -> Bool = { true }
    ) async -> Outcome {
        guard !query.isEmpty, isIdentifier else { return .staged(staged) }
        let recipient: NewChatRecipient?
        if let resolved {
            recipient = resolved
        } else {
            recipient = await resolve(query)
            guard shouldCommit() else { return .cancelled }
        }
        return stage(recipient, into: staged, lockedMemberIds: lockedMemberIds, isBlocked: isBlocked)
    }

    /// Whether a pending identifier would add someone to `staged` — what Invite's count includes.
    /// Until it resolves this is assumed; once it has, it counts only if staging would append it, so
    /// someone already staged, already in the group, or blocked doesn't inflate the count.
    static func pendingIdentifierAddsOne(
        isIdentifier: Bool,
        resolved: NewChatRecipient?,
        to staged: [NewChatRecipient],
        lockedMemberIds: Set<String>,
        isBlocked: (String) -> Bool
    ) -> Bool {
        guard isIdentifier else { return false }
        guard let resolved else { return true }
        let outcome = stage(resolved, into: staged, lockedMemberIds: lockedMemberIds, isBlocked: isBlocked)
        guard case .staged(let roster) = outcome else { return false }
        return roster.count > staged.count
    }

    /// Fold `resolved` — what the pending identifier resolved to, `nil` if nothing — into `staged`.
    /// `lockedMemberIds` are the group's current members, lowercased. A blocked person is refused
    /// even though the search already hides them, so the action agrees with the "No matches" shown.
    static func stage(
        _ resolved: NewChatRecipient?,
        into staged: [NewChatRecipient],
        lockedMemberIds: Set<String>,
        isBlocked: (String) -> Bool = { _ in false }
    ) -> Outcome {
        guard let resolved else { return .invalidIdentifier }
        let hex = resolved.accountIdHex.lowercased()
        guard !lockedMemberIds.contains(hex) else { return .alreadyMember }
        guard !isBlocked(resolved.accountIdHex) else { return .blocked }
        if staged.contains(where: { $0.accountIdHex.lowercased() == hex }) {
            return .staged(staged)
        }
        return .staged(staged + [resolved])
    }
}
