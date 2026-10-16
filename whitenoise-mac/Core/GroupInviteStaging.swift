//
//  GroupInviteStaging.swift
//  whitenoise-mac
//
//  How the add-members sheet folds a typed identifier into its staged roster when Invite (or
//  Return) is pressed before the resolved row was clicked, so one press still invites.
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

        /// The sheet's error line for a rejected identifier, or `nil` when it was staged.
        var errorMessage: String? {
            switch self {
            case .staged:
                return nil
            case .invalidIdentifier:
                return L10n.string("Enter a valid NIP-05, npub, profile link, or hex public key.")
            case .alreadyMember:
                return L10n.string("That person is already in this group.")
            }
        }
    }

    /// Fold `resolved` — what the pending identifier resolved to, `nil` if nothing — into `staged`.
    /// `lockedMemberIds` are the group's current members, lowercased.
    static func stage(
        _ resolved: NewChatRecipient?,
        into staged: [NewChatRecipient],
        lockedMemberIds: Set<String>
    ) -> Outcome {
        guard let resolved else { return .invalidIdentifier }
        let hex = resolved.accountIdHex.lowercased()
        guard !lockedMemberIds.contains(hex) else { return .alreadyMember }
        if staged.contains(where: { $0.accountIdHex.lowercased() == hex }) {
            return .staged(staged)
        }
        return .staged(staged + [resolved])
    }
}
