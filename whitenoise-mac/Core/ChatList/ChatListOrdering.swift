import Foundation

nonisolated enum ChatListOrdering {
    struct UpsertResult {
        let chats: [ChatItem]
        let reindexStart: Int?
    }

    static func sorted(_ chatItems: [ChatItem], pinnedChatIds: Set<String> = []) -> [ChatItem] {
        chatItems.sorted { lhs, rhs in
            areInDisplayOrder(lhs, rhs, pinnedChatIds: pinnedChatIds)
        }
    }

    static func upserting(
        _ chat: ChatItem,
        into chats: [ChatItem],
        pinnedChatIds: Set<String> = []
    ) -> [ChatItem] {
        upsertResult(
            chat,
            into: chats,
            existingIndex: chats.firstIndex(where: { $0.id == chat.id }),
            pinnedChatIds: pinnedChatIds
        ).chats
    }

    static func upserting(
        _ chat: ChatItem,
        into chats: [ChatItem],
        existingIndex: Int?,
        pinnedChatIds: Set<String> = []
    ) -> [ChatItem] {
        upsertResult(chat, into: chats, existingIndex: existingIndex, pinnedChatIds: pinnedChatIds).chats
    }

    static func upsertResult(
        _ chat: ChatItem,
        into chats: [ChatItem],
        existingIndex: Int?,
        pinnedChatIds: Set<String> = []
    ) -> UpsertResult {
        var result = chats
        if let index = existingIndex {
            if canReplaceInPlace(chat, at: index, in: result, pinnedChatIds: pinnedChatIds) {
                result[index] = chat
                return UpsertResult(chats: result, reindexStart: nil)
            }
            result.remove(at: index)
            let nextIndex = insertionIndex(for: chat, in: result, pinnedChatIds: pinnedChatIds)
            result.insert(chat, at: nextIndex)
            return UpsertResult(chats: result, reindexStart: min(index, nextIndex))
        }

        let nextIndex = insertionIndex(for: chat, in: result, pinnedChatIds: pinnedChatIds)
        result.insert(chat, at: nextIndex)
        return UpsertResult(chats: result, reindexStart: nextIndex)
    }

    static func mostRecent(in chatItems: [ChatItem]) -> ChatItem? {
        chatItems.min { lhs, rhs in
            areInDisplayOrder(lhs, rhs)
        }
    }

    static func preservingResolvedMetadata(in chat: ChatItem, from current: ChatItem) -> ChatItem {
        ChatItem(
            id: chat.id,
            title: current.title,
            subtitle: current.subtitle,
            preview: chat.preview,
            previewAttachmentKind: chat.previewAttachmentKind,
            previewAttribution: chat.previewAttribution,
            updatedAt: chat.updatedAt,
            avatarSeed: current.avatarSeed,
            pictureURL: current.pictureURL,
            groupImagePayload: current.groupImagePayload,
            groupImageHashHex: current.groupImageHashHex,
            unreadCount: chat.unreadCount,
            hasUnread: chat.hasUnread,
            manuallyMarkedUnread: chat.manuallyMarkedUnread,
            unreadMentionCount: chat.unreadMentionCount,
            isDirect: chat.hasAuthoritativeConversationKind ? chat.isDirect : current.isDirect,
            hasAuthoritativeConversationKind: chat.hasAuthoritativeConversationKind,
            muted: chat.muted,
            mutedUntilMs: chat.mutedUntilMs,
            leaveRequestPending: chat.leaveRequestPending,
            latestMessageDelivery: chat.latestMessageDelivery,
            pendingConfirmation: chat.pendingConfirmation,
            selfMembership: chat.selfMembership
        )
    }

    static func isOlder(_ candidate: ChatItem, than current: ChatItem) -> Bool {
        guard let currentUpdatedAt = current.updatedAt else { return false }
        guard let candidateUpdatedAt = candidate.updatedAt else { return true }
        return candidateUpdatedAt < currentUpdatedAt
    }

    private static func canReplaceInPlace(
        _ chat: ChatItem,
        at index: Int,
        in chats: [ChatItem],
        pinnedChatIds: Set<String>
    ) -> Bool {
        let previousStillBefore =
            index == chats.startIndex
            || !areInDisplayOrder(chat, chats[index - 1], pinnedChatIds: pinnedChatIds)
        let nextStillAfter: Bool
        if index == chats.index(before: chats.endIndex) {
            nextStillAfter = true
        } else {
            nextStillAfter = !areInDisplayOrder(chats[index + 1], chat, pinnedChatIds: pinnedChatIds)
        }
        return previousStillBefore && nextStillAfter
    }

    private static func insertionIndex(
        for chat: ChatItem,
        in chats: [ChatItem],
        pinnedChatIds: Set<String>
    ) -> Int {
        var lowerBound = chats.startIndex
        var upperBound = chats.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if areInDisplayOrder(chats[middle], chat, pinnedChatIds: pinnedChatIds) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private static func areInDisplayOrder(
        _ lhs: ChatItem,
        _ rhs: ChatItem,
        pinnedChatIds: Set<String> = []
    ) -> Bool {
        let lhsPinned = pinnedChatIds.contains(lhs.id)
        let rhsPinned = pinnedChatIds.contains(rhs.id)
        if lhsPinned != rhsPinned { return lhsPinned }

        switch (lhs.updatedAt, rhs.updatedAt) {
        case (let left?, let right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
