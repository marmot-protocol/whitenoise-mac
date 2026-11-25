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

    private var toolbarTitle: String {
        if messenger.workspace.isTimelineSelectionMode {
            return L10n.plural(
                "%lld selected", Int64(messenger.workspace.selectedTimelineMessageIds.count), locale: locale)
        }
        return chat.title
    }

    private var toolbarSubtitle: String {
        guard !messenger.workspace.isTimelineSelectionMode else { return "" }
        if isCatchingUp {
            return L10n.string("Catching up…", locale: locale)
        }
        let baseSubtitle = metadata?.subtitle ?? chat.subtitle
        if let durationSeconds = metadata?.disappearingMessageSecs, durationSeconds > 0 {
            let duration = DisappearingMessageOption.option(for: durationSeconds).label
            let retentionSummary = String(format: L10n.string("Disappearing messages: %@", locale: locale), duration)
            if baseSubtitle.isEmpty {
                return retentionSummary
            }
            return "\(baseSubtitle) · \(retentionSummary)"
        }
        return baseSubtitle
    }

    private func toggleChatInfo() {
        let workspace = messenger.workspace
        guard let currentChat = messenger.activeChat(matching: chat.id) else { return }
        if isDetailsPanePresented {
            workspace.closeGroupDetails()
        } else {
            Task {
                guard let refreshedChat = messenger.activeChat(matching: currentChat.id) else {
                    return
                }
                await workspace.showGroupDetails(for: refreshedChat)
            }
        }
    }

    func body(content: Content) -> some View {
        let workspace = messenger.workspace
        let infoTitle = L10n.string(
            isDetailsPanePresented ? "Hide Info" : "Info",
            locale: locale
        )

        content
            // Keep window title updated for Window menu / Mission Control while hosting a clickable
            // avatar+title+subtitle in the leading toolbar slot (no pill chrome) and Search + More
            // on the far trailing right.
            .navigationTitle(toolbarTitle)
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar {
                if workspace.isTimelineSelectionMode {
                    ToolbarItem(placement: .navigation) {
                        ConversationSelectionToolbarTitle(count: workspace.selectedTimelineMessageIds.count)
                    }
                    .sharedBackgroundVisibilityIfAvailable(.hidden)

                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
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
                        Button(action: toggleChatInfo) {
                            ConversationToolbarHeaderLabel(chat: chat, subtitle: toolbarSubtitle)
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help(infoTitle)
                        .accessibilityLabel(chat.title)
                        .accessibilityHint(infoTitle)
                        .accessibilityIdentifier("conversation.info.open")
                    }
                    .sharedBackgroundVisibilityIfAvailable(.hidden)

                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: onSearch) {
                            Label(L10n.string("Search messages", locale: locale), systemImage: "magnifyingglass")
                        }
                        .help(L10n.string("Find in Conversation…", locale: locale))
                        .accessibilityIdentifier("conversation.search.open")

                        Button(action: toggleChatInfo) {
                            Label(
                                infoTitle,
                                systemImage: isDetailsPanePresented ? "chevron.right.2" : "info.circle"
                            )
                            .contentTransition(.symbolEffect(.replace))
                        }
                        .help(infoTitle)
                        .accessibilityLabel(infoTitle)
                        .accessibilityIdentifier("conversation.info.toggle")

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
                            Label(L10n.string("More", locale: locale), systemImage: "ellipsis")
                        }
                        .menuIndicator(.hidden)
                        .help(L10n.string("More", locale: locale))
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

/// Shared leading header content (28pt chat avatar + title + subtitle) used by both the live
/// conversation toolbar and the 1-frame switching placeholder so chat switches never flash.
struct ConversationToolbarHeaderLabel: View {
    let chat: ChatItem
    let subtitle: String

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
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(minWidth: 0, alignment: .leading)
        .layoutPriority(-1)
        .contentShape(Rectangle())
    }
}

/// Holds the conversation toolbar layout steady during the brief async frame while a newly
/// selected chat's `ConversationViewModel` binds, preventing a flash back to the default window
/// titlebar.
struct ConversationSwitchingPlaceholderView: View {
    @Environment(\.locale) private var locale
    let chat: ChatItem
    let metadata: ConversationMetadata?

