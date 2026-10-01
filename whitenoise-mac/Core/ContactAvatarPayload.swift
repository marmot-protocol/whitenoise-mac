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
/// The contact pane used to receive only the kind:0 `picture` URL, which "Load Remote Profile
/// Images" blanks while it is off (the default). So a contact whose picture showed beside their
/// message opened onto a profile of initials. The core exposes no avatar lookup by account, only
/// the assets it attaches to chat rows and conversation identities, so this reads those.
enum ContactAvatarPayload {
    /// The newest transcript bytes for `accountIdHex`, then their direct chat's. The transcript
    /// comes first because it is the conversation the profile was opened from.
    static func find(
        accountIdHex: String,
        messages: [MessageItem],
        chats: [ChatItem]
    ) -> DownloadedMediaPayload? {
        messages.last { $0.senderAccountIdHex == accountIdHex && $0.senderImagePayload != nil }?
            .senderImagePayload
            ?? chats.first { $0.directPeerAccountIdHex == accountIdHex }?.groupImagePayload
    }
}
