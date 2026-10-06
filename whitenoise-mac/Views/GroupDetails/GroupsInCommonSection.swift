//
//  GroupsInCommonSection.swift
//  whitenoise-mac
//
//  The groups you share with a contact, each opening that group. Shown on a contact's profile
//  and in a direct chat's info.
//

import SwiftUI

struct GroupsInCommonSection: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        Section(L10n.string("Groups in Common")) {
            if workspace.isLoadingCommonGroups
                && workspace.commonGroupsForContact.isEmpty
            {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("Checking shared groups…"))
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            } else if workspace.commonGroupsForContact.isEmpty {
                Label(L10n.string("No groups in common"), systemImage: "person.2.slash")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            } else {
                ForEach(workspace.commonGroupsForContact) { commonGroup in
                    Button {
                        workspace.openCommonGroup(commonGroup)
                    } label: {
                        HStack(spacing: 10) {
                            ProfileImageAvatarView(
                                seed: commonGroup.avatarSeed,
                                initials: commonGroup.title,
                                sanitizedPictureURL: commonGroup.sanitizedPictureURL,
                                localImagePayload: commonGroup.groupImagePayload,
                                isPeerProfileImage: commonGroup.isDirect,
                                size: 34,
                                isSelected: false
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commonGroup.title)
                                    .wnFont(.semiBold12)
                                    .foregroundStyle(WNColor.backgroundContentPrimary)
                                    .lineLimit(1)
                                Text(commonGroup.subtitle)
                                    .wnFont(.medium10)
                                    .foregroundStyle(WNColor.backgroundContentSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .wnFont(.semiBold10)
                                .foregroundStyle(WNColor.backgroundContentTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if workspace.commonGroupsLoadHadFailures {
                Text(L10n.string("Some groups could not be checked."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
    }
}
