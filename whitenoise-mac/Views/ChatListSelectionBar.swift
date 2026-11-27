import MarmotKit
import SwiftUI

/// The bar under the chat list in selection mode: what can be done to every selected chat — the
/// Mac's counterpart to iOS's `ChatListSelectionBar`. Which actions it offers follows
/// `ChatListSelection`: Unarchive only when every selected chat is archived, Unmute only when every
/// one is muted, Leave whenever at least one can still be left, and Delete in Leave's place when
/// every selected chat is one already left (or whose group ended). Each of those choices is read
/// from the selected rows, so every action stays disabled until each selected id has resolved to
/// a row.
struct ChatListSelectionBar: View {
    @Environment(\.locale) private var locale
    @Environment(\.endingGroupIds) private var endingGroupIds
    let model: ChatListSelectionViewModel
    /// Resolves a selected id to its row, including chats outside the loaded window. The bar acts
    /// on every selected id; the rows only decide which actions it offers.
    let chat: (String) -> ChatItem?
    let archivedIds: Set<String>

    var body: some View {
        let ids = model.orderedSelection
        let selected = ids.compactMap(chat)
        let archiveAction = ChatListSelection.bulkArchiveAction(
            archivedFlags: selected.map { archivedIds.contains($0.id) }
        )
        let mutes = ChatListSelection.bulkMuteMutes(mutedFlags: selected.map(\.muted))
        // Archive/Unarchive, Mute/Unmute and Leave are chosen from the rows; until every selected
        // id has one, the choice would rest on part of the selection.
        let allResolved = !ids.isEmpty && selected.count == ids.count
        let leavable = ChatListSelection.leaveTargets(selected, endingGroupIds: endingGroupIds)
        let canLeave = allResolved && !leavable.isEmpty
        let canDelete = allResolved && ChatListSelection.canDeleteLocally(selected)

        // The count and the busy spinner sit in the Select All row at the top of the list.
        HStack(spacing: 16) {
            ChatListSelectionActionButton(
                title: L10n.string(archiveAction == .archive ? "Archive" : "Unarchive", locale: locale),
                systemImage: archiveAction == .archive ? "archivebox" : "tray.and.arrow.up",
                identifier: "chat.selection.archive"
            ) {
                model.setArchived(archiveAction == .archive, groupIds: ids)
            }
            .disabled(!allResolved)

            if mutes {
                ChatListSelectionMuteButton { duration in
                    model.setMuted(duration, groupIds: ids)
                }
                .disabled(!allResolved)
            } else {
                ChatListSelectionActionButton(
                    title: L10n.string("Unmute", locale: locale),
                    systemImage: "bell",
                    identifier: "chat.selection.unmute"
                ) {
                    model.setMuted(nil, groupIds: ids)
                }
                .disabled(!allResolved)
            }

            if canDelete {
                ChatListSelectionActionButton(
                    title: L10n.string("Delete Chats", locale: locale),
                    systemImage: "trash",
                    role: .destructive,
                    identifier: "chat.selection.delete"
                ) {
                    model.requestDelete(selected)
                }
            } else {
                ChatListSelectionActionButton(
                    title: L10n.string("Leave Chats", locale: locale),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    role: .destructive,
                    identifier: "chat.selection.leave"
                ) {
                    model.requestLeave(selected)
                }
                .disabled(!canLeave)
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(model.isBusy)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.selection.bar")
    }
}

/// Native bordered icon button for bulk actions in the chat-list selection bar.
private struct ChatListSelectionActionButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 22)
        }
        .wnSecondaryButtonStyle()
        .controlSize(.regular)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// Native Mute duration menu in the chat-list selection bar, matching a row's Mute submenu.
private struct ChatListSelectionMuteButton: View {
    @Environment(\.locale) private var locale
    let mute: (ChatMuteDuration) -> Void

    var body: some View {
        Menu {
            ForEach(ChatMuteDuration.allCases) { duration in
                Button {
                    mute(duration)
                } label: {
                    Label(L10n.string(duration.titleKey, locale: locale), systemImage: duration.systemImage)
                }
            }
        } label: {
            Label(L10n.string("Mute", locale: locale), systemImage: "bell.slash")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 22)
        }
        .menuStyle(.borderedButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.string("Mute", locale: locale))
        .accessibilityLabel(L10n.string("Mute", locale: locale))
        .accessibilityIdentifier("chat.selection.mute")
    }
}

#Preview("ChatListSelectionBar") {
    let model = ChatListSelectionViewModel(accountRef: "preview", runtime: nil)
    ChatListSelectionBar(model: model, chat: { _ in nil }, archivedIds: [])
        .frame(width: 280)
}

#Preview("ChatListSelectionBar — left chats") {
    let model = ChatListSelectionViewModel(accountRef: "preview", runtime: nil)
    let left = ChatItem(
        id: "left",
        title: "Book club",
        subtitle: "",
        preview: "",
        updatedAt: nil,
        avatarSeed: "left",
        pictureURL: nil,
        unreadCount: 0,
        selfMembership: .left
    )
    model.begin(with: left.id)
    return ChatListSelectionBar(model: model, chat: { $0 == left.id ? left : nil }, archivedIds: [])
        .frame(width: 280)
}
