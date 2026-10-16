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
    @State private var isAddMembersPresented = false
    @State private var isProfileEditorPresented = false
    /// The shared-media library, pushed over the details the way iOS pushes it.
    @State private var isMediaLibraryPresented = false
    /// The full-pane photo/video viewer, over either the details or the library.
    @State private var mediaViewer: SharedMediaViewerPresentation?
    /// A direct chat's groups in common. Kept apart from the contact profile's list, which a
    /// member's profile sliding in over this pane clears again when it closes.
    @State private var groupsInCommon = GroupsInCommonViewModel()
    let chat: ChatItem
    let conversationModel: ConversationViewModel
    let attachmentModel: AttachmentViewModel
    let safetyModel: GroupSafetyViewModel

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

    var body: some View {
        @Bindable var workspace = workspace
        let snapshot = workspace.groupDetailsSnapshot
        let permissions = snapshot.map(permissions(for:))

        VStack(spacing: 0) {
            if isMediaLibraryPresented {
                SharedMediaLibraryView(
                    model: attachmentModel,
                    onBack: { isMediaLibraryPresented = false },
                    onOpenMedia: { mediaViewer = $0 }
                )
            } else {
                GroupDetailsTopBar(
                    title: L10n.string(chat.isDirect ? "Chat Info" : "Group Info"),
                    isLoading: workspace.isLoadingGroupDetails,
                    onBack: { workspace.closeGroupDetails() },
                    onEdit: snapshot.flatMap { snapshot in
                        permissions?.canEditProfile == true ? { presentProfileEditor(snapshot) } : nil
                    }
                )
                .disabled(workspace.hasInFlightGroupCommit)

                GlassSeparator(axis: .horizontal)

                if let snapshot, let permissions {
                    Form {
                        GroupDetailsIdentitySection(
                            chat: chat,
                            snapshot: snapshot,
                            permissions: permissions,
                            onEditProfile: { presentProfileEditor(snapshot) },
                            onAddMembers: { isAddMembersPresented = true }
                        )

                        GroupRecoverySection(model: safetyModel)
                        GroupModerationSection(
                            model: safetyModel,
                            canModerate: canModerate,
                            onForgotten: { workspace.closeGroupDetails() }
                        )
                        GroupMembershipStatusSections(snapshot: snapshot)

                        if let contactAccountIdHex = chat.directPeerAccountIdHex {
                            Section(L10n.string("Contact")) {
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

                        RetainedSharedMediaSection(
                            model: attachmentModel,
                            onOpenLibrary: { isMediaLibraryPresented = true },
                            onOpenMedia: { mediaViewer = $0 }
                        )
                        GroupDetailsSettingsSection(snapshot: snapshot, permissions: permissions)

                        GroupMembersSection(
                            members: snapshot.members,
                            avatars: memberAvatars(for: snapshot.members),
                            canInvite: permissions.canInvite,
                            showsAdminOnlyNote: permissions.showsAdminOnlyNote,
                            onAddMembers: { isAddMembersPresented = true }
                        )
                        .disabled(workspace.hasInFlightGroupCommit)

                        GroupDetailsAdvancedSection(relays: snapshot.relays, groupIdHex: snapshot.groupIdHex)
                        GroupDetailsLeaveSection(chat: chat, snapshot: snapshot)

                        if workspace.developerMode {
                            GroupDeveloperSection(
                                snapshot: snapshot, epoch: conversationModel.snapshot?.header.epoch)
                        }

                        SettingsErrorView(error: workspace.lastError)
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                } else if workspace.isLoadingGroupDetails {
                    ProgressView()
                        .controlSize(.regular)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Group details unavailable", systemImage: "person.2")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            SettingsErrorView(error: workspace.lastError)
                                .padding()
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            MessagesTranscriptBackground()
        }
        .overlay {
            if let mediaViewer {
                SharedMediaViewerOverlay(presentation: mediaViewer, model: attachmentModel) {
                    self.mediaViewer = nil
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.18), value: mediaViewer?.id)
        .onChange(of: chat.id) {
            isMediaLibraryPresented = false
            mediaViewer = nil
        }
        .task(id: "\(chat.id):\(canModerate)") {
            await safetyModel.load(canModerate: canModerate)
        }
        .sheet(isPresented: $isAddMembersPresented) {
            GroupAddMembersSheet(
                existingMemberIds: Set(workspace.groupDetailsSnapshot?.members.map(\.id) ?? [])
            )
            .environment(\.locale, workspace.preferredLocale)
        }
        .sheet(isPresented: $isProfileEditorPresented) {
            GroupProfileEditorSheet(
                name: $workspace.groupProfileDraftName,
                description: $workspace.groupProfileDraftDescription,
                isSaving: workspace.isSavingGroupProfile,
                canSave: hasProfileChanges && !workspace.hasInFlightGroupCommit,
                error: workspace.lastError,
                onSave: {
                    await workspace.saveGroupProfile()
                    return workspace.lastError == nil
                }
            )
            // Sheets are hosted outside this view's hierarchy and inherit nothing from it, so
            // the app-language locale has to be handed over again.
            .environment(\.locale, workspace.preferredLocale)
        }
    }
}
