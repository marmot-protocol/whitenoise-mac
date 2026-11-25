import MarmotKit
import SwiftUI

/// Pure target-identity validation for conversation toolbar actions (#1038).
///
/// Toolbar closures capture the account and chat displayed when the button was clicked; checking
/// against live workspace state before running guarantees a toolbar update or account switch can
/// never fire an action against the previously selected chat or account.
nonisolated struct ConversationToolbarActionGuard: Equatable, Sendable {
    let originAccountId: String?
    let originChatId: String

    func matches(activeAccountId: String?, selectedChatId: String?) -> Bool {
        guard let originAccountId, let activeAccountId else { return false }
        return activeAccountId == originAccountId && selectedChatId == originChatId
    }

    static func canSetGroupImage(for chat: ChatItem) -> Bool {
        !chat.isDirect && chat.canUseComposer
    }
}

/// Moves the conversation title, subtitle, compact disappearing-message timer, Catching up state,
/// Find, Chat Info, More menu, and message-selection contextual controls into the native macOS
/// window `.toolbar` (N04, N05, T11, K01–K06, #1038).
///
/// Preserves the existing slide-in Chat Info route (`workspace.showGroupDetails(for:)`),
/// permission-gated Set Group Image sheet, and conversation confirmation/history/poll-votes hosts
/// until `#1042` migrates details into `.inspector`.
struct ConversationToolbarModifier: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    @Environment(\.endingGroupIds) private var endingGroupIds
    @Environment(\.isBulkLeavingChats) private var isBulkLeavingChats
    let chat: ChatItem
    let model: ConversationViewModel
    let recoveryStatus: AccountRecoveryStatusViewModel?
    let blockedUsersModel: BlockedUsersViewModel
    let onSearch: () -> Void
    /// Whether Escape ends message selection. Off while chat-list selection is active so only one
    /// Escape target is installed: chat-list selection ends first, then message selection, then
    /// in-conversation search.
    let escapeEndsMessageSelection: Bool

    func body(content: Content) -> some View {
        @Bindable var workspace = workspace
        let originAccountId = workspace.activeAccountId
        let actionGuard = ConversationToolbarActionGuard(
            originAccountId: originAccountId,
            originChatId: chat.id
        )
        let metadata = workspace.conversationMetadataByChat[chat.id]
        let isCatchingUp = recoveryStatus?.isCatchingUp(groupIdHex: chat.id) == true

        content
            // Suppress duplicate plain title text beside the custom avatar+title+subtitle
            // `.navigation` toolbar item while keeping the window's own title in the Window menu.
            .navigationTitle("")
            .toolbar {
                if workspace.isTimelineSelectionMode {
                    ToolbarItem(placement: .navigation) {
                        ConversationSelectionToolbarTitle(count: workspace.selectedTimelineMessageIds.count)
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        ConversationSelectionToolbarActions(
                            conversationModel: model,
                            actionGuard: actionGuard,
                            escapeEndsMessageSelection: escapeEndsMessageSelection
                        )
                    }
                } else {
                    ToolbarItem(placement: .navigation) {
                        ConversationToolbarIdentity(
                            chat: chat,
                            metadata: metadata,
                            isCatchingUp: isCatchingUp
                        )
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: onSearch) {
                            Label(L10n.string("Search messages", locale: locale), systemImage: "magnifyingglass")
                        }
                        .help(L10n.string("Find in Conversation…", locale: locale))
                        .accessibilityIdentifier("conversation.search.open")

                        Button {
                            guard
                                actionGuard.matches(
                                    activeAccountId: workspace.activeAccountId,
                                    selectedChatId: workspace.selectedChat?.id
                                )
                            else { return }
                            if workspace.isGroupDetailsPresented {
                                workspace.closeGroupDetails()
                            } else {
                                Task {
                                    guard
                                        actionGuard.matches(
                                            activeAccountId: workspace.activeAccountId,
                                            selectedChatId: workspace.selectedChat?.id
                                        )
                                    else { return }
                                    await workspace.showGroupDetails(for: chat)
                                }
                            }
                        } label: {
                            Label(L10n.string("Show Chat Info", locale: locale), systemImage: "info.circle")
                                .symbolVariant(workspace.isGroupDetailsPresented ? .fill : .none)
                        }
                        .help(L10n.string("Show Chat Info", locale: locale))
                        .accessibilityIdentifier("conversation.info.open")

                        ConversationToolbarMoreMenu(
                            chat: chat,
                            conversationModel: model,
                            actionGuard: actionGuard,
                            endingGroupIds: endingGroupIds
                        )
                    }
                }
            }
            .messageDeletionConfirmation()
            .messageEditHistory(model: model)
            .pollVotesSheet(
                model: model,
                blockedUsersModel: blockedUsersModel,
                voterDisplay: { workspace.reactionReactorDisplay(accountIdHex: $0) }
            )
            .sheet(isPresented: $workspace.isGroupImagePickerPresented) {
                GroupImagePickerSheet()
                    .environment(\.endingGroupIds, endingGroupIds)
                    .environment(\.isBulkLeavingChats, isBulkLeavingChats)
            }
    }
}

