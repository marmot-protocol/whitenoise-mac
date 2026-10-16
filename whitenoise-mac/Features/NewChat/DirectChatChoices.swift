//
//  DirectChatChoices.swift
//  whitenoise-mac
//
//  The direct chats a person already shares with the viewer, offered before starting another.
//

import Foundation

/// One existing direct chat the chooser offers to continue.
nonisolated struct DirectChatChoice: Identifiable, Hashable {
    let chat: ChatItem
    let isArchived: Bool

    var id: String { chat.id }
}

/// The chooser shown when the person picked in New chat already has a direct chat with the viewer.
struct DirectChatChooserPresentation: Identifiable, Equatable {
    let recipient: NewChatRecipient
    let choices: [DirectChatChoice]

    var id: String { recipient.accountIdHex }
}

/// Pure decisions for the chooser, testable without a workspace.
nonisolated enum DirectChatChoices {
    /// Every direct chat with `peerAccountIdHex` the viewer is still in, newest activity first.
    ///
    /// A chat the viewer left or was removed from is not one they can continue, so it is not
    /// offered; starting a new one is. Archived chats are offered and marked, the way iOS does.
    ///
    /// Matching relies on `directPeerAccountIdHex`, which the chat list fills in when it enriches
    /// a row. A direct chat whose peer is not resolved yet is not found here, so the chooser would
    /// create another chat instead of asking. That gap predates the chooser (the old reuse path had
    /// it too); the group composer avoids it by comparing member sets, an async roster read per
    /// chat that this synchronous decision does not make.
    static func existing(
        withPeer peerAccountIdHex: String,
        active: [ChatItem],
        archived: [ChatItem]
    ) -> [DirectChatChoice] {
        let peer = peerAccountIdHex.lowercased()
        var seen: Set<String> = []
        return (active.map { ($0, false) } + archived.map { ($0, true) })
            .filter { chat, _ in
                chat.isDirect
                    && chat.selfMembership == .member
                    && chat.directPeerAccountIdHex?.lowercased() == peer
            }
            .filter { chat, _ in seen.insert(chat.id).inserted }
            .map { DirectChatChoice(chat: $0, isArchived: $1) }
            .sorted {
                let lhsDate = $0.chat.updatedAt ?? .distantPast
                let rhsDate = $1.chat.updatedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.chat.id < $1.chat.id
            }
    }
}
