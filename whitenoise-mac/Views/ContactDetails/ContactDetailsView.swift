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
    @Environment(\.endingGroupIds) private var endingGroupIds
    @Environment(\.isBulkLeavingChats) private var isBulkLeavingChats
    @Environment(SessionState.self) private var session
    let contact: NewChatRecipient
    let blockedUsersModel: BlockedUsersViewModel
    /// True when opened by drilling down from Group Info inside the inspector, so the leading
    /// control explicitly returns to Group Info rather than closing the inspector.
    var returnsToGroupInfo = false

    private var isLocalProfile: Bool {
        workspace.accounts.contains {
            $0.accountIdHex.lowercased() == contact.accountIdHex.lowercased()
        }
    }

    /// This person's place in the group whose info the profile was opened over.
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

    private var isGroupCommitInFlight: Bool {
        GroupCommitGuard.isInFlight(
            workspace: workspace, endingGroupIds: endingGroupIds, isBulkLeavingChats: isBulkLeavingChats)
    }

    var body: some View {
        VStack(spacing: 0) {
            GroupDetailsTopBar(
                title: L10n.string("Profile"),
                isLoading: workspace.isLoadingContactDetails,
                backHelp: returnsToGroupInfo ? "Back" : "Close",
                backSymbol: returnsToGroupInfo ? "chevron.backward" : "xmark",
                onBack: { workspace.closeContactDetails() },
                onEdit: nil
            )

            Divider()

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
                    ContactBlockingSection(
                        model: blockedUsersModel,
                        accountID: contact.accountIdHex,
                        reporter: session.accountScope?.moderationReporter
                    )
                }

                if let groupMember {
                    ContactGroupActionsSection(
                        member: groupMember,
                        isBusy: isGroupCommitInFlight,
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
        }
    }
}

#Preview("Contact inspector") {
    let workspace = WorkspaceState.preview()
    ContactDetailsView(
        contact: NewChatRecipient(
            sourceQuery: "alice",
            memberRef: "npub1alice",
            accountIdHex: "a1ce",
            npub: "npub1a1cea1cea1cea1cea1cea1cea1cea1cea1cea1cea1cea1cea1cea1cea1ce",
            displayName: "Alice",
            pictureURL: nil,
            about: "Product designer."
        ),
        blockedUsersModel: BlockedUsersViewModel(
            accountRef: "preview",
            runtime: FakeMarmotRuntime(accounts: [], storageRootPath: NSTemporaryDirectory())
        ),
        returnsToGroupInfo: true
    )
    .environment(workspace)
    .environment(SessionState())
    .frame(width: 320, height: 540)
}
