//
//  WorkspaceState+Reactions.swift
//  whitenoise-mac
//
//  Reactor identity resolution for the reaction viewer — display name + avatar for an
//  account-id-hex, drawn from already-cached data (active account, resolved peer-profile cache,
//  and the group roster). No FFI, so the viewer stays cheap to render.
//

import Foundation
import MarmotKit

@MainActor
extension WorkspaceState {
    struct ReactionReactorDisplay: Identifiable, Hashable {
        let accountIdHex: String
        let name: String
        let sanitizedPictureURL: URL?
        let isSelf: Bool
        var id: String { accountIdHex }
    }

    func reactionReactorDisplay(accountIdHex: String) -> ReactionReactorDisplay {
        if let active = activeAccount, active.accountIdHex == accountIdHex {
            return ReactionReactorDisplay(
                accountIdHex: accountIdHex,
                name: active.displayName,
                sanitizedPictureURL: RemoteImageURLPolicy.sanitizedURL(from: active.pictureURL),
                isSelf: true
            )
        }
        // Read-only on purpose: this runs inside a SwiftUI view body, once per reactor per
        // render pass. Reaction senders are requested from `messageSenderProfiles` on the
        // projection path instead — once per window/delta rather than once per frame.
        // `peerProfileFFICache` is observed, so a name resolved there reaches this row on its
        // own with no re-projection.
        let resolved = peerProfileFFICache[accountIdHex]?.resolved
        let rosterMember = selectedChat.flatMap { chat in
            groupMemberDetailsCache[chat.id]?.first { $0.memberIdHex == accountIdHex }
        }
        let rosterName = rosterMember.flatMap { PeerDisplayText.sanitize($0.displayName) }
        let name =
            firstNonBlank([
                PeerDisplayText.sanitize(resolved?.profileDisplayName),
                PeerDisplayText.sanitize(resolved?.profileName),
                rosterName,
                PeerDisplayText.sanitize(resolved?.directoryDisplayName),
            ]) ?? DisplayText.short(accountIdHex)
        return ReactionReactorDisplay(
            accountIdHex: accountIdHex,
            name: name,
            sanitizedPictureURL: RemoteImageURLPolicy.sanitizedURL(from: resolved?.profilePicture),
            isSelf: false
        )
    }
}
