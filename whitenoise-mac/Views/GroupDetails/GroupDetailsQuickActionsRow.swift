//
//  GroupDetailsQuickActionsRow.swift
//  whitenoise-mac
//
//  Mute, Disappearing and Add under the group's name. Ported from the iOS client's
//  `actionsRowSection`.
//

import SwiftUI

/// The quick actions under group info's hero.
///
/// iOS has a fourth, Search, which jumps into the conversation's own search. This app has no
/// per-conversation search — only the global one, which would answer a different question — so
/// the row leaves it out rather than offer a button that searches every chat.
struct GroupDetailsQuickActionsRow: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isTimerPresented = false
    let chat: ChatItem
    let snapshot: GroupDetailsSnapshot
    let permissions: GroupDetailsPermissions
    let onAddMembers: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            GroupDetailsQuickAction(
                title: L10n.string(chat.muted ? "Unmute" : "Mute"),
                systemImage: chat.muted ? "bell" : "bell.slash",
                action: toggleMuted
            )
            .disabled(workspace.isMutatingChatPreferences(chat))

            GroupDetailsQuickAction(title: L10n.string("Disappearing"), systemImage: "timer") {
                isTimerPresented = true
            }
            .disabled(workspace.hasInFlightGroupCommit || !permissions.canEditGroup)
            .popover(isPresented: $isTimerPresented, arrowEdge: .bottom) {
                DisappearingTimerPopover(currentSeconds: snapshot.disappearingMessageSecs, onSelect: setTimer)
                    // Popovers are hosted outside this view's hierarchy and inherit nothing from
                    // it, so the app-language locale has to be handed over again.
                    .environment(\.locale, workspace.preferredLocale)
            }

            if permissions.canInvite {
                GroupDetailsQuickAction(
                    title: L10n.string("Add"), systemImage: "person.badge.plus", action: onAddMembers
                )
                .disabled(workspace.hasInFlightGroupCommit)
            }
        }
    }

    /// Mute here is the plain toggle iOS offers — muted until turned back on. The timed mutes stay
    /// in the chat row's menu, where there is room to list them.
    private func toggleMuted() {
        Task {
            if chat.muted {
                await workspace.clearChatMuted(chat)
            } else {
                await workspace.setChatMuted(chat, duration: nil)
            }
        }
    }

    private func setTimer(_ seconds: UInt64) {
        isTimerPresented = false
        Task { await workspace.setDisappearingMessages(groupIdHex: snapshot.groupIdHex, seconds: seconds) }
    }
}