extension View {
    func conversationToolbar(
        chat: ChatItem,
        model: ConversationViewModel,
        recoveryStatus: AccountRecoveryStatusViewModel?,
        blockedUsersModel: BlockedUsersViewModel,
        onSearch: @escaping () -> Void,
        escapeEndsMessageSelection: Bool
    ) -> some View {
        modifier(
            ConversationToolbarModifier(
                chat: chat,
                model: model,
                recoveryStatus: recoveryStatus,
                blockedUsersModel: blockedUsersModel,
                onSearch: onSearch,
                escapeEndsMessageSelection: escapeEndsMessageSelection
            )
        )
    }
}

/// Conversation avatar, title, and secondary status (Catching up or compact `#1088` disappearing
/// timer + member count) inside the native toolbar. Title presentation stays separate from the
/// Chat Info action (N04) and truncates gracefully before trailing toolbar commands disappear.
struct ConversationToolbarIdentity: View {
    @Environment(\.locale) private var locale
    let chat: ChatItem
    let metadata: ConversationMetadata?
    let isCatchingUp: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProfileImageAvatarView(
                seed: chat.avatarSeed,
                initials: chat.title,
                sanitizedPictureURL: chat.sanitizedPictureURL,
                localImagePayload: chat.groupImagePayload,
                size: 28,
                isSelected: false
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if isCatchingUp {
                    CatchingUpLabel(text: L10n.string("Catching up…", locale: locale))
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    let subtitle = metadata?.subtitle ?? chat.subtitle
                    let durationSeconds = metadata?.disappearingMessageSecs
                    if !subtitle.isEmpty || (durationSeconds ?? 0) > 0 {
                        DisappearingMessageHeaderSubtitle(
                            durationSeconds: durationSeconds,
                            subtitle: subtitle
                        )
                        .font(.caption)
                        .lineLimit(1)
                    }
                }
            }
            .layoutPriority(-1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.toolbar.identity")
    }
}

private struct ConversationSelectionToolbarTitle: View {
    @Environment(\.locale) private var locale
    let count: Int

    var body: some View {
        Text(L10n.plural("%lld selected", Int64(count), locale: locale))
            .font(.headline)
            .monospacedDigit()
            .contentTransition(.numericText())
            .accessibilityIdentifier("conversation.selection.count")
    }
}

private struct ConversationSelectionToolbarActions: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    let conversationModel: ConversationViewModel
    let actionGuard: ConversationToolbarActionGuard
    let escapeEndsMessageSelection: Bool

    var body: some View {
        let messages = workspace.selectedTimelineMessagesForAction
        let canForward = messages.contains(where: \.canForward)
        let canDelete = messages.contains(where: workspace.canDeleteMessage)

        Button {
            guard isCurrent() else { return }
            workspace.startForwarding(messages)
        } label: {
            Label(L10n.string("Forward", locale: locale), systemImage: "arrowshape.turn.up.right")
        }
        .help(L10n.string("Forward", locale: locale))
        .disabled(!canForward)
        .accessibilityIdentifier("conversation.selection.forward")

        Button(role: .destructive) {
            guard isCurrent() else { return }
            Task {
                guard isCurrent() else { return }
                await workspace.deleteSelectedMessages { message in
                    await FailedSendDiscard.run(message, model: conversationModel, workspace: workspace)
                }
            }
        } label: {
            Label(L10n.string("Delete", locale: locale), systemImage: "trash")
        }
        .help(L10n.string("Delete", locale: locale))
        .disabled(!canDelete)
        .accessibilityIdentifier("conversation.selection.delete")

        Button(L10n.string("Cancel", locale: locale)) {
            workspace.cancelMessageSelection()
        }
        .keyboardShortcut(escapeEndsMessageSelection ? .cancelAction : nil)
        .help(L10n.string("Cancel selection", locale: locale))
        .accessibilityIdentifier("conversation.selection.cancel")
    }

    private func isCurrent() -> Bool {
        actionGuard.matches(
            activeAccountId: workspace.activeAccountId,
            selectedChatId: workspace.selectedChat?.id
        )
    }
}

