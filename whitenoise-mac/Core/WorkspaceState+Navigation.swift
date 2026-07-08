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
    }

    func selectChat(_ chat: ChatItem) {
        leaveActiveConversation()
        stopTimelineListener()
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

    func showSettings(_ page: SettingsPage = .profile) {
        leaveActiveConversation()
        stopTimelineListener()
        clearEnteredLoginIdentity()
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
}
