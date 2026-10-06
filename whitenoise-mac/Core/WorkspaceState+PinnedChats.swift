//
//  WorkspaceState+PinnedChats.swift
//  whitenoise-mac
//
//  Account-device chat pins. MarmotKit owns them: it persists the pinned section and orders
//  the chat-list projections the sidebar renders, pinned rows first. `pinnedChatIdsByAccount`
//  only mirrors the pinned set the core reports, for the row badge, the context menu and the
//  ordering of the legacy `chatsByAccount` list.
//
//  Pins used to live only in a host-side file the core never read, so pinning drew the badge
//  but left the row where it was. `PinnedChatFileStore` survives solely so those pins can be
//  handed to the core once, at launch.
//

import Foundation
import MarmotKit
import OSLog

private let pinnedChatLogger = Logger(subsystem: "com.whitenoise.storage", category: "PinnedChats")

@MainActor
extension WorkspaceState {
    /// Hands pins saved by the host-only store to MarmotKit, then forgets them. The order is
    /// arbitrary — the old store kept a set, not an order — and the core puts each newly pinned
    /// chat on top. A pin the core refuses (the group is gone) is dropped with the rest;
    /// keeping it would retry a dead group on every launch.
    func migrateLegacyPinnedChats(runtime: any MarmotRuntime) async {
        guard let pinnedChatStore else { return }
        let legacy: [String: Set<String>]
        do {
            legacy = try pinnedChatStore.loadAll()
        } catch {
            pinnedChatLogger.error(
                "Failed to load legacy pinned-chat state: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        for account in signedInAccounts {
            guard let groupIds = legacy[account.id], !groupIds.isEmpty else { continue }
            let accountRef = account.accountRef
            let failures =
                (try? await FFIExecutor.run {
                    var failures = 0
                    for groupIdHex in groupIds.sorted() {
                        do {
                            _ = try runtime.setChatPinned(accountRef: accountRef, groupIdHex: groupIdHex, pinned: true)
                        } catch {
                            failures += 1
                        }
                    }
                    return failures
                }) ?? groupIds.count
            if failures > 0 {
                pinnedChatLogger.error("Dropped \(failures, privacy: .public) legacy pins MarmotKit refused")
            }
            do {
                try pinnedChatStore.remove(forAccountId: account.id)
            } catch {
                pinnedChatLogger.error(
                    "Failed to remove migrated pinned-chat state: \(error.localizedDescription, privacy: .public)"
                )
            }
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

    func setChatPinned(_ chat: ChatItem, pinned: Bool) async {
        guard let client, let activeAccount, !mutatingChatPreferenceIds.contains(chat.id) else { return }
        let accountId = activeAccount.id
        mutatingChatPreferenceIds.insert(chat.id)
        defer { mutatingChatPreferenceIds.remove(chat.id) }
        do {
            let state = try await FFIExecutor.run {
                try client.setChatPinned(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: chat.id,
                    pinned: pinned
                )
            }
            guard activeAccountId == accountId else { return }
            // The projection snapshot carrying the new order follows on its own; mirroring the
            // returned order now keeps the badge and menu from lagging behind it.
            mirrorPinnedChatIds(Set(state.orderedGroupIds), forAccountId: accountId)
        } catch {
            guard activeAccountId == accountId else { return }
            lastError = error.localizedDescription
        }
    }

    /// Adopts the pinned set from a complete chat-list snapshot.
    func mirrorPinnedChatIds(from rows: [ChatListRowFfi], forAccountId accountId: String) {
        let pinnedIds = Set(rows.lazy.filter(\.pinned).map(\.groupIdHex))
        guard pinnedIds != pinnedChatIds(forAccountId: accountId) else { return }
        pinnedChatIdsByAccount[accountId] = pinnedIds.isEmpty ? nil : pinnedIds
    }

    /// Adopts one row's pin from a live delta, which says nothing about the other rows.
    func mirrorPinnedChatId(from row: ChatListRowFfi, forAccountId accountId: String) {
        var pinnedIds = pinnedChatIds(forAccountId: accountId)
        let didChange =
            row.pinned ? pinnedIds.insert(row.groupIdHex).inserted : pinnedIds.remove(row.groupIdHex) != nil
        guard didChange else { return }
        pinnedChatIdsByAccount[accountId] = pinnedIds.isEmpty ? nil : pinnedIds
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

    private func mirrorPinnedChatIds(_ pinnedIds: Set<String>, forAccountId accountId: String) {
        guard pinnedIds != pinnedChatIds(forAccountId: accountId) else { return }
        pinnedChatIdsByAccount[accountId] = pinnedIds.isEmpty ? nil : pinnedIds
        reorderActiveChats(forAccountId: accountId)
    }

    private func reorderActiveChats(forAccountId accountId: String) {
        guard let chats = chatsByAccount[accountId] else { return }
        setChats(sortedActiveChatItems(chats, forAccountId: accountId), forAccountId: accountId)
    }
}
