//
//  GroupDetailsLeaveSection.swift
//  whitenoise-mac
//
//  The foot of group info: ending the group, stepping down as admin, and leaving or removing the
//  chat.
//

import SwiftUI

struct GroupDetailsLeaveSection: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SessionState.self) private var session
    @State private var showSelfDemoteConfirmation = false
    @State private var showEndGroupConfirmation = false
    let chat: ChatItem
    let snapshot: GroupDetailsSnapshot
    let disbandModel: GroupDisbandViewModel

    private var isLeaving: Bool { workspace.leavingChatId == snapshot.groupIdHex }
    private var isRemoving: Bool { workspace.deletingChatId == snapshot.groupIdHex }

    /// Ends the group, then reads back what MDK now reports — on failure as well, since enabling
    /// disbanding can commit even when the disband after it is refused.
    ///
    /// Up to two commits run here, so the whole flow holds `isEndingGroup`: every other group change
    /// guards on `hasInFlightGroupCommit`, and none may start against this group until it is done.
    private func endGroup() async {
        guard !workspace.hasInFlightGroupCommit else { return }
        workspace.isEndingGroup = true
        defer { workspace.isEndingGroup = false }
        let accepted = await disbandModel.endGroup(
            snapshot.disband, advisory: session.accountScope?.groupChangeAdvisory)
        await workspace.reloadSelectedGroupDetails()
        if accepted {
            await workspace.reloadChats(forceFreshSnapshot: true)
        }
    }

    var body: some View {
        Section {
            // Ending the group is offered to admins only, and stays on screen (disabled) when
            // members on old clients hold it back, so the footer can say who has to update.
            if snapshot.disband.showsEndGroup {
                DetailsDestructiveRow(
                    title: disbandModel.isEnding ? L10n.string("Ending group…") : L10n.string("End Group"),
                    systemImage: "xmark.circle",
                    isInProgress: disbandModel.isEnding
                ) {
                    showEndGroupConfirmation = true
                }
                .disabled(
                    !snapshot.disband.canEndGroup || disbandModel.isBusy || workspace.hasInFlightGroupCommit)
            }

            // Giving up your own admin rights is reversible by another admin, so it stays
            // neutral: `group_member_screen.dart` builds "remove admin role" as `outline` and
            // keeps `destructive` for removing someone from the group.
            if snapshot.isSelfAdmin, snapshot.disband.lifecycle == .active {
                Button {
                    showSelfDemoteConfirmation = true
                } label: {
                    Label(L10n.string("Step Down as Admin"), systemImage: "star.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(workspace.hasInFlightGroupCommit || snapshot.isLastAdmin)
            }

            // Leave / Delete come from the same policy the sidebar row menu uses, so the two
            // surfaces cannot disagree on which is legal. Membership is very nearly the whole
            // rule: a member is offered the leave even when eligibility will block it, and
            // `prepareSelectedChatLeave` either explains the block or resolves it — with the
            // successor picker for a sole admin who has someone to promote. The one exception is
            // an account alone in a chat it cannot leave, which this pane can see from the roster
            // and so offers the local delete outright.
            switch snapshot.destructiveAction {
            case .leave:
                DetailsDestructiveRow(
                    title: isLeaving
                        ? L10n.string("Leaving...") : L10n.string(chat.isDirect ? "Leave Chat" : "Leave Group"),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    isInProgress: isLeaving
                ) {
                    Task { await workspace.prepareSelectedChatLeave() }
                }
                .disabled(
                    workspace.leavingChatId != nil
                        || workspace.preparingChatLeaveId != nil
                        || workspace.handingOffAdminChatId != nil)

            case .deleteLocally:
                DetailsDestructiveRow(
                    title: isRemoving ? L10n.string("Removing...") : L10n.string("Remove From This Device"),
                    systemImage: "trash.slash",
                    isInProgress: isRemoving
                ) {
                    workspace.requestSelectedChatLocalDelete()
                }
                // Progress is per-chat, but the guard in `deleteGroupLocally` is global, so the
                // affordance stays disabled for any in-flight delete.
                .disabled(workspace.isDeletingGroupLocally)
                .help(L10n.string("Delete this conversation locally without notifying the group"))

            case nil:
                EmptyView()
            }
        } footer: {
            // Sourced from the shared policy so the footer and the row menu's alert cannot drift
            // apart. `leaveGuidance` rather than `leaveBlocker` because the sole admin of a group
            // with someone to promote is not blocked — they are one extra step from leaving, and
            // the footer says which step.
            VStack(alignment: .leading, spacing: 4) {
                if let blocker = snapshot.disband.blockerMessage {
                    SettingsFooterText(blocker)
                }
                if snapshot.disband.lifecycle == .ended {
                    SettingsFooterText(L10n.string("Deletes this chat's local history from this device."))
                } else if let guidance = snapshot.leaveGuidance {
                    SettingsFooterText(guidance.message)
                }
            }
        }
        .confirmationDialog(
            GroupDisbandPresentation.confirmationTitle,
            isPresented: $showEndGroupConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("End Group"), role: .destructive) {
                Task { await endGroup() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(GroupDisbandPresentation.confirmationMessage)
        }
        .alert(
            disbandModel.alert?.title ?? "",
            isPresented: Binding(
                get: { disbandModel.alert != nil },
                set: { presented in
                    if !presented { disbandModel.alert = nil }
                }
            ),
            presenting: disbandModel.alert
        ) { _ in
            Button(L10n.string("OK"), role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .confirmationDialog(
            L10n.string("Step down as admin?"),
            isPresented: $showSelfDemoteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Step Down"), role: .destructive) {
                Task {
                    await workspace.selfDemoteSelectedGroupAdmin(advisory: session.accountScope?.groupChangeAdvisory)
                }
            }
            .disabled(workspace.hasInFlightGroupCommit)
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("You'll stay in the group, but another admin will need to restore your admin status."))
        }
        // The leave and local-delete confirmations are not declared here: both actions are also
        // offered from the sidebar row menu, and they share the one dialog installed by
        // `chatDestructiveActionsConfirmation()` in `ContentView` so each has a single wording.
    }
}
