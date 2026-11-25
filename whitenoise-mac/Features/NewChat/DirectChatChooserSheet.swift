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
            DirectChatChooserHeader(recipientName: presentation.recipient.title)

            Divider()

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
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            DirectChatChooserFooter(onCancel: onCancel, onStartNew: onStartNew)
        }
        .frame(minWidth: 380, idealWidth: 420)
    }
}

private struct DirectChatChooserHeader: View {
    let recipientName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                String(
                    format: L10n.string("Conversations with %@"),
                    PeerDisplayText.templateFragment(recipientName)
                )
            )
            .font(.headline)
            .foregroundStyle(Color(nsColor: .labelColor))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)

            Text(L10n.string("Choose a conversation to continue, or start a new one."))
                .font(.subheadline)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                            .font(.body)
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .lineLimit(1)
                        if choice.isArchived {
                            Image(systemName: "archivebox")
                                .font(.caption)
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .accessibilityLabel(L10n.string("Archived"))
                        }
                        Spacer(minLength: 4)
                        Text(choice.chat.timestampLabel)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                    Text(choice.chat.previewNotice() ?? choice.chat.preview)
                        .font(.subheadline)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isHovered ? WNColor.fillTertiaryHover : .clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Native macOS sheet footer (P01, C02, C05): Cancel answers Escape and dismisses the chooser,
/// while Start new conversation stays secondary so continuing an existing chat remains the primary
/// path.
private struct DirectChatChooserFooter: View {
    let onCancel: () -> Void
    let onStartNew: () -> Void

    var body: some View {
        HStack {
            Button(L10n.string("Cancel"), action: onCancel)
                .wnSecondaryButtonStyle()
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("compose.chooser.cancel")

            Spacer()

            Button(action: onStartNew) {
                Text(L10n.string("Start new conversation"))
                    .lineLimit(1)
            }
            .wnSecondaryButtonStyle()
            .accessibilityIdentifier("compose.chooser.startNew")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
