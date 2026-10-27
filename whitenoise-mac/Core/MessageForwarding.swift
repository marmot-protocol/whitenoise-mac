//
//  MessageForwarding.swift
//  whitenoise-mac
//
//  What a forward re-sends, worked out before anything is sent. A forwarded message is a new
//  message in the destination chat: its text goes out as text, and its attachments go through
//  that chat's ordinary attachment send with the source message's text as their caption.
//

import Foundation
import MarmotKit

/// One source message as it will be re-sent to the destination chat.
nonisolated struct ForwardedMessage: Hashable, Sendable {
    /// The canonical text (`MessageItem.wireBody`): a plain message's body, or a media message's
    /// caption. Empty for an attachment-only message.
    let text: String
    /// The attachments that could be fetched, in the order the source message carried them.
    let attachments: [PendingMediaAttachment]

    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty
    }
}

/// Everything one forward will send, plus the files it cannot.
nonisolated struct MessageForwardPlan: Hashable, Sendable {
    let messages: [ForwardedMessage]
    /// Display names of attachments whose bytes could not be fetched. They are reported to the
    /// user before anything is sent, never dropped silently.
    let unavailableFileNames: [String]

    var hasContent: Bool {
        !messages.isEmpty
    }

    var isComplete: Bool {
        unavailableFileNames.isEmpty
    }

    /// Builds the plan for `messages` in order, fetching each attachment with `fetch`.
    ///
    /// A message whose text is empty and whose every attachment is unavailable contributes
    /// nothing: there is no message left to send for it, only files to report. A captioned
    /// message whose attachments are all unavailable still forwards its caption as text.
    @MainActor
    static func make(
        messages: [MessageItem],
        fetch: @MainActor (MessageMediaAttachment, MessageItem) async -> MessageMediaDownload?
    ) async -> MessageForwardPlan {
        var forwarded: [ForwardedMessage] = []
        var unavailable: [String] = []
        for message in messages {
            var attachments: [PendingMediaAttachment] = []
            for attachment in message.contentMediaAttachments {
                guard attachment.rejectionKind == nil,
                    let download = await fetch(attachment, message),
                    !download.payload.data.isEmpty
                else {
                    unavailable.append(attachment.fileName)
                    continue
                }
                attachments.append(forwardedAttachment(attachment, download: download))
            }
            let item = ForwardedMessage(
                text: message.wireBody.trimmingCharacters(in: .whitespacesAndNewlines),
                attachments: attachments
            )
            if !item.isEmpty {
                forwarded.append(item)
            }
        }
        return MessageForwardPlan(messages: forwarded, unavailableFileNames: unavailable)
    }

    /// The fetched attachment as a staged one, ready for the destination's attachment send.
    ///
    /// The core's own name and type win over the timeline reference's, matching what a download
    /// writes; the reference's dimensions and ThumbHash carry over so the forwarded copy lays out
    /// and placeholders the same way the original does.
    static func forwardedAttachment(
        _ attachment: MessageMediaAttachment,
        download: MessageMediaDownload
    ) -> PendingMediaAttachment {
        PendingMediaAttachment(
            fileName: download.fileName.nilIfBlank ?? attachment.fileName,
            mediaType: download.mediaType.nilIfBlank ?? attachment.mediaType,
            data: download.payload.data,
            dim: attachment.reference.dim,
            thumbhash: attachment.reference.thumbhash
        )
    }
}