private struct ConversationToolbarMoreMenu: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    let chat: ChatItem
    let conversationModel: ConversationViewModel
    let actionGuard: ConversationToolbarActionGuard
    let endingGroupIds: Set<String>

    var body: some View {
        let actions = ChatMenuActions(workspace: workspace, chat: chat)
        let isArchived =
            actionGuard.originAccountId.map {
                workspace.archivedChatItem(accountId: $0, chatId: chat.id) != nil
            } ?? false
        let unreadAction = ConversationUnreadMenuAction.resolve(for: chat)

        Menu {
            Button {
                Task {
                    guard isCurrent() else { return }
                    await workspace.showGroupDetails(for: chat)
                }
            } label: {
                Label(L10n.string("Show Chat Info", locale: locale), systemImage: "info.circle")
            }

            if ConversationToolbarActionGuard.canSetGroupImage(for: chat) {
                Button {
                    guard isCurrent() else { return }
                    workspace.showGroupImagePicker(for: chat)
                } label: {
                    Label(L10n.string("Set group image", locale: locale), systemImage: "photo.badge.plus")
                }
            }

            Divider()

            ChatMuteMenu(actions: actions, locale: locale, isCurrent: isCurrent)

            Button {
                Task {
                    guard isCurrent() else { return }
                    switch unreadAction {
                    case .markRead:
                        await actions.markAsRead(conversation: conversationModel)
                    case .clearUnreadReminder:
                        await workspace.setChatManuallyUnread(chat, manuallyUnread: false)
                    case .markUnread:
                        await workspace.setChatManuallyUnread(chat, manuallyUnread: true)
                    }
                }
            } label: {
                Text(L10n.string(unreadAction.titleKey, locale: locale))
            }
            .disabled(
                !ConversationUnreadMenuAction.isEnabled(
                    action: unreadAction,
                    canChangePreferences: actions.canChangePreferences,
                    hasConversationSnapshot: conversationModel.snapshot != nil
                )
            )

            Button {
                Task {
                    guard isCurrent() else { return }
                    await actions.setArchived(!isArchived)
                }
            } label: {
                Label(
                    L10n.string(isArchived ? "Unarchive" : "Archive", locale: locale),
                    systemImage: isArchived ? "tray.and.arrow.up" : "archivebox"
                )
            }
            .disabled(!actions.canArchive)

            if let destructive = ChatDestructiveActions.action(for: chat) {
                Divider()
                let item: ChatRowMenuAction = destructive == .leave ? .leave : .deleteLocally
                Button(role: .destructive) {
                    switch destructive {
                    case .deleteLocally:
                        guard isCurrent() else { return }
                        actions.requestDeleteLocally(endingGroupIDs: endingGroupIds)
                    case .leave:
                        Task {
                            guard isCurrent() else { return }
                            await actions.requestLeave(endingGroupIDs: endingGroupIds)
                        }
                    }
                } label: {
                    Label(L10n.string(item.titleKey, locale: locale), systemImage: item.systemImage)
                }
                .disabled(!actions.canPerformDestructive(destructive, endingGroupIDs: endingGroupIds))
            }
        } label: {
            Label(L10n.string("More", locale: locale), systemImage: "ellipsis.circle")
        }
        .help(L10n.string("More", locale: locale))
        .accessibilityIdentifier("conversation.more.menu")
    }

    private func isCurrent() -> Bool {
        actionGuard.matches(
            activeAccountId: workspace.activeAccountId,
            selectedChatId: workspace.selectedChat?.id
        )
    }
}

#Preview("Conversation toolbar identity — timer") {
    ConversationToolbarIdentity(
        chat: ChatItem.samples[0],
        metadata: ConversationMetadata(memberCount: 3, disappearingMessageSecs: 86_400, isSelfAdmin: true),
        isCatchingUp: false
    )
    .padding()
}

#Preview("Conversation toolbar identity — catching up") {
    ConversationToolbarIdentity(
        chat: ChatItem.samples[0],
        metadata: ConversationMetadata(memberCount: 3, disappearingMessageSecs: 0, isSelfAdmin: false),
        isCatchingUp: true
    )
    .padding()
}

#Preview("Selection toolbar title") {
    ConversationSelectionToolbarTitle(count: 4)
        .padding()
}
