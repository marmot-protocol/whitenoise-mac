//
//  MessageBubbleLayout.swift
//  whitenoise-mac
//

import Foundation

/// One of the parts a message row stacks, top to bottom.
nonisolated enum MessageBubbleElement: Hashable, Sendable {
    /// Who sent it, above an incoming row.
    case senderName
    /// The photo/video grid.
    case visualMediaGrid
    /// Audio and document rows.
    case nonvisualMediaRows
    /// The bubble proper — text, a caption, a reply quote, the debug row.
    case bubbleContent
    /// The reaction pills.
    case reactionChips
    /// The bare time-and-status line a row with no bubble carries instead.
    case standaloneMetadata
    /// The retry/remove links under a send that failed.
    case sendFailureActions
}

/// The order a message row stacks its parts in.
///
/// Stated once, here, because the order is load-bearing and invisible from anywhere else: the
/// reaction pill is drawn with a negative top padding, so it rides up onto **whatever the row
/// emitted immediately before it**. A caption-less row's metadata is a bare 10pt line rather than a
/// surface with an edge to spare — emitted before the chips, it was what the pill overlapped, and
/// the reactions sat on top of the time.
nonisolated enum MessageBubbleLayout {
    static func elements(
        for message: MessageItem,
        showsDebugMetadata: Bool
    ) -> [MessageBubbleElement] {
        var elements: [MessageBubbleElement] = []

        if !message.isOutgoing {
            elements.append(.senderName)
        }
        if !message.visualMediaAttachments.isEmpty {
            elements.append(.visualMediaGrid)
        }
        if !message.nonvisualMediaAttachments.isEmpty {
            elements.append(.nonvisualMediaRows)
        }
        if showsDebugMetadata || message.hasBubbleContent {
            elements.append(.bubbleContent)
        }
        if message.supportsChatActions, !message.reactions.isEmpty {
            elements.append(.reactionChips)
        }
        // After the chips, never before them.
        if !message.hasBubbleContent {
            elements.append(.standaloneMetadata)
        }
        elements.append(.sendFailureActions)

        return elements
    }
}
