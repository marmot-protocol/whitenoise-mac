//
//  GroupMembershipStatusSections.swift
//  whitenoise-mac
//
//  Where the reader stands in the group when that is not simply "a member": an invitation to
//  answer, or a membership that has ended.
//

import SwiftUI

struct GroupMembershipStatusSections: View {
    @Environment(WorkspaceState.self) private var workspace
    let snapshot: GroupDetailsSnapshot

    var body: some View {
        if snapshot.pendingConfirmation {
            Section(L10n.string("Invitation")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        L10n.string(
                            "Accept this invite to confirm membership, or decline it to remove the group from your chat list."
                        )
                    )
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    PendingInviteActionButtons(
                        accept: { await workspace.acceptSelectedGroupInvite() },
                        decline: { await workspace.declineSelectedGroupInvite() }
                    )
                }
            }
        }

        if let endedDescription = snapshot.selfMembership.endedDescription {
            Section(L10n.string("Membership")) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endedDescription)
                            .wnFont(.semiBold12)

                        Text(ChatSelfMembership.endedHistoryExplanation)
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: snapshot.selfMembership.endedSymbolName ?? "")
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
        }
    }
}
