//
//  WorkspaceState+HiddenMessages.swift
//  whitenoise-mac
//
//  "Delete for me" — a local, per-account/group set of hidden message ids. Hiding publishes
//  nothing; the ids are filtered from the timeline projection so a hide survives reprojection
//  and restart, and persisted in protected, backup-excluded per-chat files.
//

import Foundation
import OSLog

private let hiddenMessageLogger = Logger(subsystem: "com.whitenoise.storage", category: "HiddenMessages")

@MainActor
extension WorkspaceState {
    static let hiddenMessagesDefaultsKey = "hiddenMessageIdsByChat"

    private func hiddenMessagesScope(accountId: String, groupIdHex: String) -> HiddenMessageScope {
        HiddenMessageScope(accountId: accountId, groupIdHex: groupIdHex)
    }

    func loadHiddenMessages() {
        guard let hiddenMessageStore else { return }
        do {
            hiddenMessageIdsByChat = try hiddenMessageStore.loadAll()
        } catch {
            hiddenMessageLogger.error(
                "Failed to load protected hidden-message state: \(error.localizedDescription, privacy: .public)")
        }

        guard
            let legacy = UserDefaults.standard.dictionary(forKey: Self.hiddenMessagesDefaultsKey)
                as? [String: [String]]
        else { return }

        var migrationSucceeded = true
        for (key, messageIds) in legacy {
            let components = key.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else {
                migrationSucceeded = false
                continue
            }
            let scope = HiddenMessageScope(accountId: String(components[0]), groupIdHex: String(components[1]))
            hiddenMessageIdsByChat[scope, default: []].formUnion(messageIds)
            do {
                try hiddenMessageStore.write(hiddenMessageIdsByChat[scope] ?? [], for: scope)
            } catch {
                migrationSucceeded = false
                hiddenMessageLogger.error(
                    "Failed to migrate hidden-message state: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if migrationSucceeded {
            UserDefaults.standard.removeObject(forKey: Self.hiddenMessagesDefaultsKey)
        }
    }

    private func persistHiddenMessages(for scope: HiddenMessageScope) {
        guard let hiddenMessageStore else { return }
        do {
            if let ids = hiddenMessageIdsByChat[scope], !ids.isEmpty {
                try hiddenMessageStore.write(ids, for: scope)
            } else {
                try hiddenMessageStore.remove(for: scope)
            }
        } catch {
            hiddenMessageLogger.error(
                "Failed to persist hidden-message state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func hiddenMessageIds(accountId: String, groupIdHex: String) -> Set<String> {
        hiddenMessageIdsByChat[hiddenMessagesScope(accountId: accountId, groupIdHex: groupIdHex)] ?? []
    }

    /// Hide `messageId` locally: record it, persist, and drop it from the live window immediately.
    func hideMessageLocally(accountId: String, groupIdHex: String, messageId: String) {
        let scope = hiddenMessagesScope(accountId: accountId, groupIdHex: groupIdHex)
        var ids = hiddenMessageIdsByChat[scope] ?? []
        guard ids.insert(messageId).inserted else { return }
        hiddenMessageIdsByChat[scope] = ids
        persistHiddenMessages(for: scope)

        guard let store = messageTimelineStores[groupIdHex] else { return }
        let paging = timelinePagingByChat[groupIdHex] ?? .empty
        _ = store.applyProjection(
            upserts: [],
            removals: [messageId],
            editMutations: [],
            anchoredToNewest: !paging.hasMoreAfter,
            windowLimit: Self.timelineWindowLimit
        )
        selectedChatRevision &+= 1
    }

    /// Drop locally-hidden messages from a full window replacement (initial load, pagination,
    /// runtime re-window). Paired with `partitionHiddenMessages` on the incremental path so a hide
    /// survives every projection route, chat switch, and cold start.
    func filterHiddenMessages(_ messages: [MessageItem], groupIdHex: String) -> [MessageItem] {
        guard let activeAccountId else { return messages }
        let hidden = hiddenMessageIds(accountId: activeAccountId, groupIdHex: groupIdHex)
        guard !hidden.isEmpty else { return messages }
        return messages.filter { !hidden.contains($0.id) }
    }

    /// Forget the hidden set for a chat once it is removed, mirroring the per-chat caches.
    func purgeHiddenMessages(accountId: String, groupIdHex: String) {
        let scope = hiddenMessagesScope(accountId: accountId, groupIdHex: groupIdHex)
        hiddenMessageIdsByChat[scope] = nil
        persistHiddenMessages(for: scope)
    }

    /// Forget every hidden set for an account (account removal / full local wipe).
    func purgeHiddenMessages(accountId: String) {
        let scopes = hiddenMessageIdsByChat.keys.filter { $0.accountId == accountId }
        for scope in scopes {
            hiddenMessageIdsByChat[scope] = nil
            persistHiddenMessages(for: scope)
        }
    }

    /// Forget all hidden sets — part of the "Delete All Local Data" reset.
    func clearAllHiddenMessages() {
        hiddenMessageIdsByChat = [:]
        do {
            try hiddenMessageStore?.removeAll()
            UserDefaults.standard.removeObject(forKey: Self.hiddenMessagesDefaultsKey)
        } catch {
            hiddenMessageLogger.error(
                "Failed to clear hidden-message state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Split a projection batch for `groupIdHex` against the hidden set: hidden ids are removed
    /// from `upserts` and folded into `removals`, so a locally-hidden message stays gone across
    /// reprojection and cold start without any network round-trip.
    func partitionHiddenMessages(
        upserts: [MessageItem],
        removals: Set<String>,
        groupIdHex: String
    ) -> (upserts: [MessageItem], removals: Set<String>) {
        guard let activeAccountId else { return (upserts, removals) }
        let hidden = hiddenMessageIds(accountId: activeAccountId, groupIdHex: groupIdHex)
        guard !hidden.isEmpty else { return (upserts, removals) }
        let visibleUpserts = upserts.filter { !hidden.contains($0.id) }
        let hiddenInBatch = upserts.filter { hidden.contains($0.id) }.map(\.id)
        return (visibleUpserts, removals.union(hiddenInBatch))
    }
}
