//
//  ChatDestructiveActionsConfirmation.swift
//  whitenoise-mac
//
//  The single confirmation and reporting surface for the two destructive chat actions. Both the
//  sidebar row context menu and the group-details inspector drive it through workspace state, so
//  each action has exactly one dialog and one wording in the whole app.
//
//  It has to live on state rather than in a view for the same reason `messageDeletionConfirmation`
//  does: a SwiftUI `contextMenu` closure is torn down when an item is chosen, so a dialog declared
//  inside it never presents. Attached in `ContentView` rather than on the conversation pane,
//  because deleting a dead chat is most likely with no chat selected at all.
//

import SwiftUI

private struct ChatDestructiveActionsConfirmationModifier: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace

    func body(content: Content) -> some View {
        @Bindable var workspace = workspace

        content
            .confirmationDialog(
                leaveTitle(workspace.chatPendingLeave),
                isPresented: Binding(
                    get: { workspace.chatPendingLeave != nil },
                    set: { presented in
                        if !presented { workspace.chatPendingLeave = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: workspace.chatPendingLeave
            ) { target in
                Button(L10n.string("Leave Chat"), role: .destructive) {
                    Task { await workspace.confirmChatLeave(target) }
                }
                .disabled(workspace.leavingChatId != nil)
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: { target in
                Text(leaveMessage(target))
            }
            .confirmationDialog(
                localDeleteTitle(workspace.chatPendingLocalDelete),
                isPresented: Binding(
                    get: { workspace.chatPendingLocalDelete != nil },
                    set: { presented in
                        if !presented { workspace.chatPendingLocalDelete = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: workspace.chatPendingLocalDelete
            ) { target in
                Button(L10n.string("Remove From This Device"), role: .destructive) {
                    Task { await workspace.confirmChatLocalDelete(target) }
                }
                .disabled(workspace.isDeletingGroupLocally)
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: { _ in
                Text(
                    L10n.string(
                        "This deletes the local copy only. Other members are not notified, and you can be re-added later."
                    )
                )
            }
            .alert(
                workspace.chatActionAlert?.title ?? "",
                isPresented: Binding(
                    get: { workspace.chatActionAlert != nil },
                    set: { presented in
                        if !presented { workspace.chatActionAlert = nil }
                    }
                ),
                presenting: workspace.chatActionAlert
            ) { _ in
                // No local-delete alternative here on purpose: dropping the local copy while the
                // group still counts you as a member would silently strand everyone else's messages.
                Button(L10n.string("OK"), role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
    }

    private func leaveTitle(_ target: ChatLeaveTarget?) -> String {
        guard let target else { return L10n.string("Leave this chat?") }
        return String(format: L10n.string("Leave “%@”?"), target.title)
    }

    private func leaveMessage(_ target: ChatLeaveTarget) -> String {
        if target.requiresSelfDemote {
            return L10n.string(
                "You'll step down as admin first, then stop receiving messages from this group."
            )
        }
        return L10n.string("You will no longer receive messages from this group on this account.")
    }

    private func localDeleteTitle(_ target: ChatLocalDeleteTarget?) -> String {
        guard let target else { return L10n.string("Remove this conversation from this device?") }
        return String(format: L10n.string("Delete “%@” from this device?"), target.title)
    }
}

extension View {
    func chatDestructiveActionsConfirmation() -> some View {
        modifier(ChatDestructiveActionsConfirmationModifier())
    }
}
