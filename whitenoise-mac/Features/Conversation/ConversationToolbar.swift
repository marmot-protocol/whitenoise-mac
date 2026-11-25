import MarmotKit
import SwiftUI

/// Pure eligibility helpers for the conversation toolbar (#1038).
nonisolated enum ConversationToolbarEligibility {
    /// Matches `GroupDetailsPermissions`: only active groups the user can compose in AND edit
    /// (per MDK's `canEditGroup` capability, falling back to `isSelfAdmin` before the header loads).
    static func canSetGroupImage(
        for chat: ChatItem,
        capabilities: ConversationCapabilitiesFfi? = nil,
        metadata: ConversationMetadata? = nil
    ) -> Bool {
        guard !chat.isDirect, chat.canUseComposer, chat.lifecycle == .active else { return false }
        return capabilities?.canEditGroup ?? metadata?.isSelfAdmin ?? false
    }
}

/// Moves the conversation title, subtitle, compact disappearing-message timer, Catching up state,
/// Find, Chat Info, More menu, and message-selection contextual controls into the native macOS
/// window `.toolbar` (N04, N05, T11, K01–K06, #1038).
///
/// Reuses `MessengerCommandContext` for target-identity revalidation and `ConversationMenuItems`
/// for the More menu so menu-bar and toolbar actions stay in lockstep.
struct ConversationToolbarModifier: ViewModifier {
    @Environment(\.locale) private var locale
    @Environment(\.endingGroupIds) private var endingGroupIds
    @Environment(\.isBulkLeavingChats) private var isBulkLeavingChats
    let messenger: MessengerCommandContext
    let chat: ChatItem
    let model: ConversationViewModel
    let metadata: ConversationMetadata?
    let isCatchingUp: Bool
    let isGroupDetailsPresented: Bool
    let isDetailsPanePresented: Bool
    let blockedUsersModel: BlockedUsersViewModel
    let isGroupImagePickerPresented: Binding<Bool>
    let onSearch: () -> Void
    /// Whether Escape ends message selection. Off while chat-list selection is active so only one
    /// Escape target is installed: chat-list selection ends first, then message selection, then
    /// in-conversation search.
    let escapeEndsMessageSelection: Bool

    func body(content: Content) -> some View {
        let workspace = messenger.workspace

        content
            // Keep the chat title on the window (Window menu, Mission Control, VoiceOver) while
            // hiding SwiftUI's duplicate plain toolbar title beside the custom `.navigation` item.
            .navigationTitle(chat.title)
            .toolbar(removing: .title)
            .toolbar {
                if workspace.isTimelineSelectionMode {
                    ToolbarItem(placement: .navigation) {
                        ConversationSelectionToolbarTitle(count: workspace.selectedTimelineMessageIds.count)
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        ConversationSelectionToolbarActions(
                            messenger: messenger,
                            chatId: chat.id,
                            conversationModel: model,
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
                        .disabled(isDetailsPanePresented)
                        .accessibilityIdentifier("conversation.search.open")

                        Button {
                            guard let currentChat = messenger.activeChat(matching: chat.id) else { return }
                            if isGroupDetailsPresented {
                                workspace.closeGroupDetails()
                            } else {
                                Task {
                                    guard let refreshedChat = messenger.activeChat(matching: currentChat.id) else {
                                        return
                                    }
                                    await workspace.showGroupDetails(for: refreshedChat)
                                }
                            }
                        } label: {
                            Label(L10n.string("Show Chat Info", locale: locale), systemImage: "info.circle")
                                .symbolVariant(isGroupDetailsPresented ? .fill : .none)
                        }
                        .help(L10n.string("Show Chat Info", locale: locale))
                        .disabled(isDetailsPanePresented && !isGroupDetailsPresented)
                        .accessibilityIdentifier("conversation.info.open")

                        Menu {
                            ConversationMenuItems(
                                messenger: messenger,
                                conversation: model,
                                chat: chat,
                                locale: locale,
                                endingGroupIDs: endingGroupIds,
                                onSetGroupImage: {
                                    workspace.showGroupImagePicker(for: chat)
                                }
                            )
                        } label: {
                            Label(L10n.string("More", locale: locale), systemImage: "ellipsis.circle")
                        }
                        .help(L10n.string("More", locale: locale))
                        .disabled(isDetailsPanePresented)
                        .accessibilityIdentifier("conversation.more.menu")
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
            .sheet(isPresented: isGroupImagePickerPresented) {
                GroupImagePickerSheet()
                    .environment(\.endingGroupIds, endingGroupIds)
                    .environment(\.isBulkLeavingChats, isBulkLeavingChats)
            }
    }
}

extension View {
    func conversationToolbar(
        messenger: MessengerCommandContext,
        chat: ChatItem,
        model: ConversationViewModel,
        metadata: ConversationMetadata?,
        isCatchingUp: Bool,
        isGroupDetailsPresented: Bool,
        isDetailsPanePresented: Bool,
        blockedUsersModel: BlockedUsersViewModel,
        isGroupImagePickerPresented: Binding<Bool>,
        onSearch: @escaping () -> Void,
        escapeEndsMessageSelection: Bool
    ) -> some View {
        modifier(
            ConversationToolbarModifier(
                messenger: messenger,
                chat: chat,
                model: model,
                metadata: metadata,
                isCatchingUp: isCatchingUp,
                isGroupDetailsPresented: isGroupDetailsPresented,
                isDetailsPanePresented: isDetailsPanePresented,
                blockedUsersModel: blockedUsersModel,
                isGroupImagePickerPresented: isGroupImagePickerPresented,
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
    @Environment(\.locale) private var locale
    let messenger: MessengerCommandContext
    let chatId: String
    let conversationModel: ConversationViewModel
    let escapeEndsMessageSelection: Bool

    var body: some View {
        let workspace = messenger.workspace
        let messages = workspace.selectedTimelineMessagesForAction
        let canForward = messages.contains(where: \.canForward)
        // Must match `WorkspaceState.deleteSelectedMessages`: bulk deletion acts only on messages
        // the user may delete for everyone (never silently mixing in local hides).
        let canDelete = messages.contains { workspace.messageDeletionCapability($0).canDeleteForEveryone }

        Button {
            guard messenger.activeChat(matching: chatId) != nil else { return }
            workspace.startForwarding(messages)
        } label: {
            Label(L10n.string("Forward", locale: locale), systemImage: "arrowshape.turn.up.right")
        }
        .help(L10n.string("Forward", locale: locale))
        .disabled(!canForward)
        .accessibilityIdentifier("conversation.selection.forward")

        Button(role: .destructive) {
            Task {
                guard messenger.activeChat(matching: chatId) != nil else { return }
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
}

#Preview("Conversation toolbar identity — timer") {
    ConversationToolbarIdentity(
        chat: ChatItem.samples[0],
        metadata: ConversationMetadata(memberCount: 3, disappearingMessageSecs: 86_400, isSelfAdmin: true),
        isCatchingUp: false
    )
    .environment(WorkspaceState.preview())
    .padding()
}

#Preview("Conversation toolbar identity — catching up") {
    ConversationToolbarIdentity(
        chat: ChatItem.samples[0],
        metadata: ConversationMetadata(memberCount: 3, disappearingMessageSecs: 0, isSelfAdmin: false),
        isCatchingUp: true
    )
    .environment(WorkspaceState.preview())
    .padding()
}

#Preview("Selection toolbar title") {
    ConversationSelectionToolbarTitle(count: 4)
        .padding()
}
