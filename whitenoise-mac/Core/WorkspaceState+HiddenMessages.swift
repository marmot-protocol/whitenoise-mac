//
//  WorkspaceState+HiddenMessages.swift
//  whitenoise-mac
//
//  "Delete for me" — a local, per-account/group set of hidden message ids. Hiding publishes
//  nothing; the ids are filtered from the timeline projection so a hide survives reprojection
//  and restart, and persisted in UserDefaults.
//

import Foundation

@MainActor
extension WorkspaceState {
    static let hiddenMessagesDefaultsKey = "hiddenMessageIdsByChat"

    private func hiddenMessagesKey(accountId: String, groupIdHex: String) -> String {
        "\(accountId)\u{1F}\(groupIdHex)"
    }

    func loadHiddenMessages() {
        guard
            let raw = UserDefaults.standard.dictionary(forKey: Self.hiddenMessagesDefaultsKey)
                as? [String: [String]]
        else { return }
        hiddenMessageIdsByChat = raw.mapValues(Set.init)
    }

    private func persistHiddenMessages() {
        let encodable = hiddenMessageIdsByChat.mapValues(Array.init)
        UserDefaults.standard.set(encodable, forKey: Self.hiddenMessagesDefaultsKey)
    }

    func hiddenMessageIds(accountId: String, groupIdHex: String) -> Set<String> {
        hiddenMessageIdsByChat[hiddenMessagesKey(accountId: accountId, groupIdHex: groupIdHex)] ?? []
    }

    /// Hide `messageId` locally: record it, persist, and drop it from the live window immediately.
    func hideMessageLocally(accountId: String, groupIdHex: String, messageId: String) {
        let key = hiddenMessagesKey(accountId: accountId, groupIdHex: groupIdHex)
        var ids = hiddenMessageIdsByChat[key] ?? []
        guard ids.insert(messageId).inserted else { return }
        hiddenMessageIdsByChat[key] = ids
        persistHiddenMessages()

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
        hiddenMessageIdsByChat[hiddenMessagesKey(accountId: accountId, groupIdHex: groupIdHex)] = nil
        persistHiddenMessages()
    }

    /// Forget every hidden set for an account (account removal / full local wipe).
    func purgeHiddenMessages(accountId: String) {
        let prefix = "\(accountId)\u{1F}"
        hiddenMessageIdsByChat = hiddenMessageIdsByChat.filter { !$0.key.hasPrefix(prefix) }
        persistHiddenMessages()
    }

    /// Forget all hidden sets — part of the "Delete All Local Data" reset.
    func clearAllHiddenMessages() {
        guard !hiddenMessageIdsByChat.isEmpty else { return }
        hiddenMessageIdsByChat = [:]
        persistHiddenMessages()
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
