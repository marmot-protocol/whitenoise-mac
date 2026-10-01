//
//  ContactProfileActionsRow.swift
//  whitenoise-mac
//
//  Follow and Message, side by side under a contact's name.
//

import SwiftUI

/// Follow and Message, side by side directly under the profile header.
///
/// Both sibling clients lead a profile with these two: iOS puts them in equal-width buttons
/// above the detail rows, and the Flutter app stacks Follow first in its action column. This
/// app used to keep Follow inside a form row beside "Copy Public Key", where a small bordered
/// button next to a clipboard action read as another utility rather than as the way to follow
/// someone — the feature was there and still could not be found.
struct ContactProfileActionsRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let contact: NewChatRecipient

    var body: some View {
        HStack(spacing: 10) {
            ContactFollowControl(accountIdHex: contact.accountIdHex)

            Button {
                Task { await workspace.messageContact(contact) }
            } label: {
                Label(L10n.string("Message"), systemImage: "message")
                    .frame(maxWidth: .infinity)
            }
            .wnPrimaryButtonStyle()
            .disabled(workspace.isCreatingChat)
        }
        .controlSize(.large)
        .accessibilityIdentifier("contact.details.actions")
    }
}
