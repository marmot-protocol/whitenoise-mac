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

    var body: some View {
        let targets = chats.filter { chat in
            let searchMatches = query.isEmpty || chat.title.localizedStandardContains(query)
            return chat.canUseComposer && !chat.isBlockedDirectPeer && searchMatches
        }

        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("Forward To"))
                    .wnFont(.semiBold16)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Close"))
            }
            .padding(16)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                TextField(L10n.string("Search chats"), text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

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
            }
        }
        .frame(width: 420, height: 520)
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
                    size: 34,
                    isSelected: false
                )
                Text(chat.title)
                    .lineLimit(1)
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrowshape.turn.up.right")
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

#Preview {
    MessageForwardSheet(
        model: MessageForwardViewModel(messages: [], dependencies: .inert),
        chats: ChatItem.samples,
        onClose: {}
    )
}
