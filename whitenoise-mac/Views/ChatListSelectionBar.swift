import MarmotKit
import SwiftUI

/// The bar under the chat list in selection mode: how many chats are selected, and what can be
/// done to all of them — the Mac's counterpart to iOS's `ChatListSelectionBar`. Which actions it
/// offers follows `ChatListSelection`: Unarchive only when every selected chat is archived, Unmute
/// only when every one is muted, Leave whenever at least one can still be left. Each of those
/// choices is read from the selected rows, so every action stays disabled until each selected id
/// has resolved to a row.
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

        HStack(spacing: 8) {
            ChatListSelectionCount(count: ids.count, isBusy: model.isBusy)

            Spacer(minLength: 4)

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
        .disabled(model.isBusy)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.selection.bar")
    }
}

private struct ChatListSelectionCount: View {
    @Environment(\.locale) private var locale
    let count: Int
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(L10n.plural("%lld selected", Int64(count), locale: locale))
                .wnFont(.medium14)
                .contentTransition(.numericText())
                .lineLimit(1)
                .accessibilityIdentifier("chat.selection.count")
        }
        .animation(.default, value: count)
    }
}

/// One of the bar's round buttons, drawn like the chat-list header's controls. Icon-only for the
/// drawer's width; the title rides on the tooltip and the accessibility label.
private struct ChatListSelectionActionButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            ChatListSelectionActionGlyph(systemImage: systemImage, isDestructive: role == .destructive)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

private struct ChatListSelectionActionGlyph: View {
    @Environment(\.isEnabled) private var isEnabled
    let systemImage: String
    var isDestructive = false

    var body: some View {
        Image(systemName: systemImage)
            .wnFont(.semiBold14)
            .foregroundStyle(
                !isEnabled
                    ? WNColor.fillContentDisabled
                    : isDestructive ? WNColor.backgroundContentDestructive : WNColor.backgroundContentPrimary
            )
            .frame(width: 34, height: 34)
            .background {
                MessagesCircleControlBackground()
            }
            .contentShape(.circle)
    }
}

/// Mute, with the same lengths as a row's Mute submenu. A popover rather than a `Menu`: a menu
/// flattens a custom label on macOS, which would lose the round control.
private struct ChatListSelectionMuteButton: View {
    @Environment(\.locale) private var locale
    @State private var isPresented = false
    let mute: (ChatMuteDuration) -> Void

    var body: some View {
        Button {
            isPresented = true
        } label: {
            ChatListSelectionActionGlyph(systemImage: "bell.slash")
        }
        .buttonStyle(.plain)
        .help(L10n.string("Mute", locale: locale))
        .accessibilityLabel(L10n.string("Mute", locale: locale))
        .accessibilityIdentifier("chat.selection.mute")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ChatMuteDuration.allCases) { duration in
                    ChatListSelectionMuteOption(duration: duration) {
                        isPresented = false
                        mute(duration)
                    }
                }
            }
            .padding(6)
            // Popovers do not inherit the injected locale.
            .environment(\.locale, locale)
        }
    }
}

private struct ChatListSelectionMuteOption: View {
    @Environment(\.locale) private var locale
    @State private var isHovered = false
    let duration: ChatMuteDuration
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.string(duration.titleKey, locale: locale), systemImage: duration.systemImage)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(minWidth: 180, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? WNColor.fillTertiaryHover : WNColor.fillTertiary)
        }
        .onHover { isHovered = $0 }
    }
}

#Preview("ChatListSelectionBar") {
    let model = ChatListSelectionViewModel(accountRef: "preview", runtime: nil)
    ChatListSelectionBar(model: model, chat: { _ in nil }, archivedIds: [])
        .frame(width: 280)
}
