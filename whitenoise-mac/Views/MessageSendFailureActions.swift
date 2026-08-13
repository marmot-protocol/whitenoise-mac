//
//  MessageSendFailureActions.swift
//  whitenoise-mac
//
//  The recovery row under a send that did not make it out: run it again, or take it off the
//  transcript.
//

import SwiftUI

/// Recovery controls for an outgoing message that failed, rendered under the bubble they act on.
///
/// Shared by the two kinds of failed own row so they read as one thing: the locally staged media
/// message that never published (`PendingOutgoingMessageBubble`) and the core-committed message
/// stranded before its relay round-trip (`MessageBubble`). This is the macOS answer to the iOS
/// clients' tap-the-bubble action sheet — on a pointer platform the options belong in the open,
/// under the row, not behind a gesture and a dialog.
///
/// Both actions are optional because the two rows disagree about what a failure allows: an
/// invalidated message can only be removed, and a message in a conversation the account may not act
/// in can only be retried. A row with neither action left renders nothing.
struct MessageSendFailureActions: View {
    let onRetry: (() -> Void)?
    let discardTitle: String
    let onDiscard: (() -> Void)?
    /// Swaps the controls for a progress line while the retry runs. The only feedback the click
    /// gets on a core-committed row: its delivery marker is derived from `sentAt`, so it cannot be
    /// walked back to "Sending" the way the sibling clients walk back an optimistic one.
    var isRetrying = false

    var body: some View {
        HStack(spacing: 8) {
            if isRetrying {
                ProgressView()
                    .controlSize(.mini)
                Text(L10n.string("Retrying…"))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
            } else {
                if let onRetry {
                    Button(L10n.string("Retry"), systemImage: "arrow.clockwise", action: onRetry)
                }
                if let onDiscard {
                    Button(discardTitle, systemImage: "trash", action: onDiscard)
                }
            }
        }
        .buttonStyle(.link)
        .wnFont(.medium10)
        .labelStyle(.titleOnly)
    }

    /// Nothing to offer — the caller should leave the row out entirely rather than reserve empty
    /// space under the bubble.
    var isEmpty: Bool {
        !isRetrying && onRetry == nil && onDiscard == nil
    }
}
