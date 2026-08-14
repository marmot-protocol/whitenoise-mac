//
//  WorkspaceState+PendingInviteInviter.swift
//  whitenoise-mac
//
//  The identity behind the name in a pending invite: whose avatar the notice draws, and whose
//  profile it opens when that avatar is clicked.
//
//  Naming the inviter is `inviterDisplayName(forGroupIdHex:)`'s job, and the notice keeps it —
//  this only answers "who is that, exactly", which a name cannot: the avatar to draw, and the
//  npub the contact pane needs so the invitee can compare a key before accepting rather than
//  taking a display name at face value.
//
//  Everything here reads caches the invite has already filled. `groupWelcomerCache` and
//  `groupMemberDetailsCache` are written together by `storeGroupMembers`, which the notice's
//  `ensureGroupInviterLoaded` triggers, and the picture comes from the observed peer-profile
//  cache the roster's kind:0 pull populates — so a profile that lands after the notice is drawn
//  reaches the avatar without re-projecting anything.
//

import Foundation
import MarmotKit

@MainActor
extension WorkspaceState {
    /// Who sent a pending invite, in the terms an avatar and a profile need.
    struct PendingInviteInviterIdentity: Hashable {
        let accountIdHex: String
        /// Empty until the roster resolves; the contact pane falls back to the hex key.
        let npub: String
        let pictureURL: String?
        /// Already through `RemoteImageURLPolicy`; the view still applies `loadRemoteImages`.
        let sanitizedPictureURL: URL?
    }

    /// The inviter of `chat`, or nil when this is not a pending invite, when nobody is recorded
    /// as having sent it, or when the invite came from this account (nothing to look up).
    ///
    /// The direct-chat fallback matches how the notice names an inviter it has no welcomer for:
    /// a one-to-one has exactly one other member, so they are the person who invited you.
    func pendingInviteInviterIdentity(for chat: ChatItem) -> PendingInviteInviterIdentity? {
        guard chat.pendingConfirmation else { return nil }
        let welcomer = inviterAccountIdHex(forGroupIdHex: chat.id)
        guard let accountIdHex = (welcomer ?? chat.directPeerAccountIdHex)?.nilIfBlank,
            accountIdHex != activeAccount?.accountIdHex
        else { return nil }

        let member = groupMemberDetailsCache[chat.id]?.first { $0.memberIdHex == accountIdHex }
        let pictureURL = peerProfileFFICache[accountIdHex]?.resolved.profilePicture
        return PendingInviteInviterIdentity(
            accountIdHex: accountIdHex,
            npub: member?.npub.nilIfBlank ?? "",
            pictureURL: pictureURL,
            sanitizedPictureURL: RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
        )
    }

    /// Opens the inviter's profile, the way a group-details member row or a message avatar does.
    ///
    /// `name` is what the notice calls them, so the pane opens on the name the user just read
    /// rather than blanking until the profile re-resolves.
    func showContactDetails(
        for inviter: PendingInviteInviterIdentity,
        named name: String,
        invitedTo chat: ChatItem
    ) async {
        await showContactDetails(
            accountIdHex: inviter.accountIdHex,
            npub: inviter.npub,
            displayName: name,
            pictureURL: inviter.pictureURL,
            // The invite has not been accepted, so the group it is for is not a group in common.
            excludingGroupIdHex: chat.id
        )
    }
}
