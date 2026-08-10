//
//  WorkspaceState+Navigation.swift
//  whitenoise-mac
//
//  Navigation behavior extracted from WorkspaceState.swift (no behavior change).
//

import AVFoundation
import AppKit
import Combine
import Foundation
import MarmotKit
import Observation
import SwiftUI
import UserNotifications

@MainActor
extension WorkspaceState {
    /// Releases live, conversation-scoped resources whose only stop/cancel UI lives in the
    /// conversation composer or the group-details sheet. Any navigation path that removes
    /// those from the hierarchy (selecting another chat, opening Settings/new-chat, switching
    /// accounts, wiping data) must run this so the microphone can never stay hot with no
    /// visible way to stop it (#311) and a transcript export cannot keep paginating FFI
    /// calls for a conversation the user has left (#316).
    /// Centralizing the teardown keeps the cancellation from being silently omitted on new paths.
    func leaveActiveConversation() {
        cancelVoiceRecording()
        cancelGroupTranscriptExport()
        pendingMessageNavigation = nil
    }

    func selectChat(_ chat: ChatItem) {
        leaveActiveConversation()
        stopTimelineListener()
        cancelTimelineLoad()
        clearEnteredLoginIdentity()
        selection = .chat(chat.id)
        closeNewChatComposer()
        pruneMessageCache(keeping: chat.id)
        beginTimelineInitialLoadIfNeeded(groupIdHex: chat.id)
        Task { await loadMessages(groupIdHex: chat.id) }
    }

    func showNewChat() {
        leaveActiveConversation()
        isNewChatComposerVisible = true
        lastError = nil
        resetNewChatComposer()
    }

    func closeNewChatComposer() {
        isNewChatComposerVisible = false
        resetNewChatComposer()
    }

    func composeShowChooseMembers() {
        composePane = .chooseMembers
        clearComposeSearch()
    }

    func composeShowNameGroup() {
        guard !newChatRecipients.isEmpty else { return }
        composePane = .nameGroup
        clearComposeSearch()
    }

    /// One step back through the compose flow; leaving the first panel closes the composer.
    /// The group draft (members, name, timer) survives chooseMembers ↔ nameGroup hops and is
    /// discarded only when the composer closes.
    func composeGoBack() {
        guard !isCreatingChat else { return }
        switch composePane {
        case .newChat:
            closeNewChatComposer()
        case .chooseMembers:
            composePane = .newChat
            clearComposeSearch()
        case .nameGroup:
            composePane = .chooseMembers
        }
    }

    /// The single funnel for "the compose query went away" (pane hops, staging a member, going
    /// back). Releasing the people search here rather than waiting for the view's `.task(id:)` to
    /// notice keeps a relay traversal from outliving the panel that asked for it.
    /// `closeNewChatComposer()` is covered too, via `resetNewChatComposer()`.
    func clearComposeSearch() {
        invalidateNewChatLookup()
        invalidateUserDiscovery()
        newChatQuery = ""
        newChatRecipient = nil
        lastError = nil
    }

    func showSettings(_ page: SettingsPage = .profile) {
        leaveActiveConversation()
        stopTimelineListener()
        cancelTimelineLoad()
        clearEnteredLoginIdentity()
        // `lastError` is scoped to the user action on the current screen, but every settings
        // pane renders it through the shared `SettingsScaffold`. Without clearing it here a
        // failure raised in one pane (notification permission, relay save, …) follows the user
        // into every other pane and stays there until some unrelated action overwrites it.
        lastError = nil
        selection = .settings(page)
        closeNewChatComposer()
        pruneMessageCache(keeping: nil)
    }

    func showSettingsPage(_ page: SettingsPage) {
        showSettings(page)
    }

    func toggleChatList() {
        isChatListVisible.toggle()
    }

    /// Whether the drawer is currently the chat list rather than the settings list or the
    /// compose flow. Only the chat list has an avatar-only form, so this gates collapsing.
    var isChatListDrawerShowingChats: Bool {
        if case .settings = selection { return false }
        return !isNewChatComposerVisible
    }

    /// The width the drawer should render at. Equals `chatListWidth` while the chat list is
    /// showing; a settings or compose pane is floored to the narrowest full width, since
    /// neither has anything to show inside an avatar-only rail. Visiting one of those panes
    /// deliberately does *not* rewrite `chatListWidth`, so a collapsed chat list is still
    /// collapsed when the user comes back to it.
    var chatListDrawerWidth: CGFloat {
        isChatListDrawerShowingChats
            ? chatListWidth
            : max(chatListWidth, ChatListWidthPolicy.minimumExpandedWidth)
    }

    /// True when the drawer is rendering as an avatar-only rail.
    var isChatListCollapsed: Bool {
        ChatListWidthPolicy.isCollapsed(width: chatListDrawerWidth)
    }

    /// Commits a drag on the drawer's resize handle. `proposedWidth` is the raw dragged
    /// width; `ChatListWidthPolicy` decides which allowed width that lands on.
    func resizeChatListDrawer(toProposedWidth proposedWidth: CGFloat) {
        let resolved = ChatListWidthPolicy.resolve(
            proposedWidth: proposedWidth,
            allowsCollapse: isChatListDrawerShowingChats
        )
        guard resolved != chatListWidth else { return }
        let wasCollapsed = isChatListCollapsed
        chatListWidth = resolved
        // A row-filtering query the user can no longer see or clear is worse than no
        // query: the collapsed rail shows a silently short list with no search field to
        // explain it. Collapsing therefore releases the sidebar search.
        if !wasCollapsed, isChatListCollapsed, !searchText.isEmpty {
            invalidateSidebarMessageSearch(clearQuery: true)
        }
    }

    /// Keyboard/VoiceOver equivalent of dragging the handle, so the drawer width is not
    /// reachable by pointer alone.
    func stepChatListDrawerWidth(_ step: ChatListWidthPolicy.Step) {
        resizeChatListDrawer(
            toProposedWidth: ChatListWidthPolicy.stepped(
                from: chatListDrawerWidth,
                toward: step,
                allowsCollapse: isChatListDrawerShowingChats
            )
        )
    }
}
