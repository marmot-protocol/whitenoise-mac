//
//  GroupMembersSection.swift
//  whitenoise-mac
//
//  The roster in group info: Add members, a search once the group is large, the first six
//  people, and "See all" for the rest. Ported from the iOS client's `membersSection`.
//

import SwiftUI

struct GroupMembersSection: View {
    let members: [GroupMemberItem]
    let canInvite: Bool
    /// Whether to say why there is no Add row. Only a member who can't invite is owed it; a former
    /// member or a direct chat has no Add row for a different reason.
    var showsAdminOnlyNote = false
    let onAddMembers: () -> Void

    @State private var query = ""
    @State private var isExpanded = false

    var body: some View {
        let list = GroupMemberList(members: members, query: query, isExpanded: isExpanded)

        SettingsSection(
            title: L10n.plural("%lld members", Int64(members.count)),
            footer: showsAdminOnlyNote ? L10n.string("Only admins can add or manage members.") : nil
        ) {
            if canInvite {
                Button(action: onAddMembers) {
                    Label(L10n.string("Add members"), systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            if list.showsSearchField {
                MessagesSearchField(
                    text: $query,
                    accessibilityIdentifier: "group.details.members.search",
                    placeholder: L10n.string("Search members")
                )
            }

            if members.isEmpty {
                ContentUnavailableView(L10n.string("No members"), systemImage: "person.2.slash")
                    .frame(minHeight: 120)
            } else if list.visible.isEmpty {
                Text(L10n.string("No members match your search."))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            } else {
                ForEach(list.visible) { member in
                    GroupMemberRow(member: member)
                }
                if list.isTruncated {
                    Button {
                        isExpanded = true
                    } label: {
                        Text(L10n.plural("See all %lld members", Int64(list.matching.count)))
                            .wnFont(.semiBold12)
                            .foregroundStyle(WNColor.backgroundContentPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#Preview {
    let members = (1...9).map { index in
        GroupMemberItem(
            id: "member-\(index)",
            displayName: index == 1 ? "You" : "Member \(index)",
            publishedDisplayName: nil,
            npub: "npub1member\(index)",
            accountLabel: nil,
            isLocal: index == 1,
            isAdmin: index <= 2,
            isSelf: index == 1,
            canRemove: false,
            canPromote: false,
            canDemote: false
        )
    }

    Form {
        GroupMembersSection(members: members, canInvite: true, onAddMembers: {})
    }
    .formStyle(.grouped)
    .environment(WorkspaceState.preview())
    .frame(width: 480, height: 620)
}
