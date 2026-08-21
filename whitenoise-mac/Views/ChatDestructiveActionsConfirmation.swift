//
//  ChatDestructiveActionsConfirmation.swift
//  whitenoise-mac
//
//  The single confirmation and reporting surface for the two destructive chat actions, plus the
//  admin handoff a sole admin's leave routes through. Both the sidebar row context menu and the
//  group-details inspector drive it through workspace state, so each action has exactly one dialog
//  and one wording in the whole app.
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
            // A sheet rather than a confirmation dialog because this step asks for a choice from a
            // roster, not a yes/no. It is attached here for the same reason the dialogs above are:
            // the leave can start from a sidebar row whose menu is already torn down.
            .sheet(item: $workspace.chatPendingAdminHandoff) { target in
                ChatAdminHandoffSheet(target: target)
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
                // The one case where that argument does not apply — nobody else left in the chat —
                // never reaches this alert; it opens the local-delete confirmation above instead.
                Button(L10n.string("OK"), role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
    }

    // The wording lives on `ChatConfirmationSubject` rather than here: a group with no name and a
    // one-to-one chat need different *sentences*, not a different name dropped into one, and that
    // choice has to be testable without standing up a dialog.

    private func leaveTitle(_ target: ChatLeaveTarget?) -> String {
        guard let target else { return L10n.string("Leave this chat?") }
        return target.subject.leaveConfirmationTitle
    }

    private func leaveMessage(_ target: ChatLeaveTarget) -> String {
        target.subject.leaveConfirmationMessage(requiresSelfDemote: target.requiresSelfDemote)
    }

    private func localDeleteTitle(_ target: ChatLocalDeleteTarget?) -> String {
        guard let target else { return L10n.string("Remove this conversation from this device?") }
        return target.subject.localDeleteConfirmationTitle
    }
}

extension View {
    func chatDestructiveActionsConfirmation() -> some View {
        modifier(ChatDestructiveActionsConfirmationModifier())
    }
}
