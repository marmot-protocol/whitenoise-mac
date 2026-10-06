//
//  GroupDetailsIdentitySection.swift
//  whitenoise-mac
//
//  The top of group info: the hero and the quick-action row beneath it.
//

import SwiftUI

/// The hero and the quick actions, on the pane's own background rather than in a card — the
/// clear row iOS gives them.
///
/// A macOS grouped `Form` ignores `listRowBackground`, so a row always draws a card. They go in
/// an empty section's *header* instead, which draws none. The empty footer is load-bearing: a
/// section with no content and no footer lets the next section's header collapse into the small
/// grey footer style, so "Settings" read as a caption under the quick actions.
struct GroupDetailsIdentitySection: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem
    let snapshot: GroupDetailsSnapshot
    let permissions: GroupDetailsPermissions
    let onEditProfile: () -> Void
    let onAddMembers: () -> Void

    var body: some View {
        Section {
        } header: {
            VStack(spacing: 16) {
                GroupDetailsHero(
                    title: snapshot.name,
                    subtitle: subtitle,
                    description: snapshot.description,
                    onEditProfile: permissions.canEditProfile ? onEditProfile : nil,
                    onEditImage: permissions.canEditProfile ? { presentGroupImagePicker() } : nil
                ) {
                    ProfileImageAvatarView(
                        seed: chat.avatarSeed,
                        initials: chat.title,
                        sanitizedPictureURL: GroupDetailsHeaderAvatar.sanitizedURL(snapshot: snapshot, fallback: chat),
                        localImagePayload: chat.groupImagePayload,
                        isPeerProfileImage: chat.isDirect,
                        size: MessagesLayout.groupDetailsAvatarSize,
                        isSelected: false
                    )
                }
                .disabled(workspace.hasInFlightGroupCommit)

                GroupDetailsQuickActionsRow(
                    chat: chat,
                    snapshot: snapshot,
                    permissions: permissions,
                    onAddMembers: onAddMembers
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
        } footer: {
            Color.clear.frame(height: 1)
        }
    }

    private var subtitle: String {
        chat.isDirect
            ? L10n.string("Direct message")
            : L10n.plural("Group · %lld members", Int64(snapshot.members.count))
    }

    private func presentGroupImagePicker() {
        workspace.closeGroupDetails()
        workspace.showGroupImagePicker(for: chat)
    }
}
