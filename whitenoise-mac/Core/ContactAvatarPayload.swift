//
//  ContactAvatarPayload.swift
//  whitenoise-mac
//
//  Finds a contact's avatar among the bytes the app already holds, so a profile draws the same
//  picture as the row it was opened from.
//

import Foundation

/// The contact's avatar bytes, taken from what is already on screen.
///
/// MDK acquires peer avatars itself and the chat list and transcript draw those retained bytes.
/// The contact pane draws those same bytes ahead of the kind:0 `picture` URL, so it shows the
/// picture already beside their message instead of starting a second fetch. The core exposes no avatar lookup by account, only
/// the assets it attaches to chat rows and conversation identities, so this reads those.
enum ContactAvatarPayload {
    /// The newest transcript bytes for `accountIdHex`, then their direct chat's. The transcript
    /// comes first because it is the conversation the profile was opened from.
    static func find(
        accountIdHex: String,
        messages: [MessageItem],
        chats: [ChatItem]
    ) -> DownloadedMediaPayload? {
        index(for: [accountIdHex], messages: messages, chats: chats)[accountIdHex]
    }

    /// `find` for a whole roster in one pass over each source, keyed by account id; ids with no
    /// bytes on screen are absent. Sharing the precedence is what makes a group-info member row
    /// draw the picture the profile it opens will.
    static func index(
        for accountIdHexes: Set<String>,
        messages: [MessageItem],
        chats: [ChatItem]
    ) -> [String: DownloadedMediaPayload] {
        var result: [String: DownloadedMediaPayload] = [:]
        for message in messages.reversed() where accountIdHexes.contains(message.senderAccountIdHex) {
            if result[message.senderAccountIdHex] == nil, let payload = message.senderImagePayload {
                result[message.senderAccountIdHex] = payload
            }
        }
        for chat in chats {
            if let peer = chat.directPeerAccountIdHex, accountIdHexes.contains(peer), result[peer] == nil,
                let payload = chat.groupImagePayload
            {
                result[peer] = payload
            }
        }
        return result
    }
}
