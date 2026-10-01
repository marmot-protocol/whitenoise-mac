//
//  GroupDetailsHero.swift
//  whitenoise-mac
//
//  The identity block that opens group info: a large avatar, the name, one line of context,
//  and the description. Ported from the iOS client's `groupIdentitySection`.
//

import SwiftUI

/// The centred identity block at the top of group info, and of a contact's profile.
///
/// It draws no avatar of its own: the caller hands one in, so this view depends on nothing but
/// the values it is given and the avatar keeps whatever image policy its own view enforces.
/// An empty description is offered to admins as "Add Description" — the empty state of the
/// field is where the edit belongs, as on iOS — and to everyone else draws nothing at all.
struct GroupDetailsHero<Avatar: View, TitleAccessory: View>: View {
    let title: String
    /// One line of context under the name; `nil` draws none.
    let subtitle: String?
    let description: String
    /// Set when the reader may edit the group's name and description.
    var onEditProfile: (() -> Void)?
    /// Set when the reader may change the group image; the avatar becomes its button.
    var onEditImage: (() -> Void)?
    /// Controls drawn after the name, on its first line — a contact's nickname actions.
    let titleAccessory: TitleAccessory
    let avatar: Avatar

    init(
        title: String,
        subtitle: String?,
        description: String,
        onEditProfile: (() -> Void)? = nil,
        onEditImage: (() -> Void)? = nil,
        @ViewBuilder titleAccessory: () -> TitleAccessory,
        @ViewBuilder avatar: () -> Avatar
    ) {
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.onEditProfile = onEditProfile
        self.onEditImage = onEditImage
        self.titleAccessory = titleAccessory()
        self.avatar = avatar()
    }

    var body: some View {
        VStack(spacing: 10) {
            if let onEditImage {
                Button(action: onEditImage) {
                    avatar
                }
                .buttonStyle(.plain)
                .help(L10n.string("Set group image"))
                .accessibilityLabel(L10n.string("Set group image"))
            } else {
                avatar
            }

            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .wnFont(.semiBold20)
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    titleAccessory
                }

                if let subtitle {
                    Text(subtitle)
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .multilineTextAlignment(.center)
                }
            }

            if !description.isEmpty {
                Text(description)
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let onEditProfile {
                // Not `.link`: that is system blue, and blue is reserved for the unread badge.
                Button(L10n.string("Add Description"), action: onEditProfile)
                    .buttonStyle(.wnSecondary)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

extension GroupDetailsHero where TitleAccessory == EmptyView {
    init(
        title: String,
        subtitle: String?,
        description: String,
        onEditProfile: (() -> Void)? = nil,
        onEditImage: (() -> Void)? = nil,
        @ViewBuilder avatar: () -> Avatar
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            description: description,
            onEditProfile: onEditProfile,
            onEditImage: onEditImage,
            titleAccessory: { EmptyView() },
            avatar: avatar
        )
    }
}

#Preview("Member") {
    GroupDetailsHero(
        title: "Design Crew",
        subtitle: "Group · 8 members",
        description: "Where the mockups go to be argued about."
    ) {
        AvatarView(
            seed: "design-crew", initials: "Design Crew", size: MessagesLayout.groupDetailsAvatarSize, isSelected: false
        )
    }
    .padding()
    .frame(width: 420)
}

#Preview("Admin, no description") {
    GroupDetailsHero(
        title: "Design Crew",
        subtitle: "Group · 8 members",
        description: "",
        onEditProfile: {},
        onEditImage: {}
    ) {
        AvatarView(
            seed: "design-crew", initials: "Design Crew", size: MessagesLayout.groupDetailsAvatarSize, isSelected: false
        )
    }
    .padding()
    .frame(width: 420)
}
