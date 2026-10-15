//
//  GroupsInCommonSection.swift
//  whitenoise-mac
//
//  The groups you share with a contact, each opening that group. Shown on a contact's profile
//  and in a direct chat's info.
//

import SwiftUI

struct GroupsInCommonSection: View {
    let groups: [ChatItem]
    let isLoading: Bool
    let hadFailures: Bool
    let onOpen: (ChatItem) -> Void

    var body: some View {
        Section(L10n.string("Groups in Common")) {
            if isLoading && groups.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("Checking shared groups…"))
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            } else if groups.isEmpty {
                Label(L10n.string("No groups in common"), systemImage: "person.2.slash")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            } else {
                ForEach(groups) { commonGroup in
                    Button {
                        onOpen(commonGroup)
                    } label: {
                        HStack(spacing: 10) {
                            ProfileImageAvatarView(
                                seed: commonGroup.avatarSeed,
                                initials: commonGroup.title,
                                sanitizedPictureURL: commonGroup.sanitizedPictureURL,
                                localImagePayload: commonGroup.groupImagePayload,
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

            if hadFailures {
                Text(L10n.string("Some groups could not be checked."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
    }
}

#Preview {
    Form {
        GroupsInCommonSection(
            groups: [
                ChatItem(
                    id: "book-club",
                    title: "Book club",
                    subtitle: "Book club",
                    preview: "",
                    updatedAt: nil,
                    avatarSeed: "book-club",
                    pictureURL: nil,
                    unreadCount: 0
                )
            ],
            isLoading: false,
            hadFailures: true,
            onOpen: { _ in }
        )
        GroupsInCommonSection(groups: [], isLoading: true, hadFailures: false, onOpen: { _ in })
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 320)
}
