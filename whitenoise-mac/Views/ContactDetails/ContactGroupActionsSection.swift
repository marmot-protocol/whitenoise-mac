//
//  ContactGroupActionsSection.swift
//  whitenoise-mac
//
//  "Group Actions" at the foot of a member's profile opened from group info: Make Admin, Remove
//  Admin, Remove from Group. Ported from the iOS client's `ProfileContentView.moderationSection`.
//

import SwiftUI

struct ContactGroupActionsSection: View {
    let member: GroupMemberItem
    let isBusy: Bool
    let isMutating: Bool
    let onPromote: () -> Void
    let onDemote: () -> Void
    let onRemove: () -> Void

    @State private var isConfirmingRemoval = false
    /// The command this section started, so the spinner lands on its row: `isMutating` only says
    /// that *some* commit for this member is running, and a removal sets it too.
    @State private var pendingAction: ContactGroupAction?

    var body: some View {
        let actions = ContactGroupAction.actions(for: member)
        if !actions.isEmpty {
            SettingsSection(
                title: L10n.string("Group Actions"),
                footer: member.isAdmin ? L10n.string("This person is a group admin.") : nil
            ) {
                if actions.contains(.promote) {
                    ContactGroupActionRow(
                        title: L10n.string("Make Admin"),
                        systemImage: "star",
                        isInProgress: isMutating && pendingAction == .promote,
                        action: { start(.promote, onPromote) }
                    )
                    .disabled(isBusy)
                }

                if actions.contains(.demote) {
                    ContactGroupActionRow(
                        title: L10n.string("Remove Admin"),
                        systemImage: "star.slash",
                        isInProgress: isMutating && pendingAction == .demote,
                        action: { start(.demote, onDemote) }
                    )
                    .disabled(isBusy)
                }

                if actions.contains(.remove) {
                    DetailsDestructiveRow(
                        title: L10n.string("Remove from Group"),
                        systemImage: "minus.circle",
                        isInProgress: isMutating && pendingAction == .remove
                    ) {
                        isConfirmingRemoval = true
                    }
                    .disabled(isBusy)
                }
            }
            .confirmationDialog(
                L10n.string("Remove this member?"),
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button(L10n.string("Remove from Group"), role: .destructive) {
                    start(.remove, onRemove)
                }
                .disabled(isBusy)
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: {
                Text(
                    String(
                        format: L10n.string("This removes %@ from the group."),
                        PeerDisplayText.templateFragment(member.displayName)))
            }
            .onChange(of: isMutating) { _, isMutating in
                if !isMutating { pendingAction = nil }
            }
        }
    }

    private func start(_ action: ContactGroupAction, _ perform: () -> Void) {
        pendingAction = action
        perform()
    }
}

/// A role change drawn as a plain form row, the way `GroupMembersSection` draws Add members.
private struct ContactGroupActionRow: View {
    let title: String
    let systemImage: String
    let isInProgress: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 0)
                if isInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let member = { (isAdmin: Bool) in
        GroupMemberItem(
            id: isAdmin ? "admin" : "member",
            displayName: isAdmin ? "Alice" : "Bob",
            publishedDisplayName: nil,
            profileName: isAdmin ? "Alice" : "Bob",
            npub: "npub1example",
            accountLabel: nil,
            isLocal: false,
            isAdmin: isAdmin,
            isSelf: false,
            canRemove: true,
            canPromote: !isAdmin,
            canDemote: isAdmin
        )
    }

    Form {
        ContactGroupActionsSection(
            member: member(false), isBusy: false, isMutating: false,
            onPromote: {}, onDemote: {}, onRemove: {}
        )
        ContactGroupActionsSection(
            member: member(true), isBusy: true, isMutating: true,
            onPromote: {}, onDemote: {}, onRemove: {}
        )
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 360)
}
