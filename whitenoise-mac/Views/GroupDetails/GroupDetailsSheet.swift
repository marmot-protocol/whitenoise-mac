//
//  GroupDetailsSheet.swift
//  whitenoise-mac
//
//  Group info: the pane that slides in over a conversation. Laid out after the iOS client's
//  `GroupDetailsView` — identity and quick actions, shared media, settings, people, advanced,
//  and the destructive actions last.
//

import MarmotKit
import SwiftUI

struct GroupDetailsSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.endingGroupIds) private var endingGroupIds
    @Environment(\.isBulkLeavingChats) private var isBulkLeavingChats
    @State private var isAddMembersPresented = false
    @State private var isProfileEditorPresented = false
    /// A direct chat's groups in common. Kept apart from the contact profile's list, which a
    /// member's profile sliding in over this pane clears again when it closes.
    @State private var groupsInCommon = GroupsInCommonViewModel()
    /// Hosted by the profile editor sheet, which is on top while its save runs.
    @State private var profileAdvisory = GroupChangeAdvisoryPrompter()
    let chat: ChatItem
    let conversationModel: ConversationViewModel
    let attachmentModel: AttachmentViewModel
    let safetyModel: GroupSafetyViewModel
    let disbandModel: GroupDisbandViewModel
    let accountDevicesModel: GroupAccountDevicesViewModel
    /// Whether the account blocked this account id hex, for the add-members sheet.
    let isBlocked: (String) -> Bool
    /// Opens in-conversation Find beside the inspector.
    var onSearchInChat: (() -> Void)? = nil
    /// Opens the spacious Shared Media library in the conversation content area.
    let onOpenSharedMediaLibrary: () -> Void
    /// Opens the full-size media viewer over the conversation content area.
    let onOpenSharedMediaViewer: (SharedMediaViewerPresentation) -> Void

    private var canModerate: Bool {
        !chat.isDirect && conversationModel.snapshot?.header.capabilities.isSelfAdmin == true
    }

    /// Each member's picture from what the app already holds: MDK's retained bytes from this
    /// conversation's transcript or a direct chat, then the profile URL resolved since the roster
    /// loaded. Read here rather than baked into the snapshot so pictures fill in while the pane is open.
    private func memberAvatars(for members: [GroupMemberItem]) -> [String: GroupMemberAvatar] {
        let payloads = ContactAvatarPayload.index(
            for: Set(members.map(\.id)),
            messages: workspace.messageTimelineStores[chat.id]?.messages ?? [],
            chats: workspace.activeChats
        )
        return Dictionary(
            members.map { member in
                let sanitizedPictureURL =
                    member.isSelf
                    ? workspace.activeAccount?.sanitizedPictureURL
                    : RemoteImageURLPolicy.sanitizedURL(
                        from: workspace.peerProfileFFICache[member.id]?.resolved.profilePicture)
                return (
                    member.id,
                    GroupMemberAvatar(imagePayload: payloads[member.id], sanitizedPictureURL: sanitizedPictureURL)
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func permissions(for snapshot: GroupDetailsSnapshot) -> GroupDetailsPermissions {
        GroupDetailsPermissions(
            snapshot: snapshot,
            capabilities: conversationModel.snapshot?.header.capabilities,
            isDirect: chat.isDirect
        )
    }

    private func directPeerAccountIdHex(in snapshot: GroupDetailsSnapshot) -> String? {
        guard chat.isDirect else { return nil }
        return GroupsInCommon.directPeerAccountIdHex(
            resolvedPeerAccountIdHex: chat.directPeerAccountIdHex,
            members: snapshot.members
        )
    }

    private func directPeerMember(in snapshot: GroupDetailsSnapshot) -> GroupMemberItem? {
        guard let peerHex = directPeerAccountIdHex(in: snapshot)?.lowercased() else { return nil }
        return snapshot.members.first { $0.id.lowercased() == peerHex }
    }

    private func presentProfileEditor(_ snapshot: GroupDetailsSnapshot) {
        // Start from what the group carries now, not from an edit abandoned last time.
        workspace.groupProfileDraftName = snapshot.customName ?? ""
        workspace.groupProfileDraftDescription = snapshot.description
        isProfileEditorPresented = true
    }

    private var hasProfileChanges: Bool {
        guard let snapshot = workspace.groupDetailsSnapshot else { return false }
        return workspace.groupProfileDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
            != (snapshot.customName ?? "")
            || workspace.groupProfileDraftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                != snapshot.description
    }

    private var isGroupCommitInFlight: Bool {
        GroupCommitGuard.isInFlight(
            workspace: workspace, endingGroupIds: endingGroupIds, isBulkLeavingChats: isBulkLeavingChats)
    }

    private func invalidateEditors() {
        isAddMembersPresented = false
        isProfileEditorPresented = false
        profileAdvisory.cancelPending()
    }

    var body: some View {
        @Bindable var workspace = workspace
        let snapshot = workspace.groupDetailsSnapshot
        let permissions = snapshot.map(permissions(for:))

        VStack(spacing: 0) {
            if let snapshot, let permissions {
                Form {
                    // 1. Identity & compact supported actions
                    GroupDetailsIdentitySection(
                        chat: chat,
                        snapshot: snapshot,
                        permissions: permissions,
                        onEditProfile: { presentProfileEditor(snapshot) },
                        onSearchInChat: onSearchInChat
                    )

                    // Actionable status stays near identity, never buried below members.
                    GroupRecoverySection(model: safetyModel)
                    GroupModerationSection(
                        model: safetyModel,
                        canModerate: canModerate,
                        onForgotten: { workspace.closeGroupDetails() }
                    )
                    GroupMembershipStatusSections(snapshot: snapshot)
                    GroupDisbandStatusSection(
                        status: disbandModel.reconciled(snapshot.disband).status,
                        isDismissing: disbandModel.isDismissingFailure,
                        onDismiss: {
                            Task {
                                await disbandModel.dismissFailure()
                                await workspace.reloadSelectedGroupDetails()
                            }
                        }
                    )

                    // Direct-chat person / About / contact actions — distinct from Chat Actions.
                    if let contactAccountIdHex = chat.directPeerAccountIdHex {
                        let peer = directPeerMember(in: snapshot)
                        let aboutText = workspace.peerProfileFFICache[contactAccountIdHex]?.resolved.profileAbout?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        Section(L10n.string("Contact")) {
                            if let aboutText, !aboutText.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.string("About"))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Text(aboutText)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if let peer, !peer.npub.isEmpty {
                                GroupDiagnosticsValueRow(
                                    title: L10n.string("Public Key"),
                                    value: peer.npub,
                                    lineLimit: 1
                                )
                            }
                            ContactNicknameRow(
                                accountIdHex: contactAccountIdHex, publishedName: chat.publishedTitle)
                            ContactFollowControl(accountIdHex: contactAccountIdHex)
                        }
                    }
                    if let peerAccountIdHex = directPeerAccountIdHex(in: snapshot) {
                        GroupsInCommonSection(
                            groups: groupsInCommon.groups,
                            isLoading: groupsInCommon.isLoading,
                            hadFailures: groupsInCommon.hadFailures,
                            onOpen: { workspace.openCommonGroup($0) }
                        )
                        .task(id: peerAccountIdHex) {
                            await groupsInCommon.load(
                                contactIdHex: peerAccountIdHex,
                                excludingGroupIdHex: chat.id,
                                from: .workspace(workspace)
                            )
                        }
                    }

                    // 3. Shared content
                    RetainedSharedMediaSection(
                        model: attachmentModel,
                        onOpenLibrary: onOpenSharedMediaLibrary,
                        onOpenMedia: onOpenSharedMediaViewer
                    )

                    // 4. Chat settings (Chat Actions on direct chats; Settings on groups)
                    GroupDetailsSettingsSection(
                        isDirect: chat.isDirect,
                        snapshot: snapshot,
                        permissions: permissions
                    )

                    // 5. Members
                    GroupMembersSection(
                        members: snapshot.members,
                        avatars: memberAvatars(for: snapshot.members),
                        canInvite: permissions.canInvite,
                        showsAdminOnlyNote: permissions.showsAdminOnlyNote,
                        onAddMembers: { isAddMembersPresented = true }
                    )
                    .disabled(isGroupCommitInFlight)

                    // 6. Advanced information
                    GroupLinkedDevicesSection(model: accountDevicesModel)
                        .disabled(isGroupCommitInFlight)
                        .task(id: snapshot.groupIdHex) { await accountDevicesModel.load() }
                    GroupDetailsAdvancedSection(relays: snapshot.relays, groupIdHex: snapshot.groupIdHex)
                    if workspace.developerMode {
                        GroupDeveloperSection(
                            snapshot: snapshot, epoch: conversationModel.snapshot?.header.epoch)
                    }

                    // 7. Destructive actions (terminal section)
                    GroupDetailsLeaveSection(
                        chat: chat, snapshot: snapshot, conversationModel: conversationModel,
                        disbandModel: disbandModel)

                    SettingsErrorView(error: workspace.lastError)
                }
                .formStyle(.grouped)
            } else if workspace.isLoadingGroupDetails {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    L10n.string("Group details unavailable"),
                    systemImage: "person.2"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    SettingsErrorView(error: workspace.lastError)
                        .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: chat.id) { _, _ in
            invalidateEditors()
        }
        .onChange(of: workspace.activeAccountId) { _, _ in
            invalidateEditors()
        }
        .task(id: "\(chat.id):\(canModerate)") {
            await safetyModel.load(canModerate: canModerate)
        }
        .sheet(isPresented: $isAddMembersPresented) {
            GroupAddMembersSheet(
                existingMemberIds: Set(workspace.groupDetailsSnapshot?.members.map(\.id) ?? []),
                isBlocked: isBlocked
            )
            .environment(\.locale, workspace.preferredLocale)
            .environment(\.endingGroupIds, endingGroupIds)
            .environment(\.isBulkLeavingChats, isBulkLeavingChats)
        }
        .sheet(isPresented: $isProfileEditorPresented) {
            GroupProfileEditorSheet(
                name: $workspace.groupProfileDraftName,
                description: $workspace.groupProfileDraftDescription,
                isSaving: workspace.isSavingGroupProfile,
                canSave: hasProfileChanges && !isGroupCommitInFlight,
                error: workspace.lastError,
                onSave: {
                    await workspace.saveGroupProfile(advisory: profileAdvisory)
                    return workspace.lastError == nil
                }
            )
            .groupChangeAdvisoryAlert(profileAdvisory)
            .onDisappear { profileAdvisory.cancelPending() }
            // Sheets are hosted outside this view's hierarchy and inherit nothing from it, so
            // the app-language locale has to be handed over again.
            .environment(\.locale, workspace.preferredLocale)
        }
    }
}
