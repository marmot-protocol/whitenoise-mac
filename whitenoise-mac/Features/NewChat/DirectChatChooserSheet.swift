//
//  DirectChatChooserSheet.swift
//  whitenoise-mac
//
//  Asks, when someone already has a direct chat with the viewer, whether to continue one of them
//  or start another — the chooser the iOS app shows for the same pick.
//

import SwiftUI

struct DirectChatChooserSheet: View {
    let presentation: DirectChatChooserPresentation
    let onOpen: (DirectChatChoice) -> Void
    let onStartNew: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DirectChatChooserHeader(recipientName: presentation.recipient.title, onClose: onCancel)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(presentation.choices) { choice in
                        DirectChatChoiceRow(
                            choice: choice,
                            avatarSeed: presentation.recipient.accountIdHex
                        ) {
                            onOpen(choice)
                        }
                        .accessibilityIdentifier("compose.chooser.chat.\(choice.id)")
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)

            DirectChatChooserFooter(onStartNew: onStartNew)
        }
        .frame(width: 400)
        .wnButtonShape(.capsule)
    }
}

private struct DirectChatChooserHeader: View {
    let recipientName: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    String(
                        format: L10n.string("Conversations with %@"),
                        PeerDisplayText.templateFragment(recipientName)
                    )
                )
                .wnFont(.semiBold16)
                .lineLimit(1)
                Text(L10n.string("Choose a conversation to continue, or start a new one."))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // The sheet's only dismissal, so it also answers Escape.
            GlassCircleCloseButton(appearance: .outline, action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

/// One existing chat. Every direct chat with the same person carries the same title, so what
/// tells them apart is the last message and when it was sent.
private struct DirectChatChoiceRow: View {
    let choice: DirectChatChoice
    let avatarSeed: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProfileImageAvatarView(
                    seed: avatarSeed,
                    initials: choice.chat.title,
                    sanitizedPictureURL: choice.chat.sanitizedPictureURL,
                    localImagePayload: choice.chat.groupImagePayload,
                    size: 36,
                    isSelected: false
                )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(choice.chat.title)
                            .wnFont(MessagesType.rowLabel)
                            .lineLimit(1)
                        if choice.isArchived {
                            Image(systemName: "archivebox")
                                .wnFont(.medium10)
                                .foregroundStyle(WNColor.backgroundContentTertiary)
                                .accessibilityLabel(L10n.string("Archived"))
                        }
                        Spacer(minLength: 4)
                        Text(choice.chat.timestampLabel)
                            .wnFont(MessagesType.meta)
                            .foregroundStyle(WNColor.backgroundContentTertiary)
                    }
                    Text(choice.chat.previewNotice() ?? choice.chat.preview)
                        .wnFont(MessagesType.meta)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Dismissal lives on the header's close button alone; starting another chat is the secondary
/// tier, since continuing an existing conversation is the pick this sheet leads with.
private struct DirectChatChooserFooter: View {
    let onStartNew: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer()

            Button(L10n.string("Start new conversation"), action: onStartNew)
                .buttonStyle(.wnSecondary)
                .accessibilityIdentifier("compose.chooser.startNew")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }
}

#Preview("Two existing chats") {
    let peer = String(repeating: "b", count: 64)
    DirectChatChooserSheet(
        presentation: DirectChatChooserPresentation(
            recipient: NewChatRecipient(
                sourceQuery: "",
                memberRef: peer,
                accountIdHex: peer,
                npub: "npub1preview",
                displayName: "Bob",
                pictureURL: nil
            ),
            choices: [
                DirectChatChoice(
                    chat: ChatItem(
                        id: "recent",
                        title: "Bob",
                        subtitle: "",
                        preview: "See you tomorrow",
                        updatedAt: .now,
                        avatarSeed: peer,
                        pictureURL: nil,
                        unreadCount: 0,
                        isDirect: true
                    ),
                    isArchived: false
                ),
                DirectChatChoice(
                    chat: ChatItem(
                        id: "older",
                        title: "Bob",
                        subtitle: "",
                        preview: "",
                        updatedAt: .now.addingTimeInterval(-86_400 * 30),
                        avatarSeed: peer,
                        pictureURL: nil,
                        unreadCount: 0,
                        isDirect: true
                    ),
                    isArchived: true
                ),
            ]
        ),
        onOpen: { _ in },
        onStartNew: {},
        onCancel: {}
    )
}
