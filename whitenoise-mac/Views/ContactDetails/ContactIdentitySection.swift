//
//  ContactIdentitySection.swift
//  whitenoise-mac
//
//  The top of a contact's profile: avatar, name, npub, bio, then Follow and Message. Ported from
//  the iOS client's `ProfileIdentityHeader`.
//

import SwiftUI

/// The contact's identity on the pane's own background, in the same header-only section
/// `GroupDetailsIdentitySection` uses — see there for why a macOS grouped `Form` needs it.
///
/// The order is iOS's: a large avatar, the name, the published name under a nickname, the bio,
/// and the npub as a copyable capsule. The nickname is set, edited and removed from beside the
/// name it replaces rather than from a form row further down. iOS's Verified Nostr Address line is left out: checking
/// it means fetching the peer's own domain, which tells that domain who is looking.
struct ContactIdentitySection: View {
    let contact: NewChatRecipient
    /// One of this device's own accounts, which gets no Follow or Message.
    let isLocalProfile: Bool
    let isBlocked: Bool

    var body: some View {
        Section {
        } header: {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    GroupDetailsHero(
                        title: contact.title,
                        subtitle: publishedNameCaption,
                        description: contact.about ?? ""
                    ) {
                        ContactNicknameHeaderActions(accountIdHex: contact.accountIdHex)
                    } avatar: {
                        ProfileImageAvatarView(
                            seed: contact.accountIdHex,
                            initials: contact.title,
                            sanitizedPictureURL: contact.sanitizedPictureURL,
                            localImagePayload: contact.imagePayload,
                            isPeerProfileImage: !isLocalProfile,
                            size: MessagesLayout.groupDetailsAvatarSize,
                            isSelected: false
                        )
                    }

                    WNCopyCard(
                        displayText: DisplayText.short(publicKey, head: 14, tail: 4),
                        value: publicKey,
                        actionDescription: L10n.string("Copy npub"),
                        style: .pill
                    )
                }

                if !isLocalProfile {
                    if isBlocked {
                        BlockedContactNotice()
                    } else {
                        ContactProfileActionsRow(contact: contact)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)
        } footer: {
            Color.clear.frame(height: 1)
        }
    }

    /// A nickname replaces the name everywhere, so the header is where the published one has to
    /// stay readable — never let a private label pass for what they call themselves.
    private var publishedNameCaption: String? {
        contact.publishedDisplayName.map {
            String(format: L10n.string("Name from profile: %@"), PeerDisplayText.templateFragment($0))
        }
    }

    private var publicKey: String {
        contact.npub.isEmpty ? contact.accountIdHex : contact.npub
    }
}

#Preview("Contact with a bio") {
    Form {
        ContactIdentitySection(
            contact: NewChatRecipient(
                sourceQuery: "alice",
                memberRef: "npub1alice",
                accountIdHex: "a1ce",
                npub: "npub1a1cea1cea1cea1cea1cea1cea1cea1cea1cea1cea1cea1cea1cea1cea1ce",
                displayName: "Ali",
                publishedDisplayName: "Alice Cooper",
                pictureURL: nil,
                about: "Designer. Writes about type, color, and very small cameras."
            ),
            isLocalProfile: false,
            isBlocked: false
        )
    }
    .formStyle(.grouped)
    .frame(width: 460, height: 520)
    .environment(WorkspaceState.preview())
}

#Preview("Blocked") {
    Form {
        ContactIdentitySection(
            contact: NewChatRecipient(
                sourceQuery: "bob",
                memberRef: "npub1bob",
                accountIdHex: "b0b",
                npub: "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m",
                displayName: "Bob",
                pictureURL: nil
            ),
            isLocalProfile: false,
            isBlocked: true
        )
    }
    .formStyle(.grouped)
    .frame(width: 460, height: 420)
    .environment(WorkspaceState.preview())
}
