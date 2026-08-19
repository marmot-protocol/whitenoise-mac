//
//  MessageSendFailureActions.swift
//  whitenoise-mac
//
//  The recovery control under a send that did not make it out: run it again.
//

import SwiftUI

/// Retry for an outgoing message that failed, rendered under the bubble it acts on.
///
/// Shared by the two kinds of failed own row so they read as one thing: the locally staged media
/// message that never published (`PendingOutgoingMessageBubble`) and the core-committed message
/// stranded before its relay round-trip (`MessageBubble`). This is the macOS answer to the iOS
/// clients' tap-the-bubble action sheet — on a pointer platform the one thing worth doing about a
/// failure belongs in the open, under the row, not behind a gesture and a dialog.
///
/// Only retry. Deleting a failed message is not a recovery — it is the same destructive action
/// every other row has, and it lives where every other row keeps it: the ⋯ menu
/// (`MessageRowAction.all`). Putting it here as well made the one control under a failure a
/// two-way choice, with the destructive half a click away from the one the user came for.
///
/// Nothing here covers a retry that is already running: both rows put the bubble back into their
/// respective sending state for that window — clock in the footer, or the staged bubble's own
/// spinner — so this control is simply not rendered while one is in flight.
struct MessageSendFailureActions: View {
    let onRetry: () -> Void

    var body: some View {
        Button(L10n.string("Retry"), systemImage: "arrow.clockwise", action: onRetry)
            .buttonStyle(.link)
            .wnFont(.medium10)
            .labelStyle(.titleOnly)
    }
}
