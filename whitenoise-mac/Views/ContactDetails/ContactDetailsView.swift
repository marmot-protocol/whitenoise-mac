//
//  ContactDetailsView.swift
//  whitenoise-mac
//
//  A contact's profile: the pane that slides in over a conversation or group info. Laid out after
//  the iOS client's `ProfileContentView` — identity and actions, then shared groups and blocking.
//

import SwiftUI

struct ContactDetailsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SessionState.self) private var session
    let contact: NewChatRecipient
    let blockedUsersModel: BlockedUsersViewModel

    private var isLocalProfile: Bool {
        workspace.accounts.contains {
            $0.accountIdHex.lowercased() == contact.accountIdHex.lowercased()
        }
    }

    /// This person's place in the group whose info the profile was opened over. The contact pane
    /// slides in on top of group info, so while group info is open, a profile that is in its
    /// roster was reached from it; anywhere else the profile carries no group commands.
    private var groupMember: GroupMemberItem? {
        guard workspace.isGroupDetailsPresented else { return nil }
        return ContactGroupAction.member(accountIdHex: contact.accountIdHex, in: workspace.groupDetailsSnapshot)
    }

    /// See `ContactGroupAction.closesProfile` for when the profile goes back to group info.
    private func removeFromGroup(_ member: GroupMemberItem) async {
        await workspace.removeGroupMember(member, advisory: session.accountScope?.groupChangeAdvisory)
        if ContactGroupAction.closesProfile(
            afterRemoving: contact.accountIdHex,
            openProfileAccountIdHex: workspace.contactDetailsTarget?.accountIdHex,
            in: workspace.groupDetailsSnapshot
        ) {
            workspace.closeContactDetails()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GroupDetailsTopBar(
                title: L10n.string("Profile"),
                isLoading: workspace.isLoadingContactDetails,
                backHelp: "Back",
                onBack: { workspace.closeContactDetails() },
                onEdit: nil
            )

            GlassSeparator(axis: .horizontal)

            Form {
                ContactIdentitySection(
                    contact: contact,
                    isLocalProfile: isLocalProfile,
                    isBlocked: blockedUsersModel.isBlocked(accountID: contact.accountIdHex)
                )

                if workspace.lastError != nil {
                    Section {
                        SettingsErrorView(error: workspace.lastError)
                    }
                }

                GroupsInCommonSection(
                    groups: workspace.commonGroupsForContact,
                    isLoading: workspace.isLoadingCommonGroups,
                    hadFailures: workspace.commonGroupsLoadHadFailures,
                    onOpen: { workspace.openCommonGroup($0) }
                )

                if !isLocalProfile {
                    ContactBlockingSection(model: blockedUsersModel, accountID: contact.accountIdHex)
                }

                if let groupMember {
                    ContactGroupActionsSection(
                        member: groupMember,
                        isBusy: workspace.hasInFlightGroupCommit,
                        isMutating: workspace.mutatingGroupMemberId == groupMember.id,
                        onPromote: {
                            Task {
                                await workspace.promoteGroupMember(
                                    groupMember, advisory: session.accountScope?.groupChangeAdvisory)
                            }
                        },
                        onDemote: {
                            Task {
                                await workspace.demoteGroupMember(
                                    groupMember, advisory: session.accountScope?.groupChangeAdvisory)
                            }
                        },
                        onRemove: { Task { await removeFromGroup(groupMember) } }
                    )
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}
