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
    func selectChat(_ chat: ChatItem) {
        cancelVoiceRecording()
        stopTimelineListener()
        clearEnteredLoginIdentity()
        selection = .chat(chat.id)
        closeNewChatComposer()
        pruneMessageCache(keeping: chat.id)
        beginTimelineInitialLoadIfNeeded(groupIdHex: chat.id)
        Task { await loadMessages(groupIdHex: chat.id) }
    }

    func showNewChat() {
        isNewChatComposerVisible = true
        lastError = nil
        resetNewChatComposer()
    }

    func closeNewChatComposer() {
        isNewChatComposerVisible = false
        resetNewChatComposer()
    }

    func showSettings(_ page: SettingsPage = .profile) {
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
        withAnimation(.smooth(duration: 0.18)) {
            isChatListVisible.toggle()
        }
    }
}
