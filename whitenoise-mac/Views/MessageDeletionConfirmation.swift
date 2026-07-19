//
//  MessageDeletionConfirmation.swift
//  whitenoise-mac
//
//  The unified delete-confirmation surface: one adaptive dialog offering only the scopes the
//  local account may perform on the pending message. A native confirmationDialog carries the
//  platform's semantic destructive styling, VoiceOver, keyboard, and RTL handling.
//

import SwiftUI

private struct MessageDeletionConfirmationModifier: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace

    func body(content: Content) -> some View {
        @Bindable var workspace = workspace

        content.confirmationDialog(
            L10n.string("Delete message?"),
            isPresented: Binding(
                get: { workspace.messagePendingDeletion != nil },
                set: { presented in
                    if !presented { workspace.messagePendingDeletion = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: workspace.messagePendingDeletion
        ) { message in
            let capability = workspace.messageDeletionCapability(message)
            if capability.canDeleteForEveryone {
                Button(L10n.string("Delete for everyone"), role: .destructive) {
                    Task { await workspace.deleteForEveryone(message) }
                }
            }
            if capability.canDeleteForMe {
                Button(L10n.string("Delete for me"), role: .destructive) {
                    workspace.deleteForMe(message)
                }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: { message in
            Text(workspace.messageDeletionScopeExplanation(message))
        }
    }
}

extension View {
    func messageDeletionConfirmation() -> some View {
        modifier(MessageDeletionConfirmationModifier())
    }
}
