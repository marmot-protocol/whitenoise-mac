//
//  WorkspaceState+PinnedChats.swift
//  whitenoise-mac
//
//  Local account-scoped chat pins. Pins partition the active chat list without changing
//  the ordinary recency ordering within the pinned and unpinned partitions.
//

import Foundation
import OSLog

private let pinnedChatLogger = Logger(subsystem: "com.whitenoise.storage", category: "PinnedChats")

@MainActor
extension WorkspaceState {
    func loadPinnedChats() {
        guard let pinnedChatStore else { return }
        do {
            pinnedChatIdsByAccount = try pinnedChatStore.loadAll()
        } catch {
            pinnedChatLogger.error(
                "Failed to load protected pinned-chat state: \(error.localizedDescription, privacy: .public)"
            )
        }

        for accountId in Array(chatsByAccount.keys) {
            reorderActiveChats(forAccountId: accountId)
        }
    }

    func pinnedChatIds(forAccountId accountId: String) -> Set<String> {
        pinnedChatIdsByAccount[accountId] ?? []
    }

    func isChatPinned(_ chat: ChatItem) -> Bool {
        guard let activeAccountId else { return false }
        return isChatPinned(accountId: activeAccountId, groupIdHex: chat.id)
    }

    func isChatPinned(accountId: String, groupIdHex: String) -> Bool {
        pinnedChatIds(forAccountId: accountId).contains(groupIdHex)
    }

    func setChatPinned(_ chat: ChatItem, pinned: Bool) {
        guard
            let activeAccountId,
            chatIndex(accountId: activeAccountId, chatId: chat.id) != nil
        else { return }

        var pinnedIds = pinnedChatIds(forAccountId: activeAccountId)
        let didChange = pinned ? pinnedIds.insert(chat.id).inserted : pinnedIds.remove(chat.id) != nil
        guard didChange else { return }

        pinnedChatIdsByAccount[activeAccountId] = pinnedIds.isEmpty ? nil : pinnedIds
        persistPinnedChats(forAccountId: activeAccountId)
        reorderActiveChats(forAccountId: activeAccountId)
    }

    func sortedActiveChatItems(_ chatItems: [ChatItem], forAccountId accountId: String) -> [ChatItem] {
        ChatListOrdering.sorted(
            chatItems,
            pinnedChatIds: pinnedChatIds(forAccountId: accountId)
        )
    }

    func purgePinnedChats(accountId: String) {
        pinnedChatIdsByAccount[accountId] = nil
        do {
            try pinnedChatStore?.remove(forAccountId: accountId)
        } catch {
            pinnedChatLogger.error(
                "Failed to purge pinned-chat state for an account: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func clearAllPinnedChats() {
        pinnedChatIdsByAccount = [:]
        do {
            try pinnedChatStore?.removeAll()
        } catch {
            pinnedChatLogger.error(
                "Failed to clear pinned-chat state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistPinnedChats(forAccountId accountId: String) {
        guard let pinnedChatStore else { return }
        do {
            let groupIds = pinnedChatIds(forAccountId: accountId)
            if groupIds.isEmpty {
                try pinnedChatStore.remove(forAccountId: accountId)
            } else {
                try pinnedChatStore.write(groupIds, forAccountId: accountId)
            }
        } catch {
            pinnedChatLogger.error(
                "Failed to persist pinned-chat state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func reorderActiveChats(forAccountId accountId: String) {
        guard let chats = chatsByAccount[accountId] else { return }
        setChats(sortedActiveChatItems(chats, forAccountId: accountId), forAccountId: accountId)
    }
}
