import Foundation

nonisolated enum ChatListOrdering {
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
        upserting(
            chat,
            into: chats,
            existingIndex: chats.firstIndex(where: { $0.id == chat.id }),
            pinnedChatIds: pinnedChatIds
        )
    }

    static func upserting(
        _ chat: ChatItem,
        into chats: [ChatItem],
        existingIndex: Int?,
        pinnedChatIds: Set<String> = []
    ) -> [ChatItem] {
        var result = chats
        upsert(chat, into: &result, existingIndex: existingIndex, pinnedChatIds: pinnedChatIds)
        return result
    }

    /// Places `chat` in display order, mutating `chats` in place so a caller that passes its
    /// stored list (`&chatsByAccount[id, default: []]`) never copies the whole list per row.
    /// Returns the first index whose position changed, or `nil` when the row was replaced where
    /// it stood and no other row moved.
    @discardableResult
    static func upsert(
        _ chat: ChatItem,
        into chats: inout [ChatItem],
        existingIndex: Int?,
        pinnedChatIds: Set<String> = []
    ) -> Int? {
        if let index = existingIndex {
            if canReplaceInPlace(chat, at: index, in: chats, pinnedChatIds: pinnedChatIds) {
                chats[index] = chat
                return nil
            }
            chats.remove(at: index)
            let nextIndex = insertionIndex(for: chat, in: chats, pinnedChatIds: pinnedChatIds)
            chats.insert(chat, at: nextIndex)
            return min(index, nextIndex)
        }

        let nextIndex = insertionIndex(for: chat, in: chats, pinnedChatIds: pinnedChatIds)
        chats.insert(chat, at: nextIndex)
        return nextIndex
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
            // A nicknamed title only reverts through `publishedTitle`; dropping it here left the
            // nickname stuck on the row once it was cleared.
            publishedTitle: current.publishedTitle,
            subtitle: current.subtitle,
            preview: chat.preview,
            previewAttachmentKind: chat.previewAttachmentKind,
            previewAttribution: chat.previewAttribution,
            updatedAt: chat.updatedAt,
            lastMessageAt: chat.lastMessageAt,
            avatarSeed: current.avatarSeed,
            directPeerAccountIdHex: current.directPeerAccountIdHex,
            pictureURL: current.pictureURL,
            groupImagePayload: current.groupImagePayload,
            groupImageHashHex: current.groupImageHashHex,
            unreadCount: chat.unreadCount,
            hasUnread: chat.hasUnread,
            manuallyMarkedUnread: chat.manuallyMarkedUnread,
            unreadMentionCount: chat.unreadMentionCount,
            isDirect: chat.hasAuthoritativeConversationKind ? chat.isDirect : current.isDirect,
            hasAuthoritativeConversationKind: chat.hasAuthoritativeConversationKind,
            isAuthoritativeGroup: chat.isAuthoritativeGroup,
            muted: chat.muted,
            mutedUntilMs: chat.mutedUntilMs,
            leaveRequestPending: chat.leaveRequestPending,
            leaveBlocked: chat.leaveBlocked,
            latestMessageDelivery: chat.latestMessageDelivery,
            pendingConfirmation: chat.pendingConfirmation,
            selfMembership: chat.selfMembership,
            lifecycle: chat.lifecycle
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
