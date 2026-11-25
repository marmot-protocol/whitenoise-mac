//
//  MessageForwardSheet.swift
//  whitenoise-mac
//

import SwiftUI

/// The "Forward To" picker. Takes its chat list as plain rows so it depends on nothing it is not
/// handed; the presenting pane projects them from the account's chat list.
struct MessageForwardSheet: View {
    let model: MessageForwardViewModel
    let chats: [ChatItem]
    let onClose: () -> Void
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let targets = chats.filter { chat in
            let searchMatches = query.isEmpty || chat.title.localizedStandardContains(query)
            return chat.canUseComposer && !chat.isBlockedDirectPeer && searchMatches
        }

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("Forward To"))
                    .font(.headline)
                    .foregroundStyle(WNColor.textPrimary)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                        .accessibilityHidden(true)
                    TextField(L10n.string("Search chats"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($isSearchFocused)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button {
                            query = ""
                            isSearchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("Clear search"))
                        .accessibilityLabel(L10n.string("Clear search"))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSearchFocused ? WNColor.borderPrimary : WNColor.borderTertiary, lineWidth: 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            if targets.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? L10n.string("No chats") : L10n.string("No matching chats"),
                    systemImage: query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(targets) { chat in
                            MessageForwardTargetRow(
                                chat: chat,
                                isBusy: model.busyChatId == chat.id,
                                isDisabled: model.isBusy,
                                action: { model.forward(to: chat) }
                            )
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.string("Cancel"), action: onClose)
                    .wnSecondaryButtonStyle()
                    .disabled(model.isBusy)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 520)
        .interactiveDismissDisabled(model.isBusy)
        .onAppear { isSearchFocused = true }
        .alert(
            L10n.string("Files unavailable"),
            isPresented: Binding(
                get: { model.unavailableFiles != nil },
                set: { isPresented in
                    if !isPresented { model.dismissUnavailableFiles() }
                }
            ),
            presenting: model.unavailableFiles
        ) { files in
            if files.canForwardRemainder {
                Button(L10n.string("Forward Anyway")) {
                    model.forwardAvailableFiles()
                }
                Button(L10n.string("Cancel"), role: .cancel) {
                    model.dismissUnavailableFiles()
                }
            } else {
                Button(L10n.string("OK"), role: .cancel) {
                    model.dismissUnavailableFiles()
                }
            }
        } message: { files in
            Text(files.message)
        }
    }
}

private struct MessageForwardTargetRow: View {
    @State private var isHovering = false
    let chat: ChatItem
    let isBusy: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProfileImageAvatarView(
                    seed: chat.avatarSeed,
                    initials: chat.title,
                    sanitizedPictureURL: chat.sanitizedPictureURL,
                    localImagePayload: chat.groupImagePayload,
                    size: 32,
                    isSelected: false
                )
                Text(chat.title)
                    .font(.body)
                    .foregroundStyle(WNColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.subheadline)
                        .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering && !isDisabled ? WNColor.fillTertiaryHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
    }
}

#Preview("Forward To – Light") {
    MessageForwardSheet(
        model: MessageForwardViewModel(messages: [], dependencies: .inert),
        chats: ChatItem.samples,
        onClose: {}
    )
    .environment(\.colorScheme, .light)
}

#Preview("Forward To – Dark") {
    MessageForwardSheet(
        model: MessageForwardViewModel(messages: [], dependencies: .inert),
        chats: ChatItem.samples,
        onClose: {}
    )
    .environment(\.colorScheme, .dark)
}
