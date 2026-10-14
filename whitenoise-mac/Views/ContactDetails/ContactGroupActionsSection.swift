//
//  ContactGroupActionsSection.swift
//  whitenoise-mac
//
//  "Group Actions" at the foot of a member's profile opened from group info: Make Admin, Remove
//  Admin, Remove from Group. Ported from the iOS client's `ProfileContentView.moderationSection`.
//

import SwiftUI

/// The group commands a member's profile offers. Each one is the core's own verdict for this
/// member (`canPromote` / `canDemote` / `canRemove`), so an ordinary member sees none of them.
enum ContactGroupAction: Equatable {
    case promote
    case demote
    case remove

    /// Your own row has no commands here: stepping down as admin lives with Leave in group info,
    /// as it does on iOS, so `canDemote` on yourself is not offered from a profile.
    static func actions(for member: GroupMemberItem) -> [ContactGroupAction] {
        guard !member.isSelf else { return [] }
        var actions: [ContactGroupAction] = []
        if member.canPromote { actions.append(.promote) }
        if member.canDemote { actions.append(.demote) }
        if member.canRemove { actions.append(.remove) }
        return actions
    }

    /// The roster entry for the profile on screen, read from the live group details rather than
    /// captured when the profile opened, so a promotion made from here relabels it in place.
    static func member(accountIdHex: String, in snapshot: GroupDetailsSnapshot?) -> GroupMemberItem? {
        let accountIdHex = accountIdHex.lowercased()
        return snapshot?.members.first { $0.id.lowercased() == accountIdHex }
    }
}

struct ContactGroupActionsSection: View {
    let member: GroupMemberItem
    let isBusy: Bool
    let isMutating: Bool
    let onPromote: () -> Void
    let onDemote: () -> Void
    let onRemove: () -> Void

    @State private var isConfirmingRemoval = false

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
                        isInProgress: isMutating,
                        action: onPromote
                    )
                    .disabled(isBusy)
                }

                if actions.contains(.demote) {
                    ContactGroupActionRow(
                        title: L10n.string("Remove Admin"),
                        systemImage: "star.slash",
                        isInProgress: isMutating,
                        action: onDemote
                    )
                    .disabled(isBusy)
                }

                if actions.contains(.remove) {
                    DetailsDestructiveRow(
                        title: L10n.string("Remove from Group"),
                        systemImage: "minus.circle"
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
                Button(L10n.string("Remove from Group"), role: .destructive, action: onRemove)
                    .disabled(isBusy)
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("They'll stop receiving new messages in this group."))
            }
        }
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