    private var subtitle: String {
        let baseSubtitle = metadata?.subtitle ?? chat.subtitle
        if let durationSeconds = metadata?.disappearingMessageSecs, durationSeconds > 0 {
            let duration = DisappearingMessageOption.option(for: durationSeconds).label
            let retentionSummary = String(format: L10n.string("Disappearing messages: %@", locale: locale), duration)
            if baseSubtitle.isEmpty { return retentionSummary }
            return "\(baseSubtitle) · \(retentionSummary)"
        }
        return baseSubtitle
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(chat.title)
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ConversationToolbarHeaderLabel(chat: chat, subtitle: subtitle)
                }
                .sharedBackgroundVisibilityIfAvailable(.hidden)

                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                    } label: {
                        Label(L10n.string("Search messages", locale: locale), systemImage: "magnifyingglass")
                    }
                    .disabled(true)

                    Button {
                    } label: {
                        Label(L10n.string("Info", locale: locale), systemImage: "info.circle")
                    }
                    .disabled(true)

                    Button {
                    } label: {
                        Label(L10n.string("More", locale: locale), systemImage: "ellipsis")
                    }
                    .disabled(true)
                }
            }
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func sharedBackgroundVisibilityIfAvailable(_ visibility: Visibility) -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(visibility)
        } else {
            self
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

    @State private var pendingDeletion: SelectionDeletion?

    var body: some View {
        let workspace = messenger.workspace
        let messages = workspace.selectedTimelineMessagesForAction
        let canForward = messages.contains(where: \.canForward)
        let deletionTargets = workspace.selectedMessageDeletionTargets

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
            guard messenger.activeChat(matching: chatId) != nil else { return }
            pendingDeletion = SelectionDeletion(
                targets: deletionTargets, selectionCount: workspace.selectedTimelineMessageIds.count)
        } label: {
            Label(L10n.string("Delete", locale: locale), systemImage: "trash")
        }
        .help(L10n.string("Delete", locale: locale))
        .disabled(deletionTargets.isEmpty)
        .accessibilityIdentifier("conversation.selection.delete")
        .confirmationDialog(
            pendingDeletion?.title(locale: locale) ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { selection in
            Button(L10n.string(selection.actionKey, locale: locale), role: .destructive) {
                Task {
                    await workspace.deleteSelectedMessages(confirming: selection.targets) { message in
                        await FailedSendDiscard.run(message, model: conversationModel, workspace: workspace)
                    }
                }
            }
            Button(L10n.string("Cancel", locale: locale), role: .cancel) {}
        } message: { selection in
            Text(verbatim: selection.summary(locale: locale))
        }

        Button(L10n.string("Cancel", locale: locale)) {
            workspace.cancelMessageSelection()
        }
        .keyboardShortcut(escapeEndsMessageSelection && pendingDeletion == nil ? .cancelAction : nil)
        .help(L10n.string("Cancel selection", locale: locale))
        .accessibilityIdentifier("conversation.selection.cancel")
    }
}

private struct SelectionDeletion {
    let targets: [MessageDeletionTarget]
    let selectionCount: Int

    var localCount: Int { targets.filter { $0.message.isLocalPublishFailure }.count }
    var sharedCount: Int { targets.count - localCount }

    var actionKey: String {
        if localCount == 0 { return "Delete for everyone" }
        if sharedCount == 0 { return "Remove From This Device" }
        return "Delete"
    }

    func title(locale: Locale) -> String {
        if sharedCount == 1 && localCount == 0 { return L10n.string("Delete message?", locale: locale) }
        if sharedCount > 0 && localCount > 0 {
            return [
                L10n.string("Delete for everyone", locale: locale),
                L10n.string("Remove From This Device", locale: locale),
            ]
            .joined(separator: " / ")
        }
        return L10n.string(actionKey, locale: locale)
    }

    func summary(locale: Locale) -> String {
        let rows = [
            ("Delete for everyone", sharedCount),
            ("Remove From This Device", localCount),
            ("Skipped", selectionCount - targets.count),
        ]
        return rows.filter { $0.1 > 0 }.map { label, count in
            "\(L10n.string(label, locale: locale)) · \(count.formatted(.number.locale(locale)))"
        }.joined(separator: "\n")
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
