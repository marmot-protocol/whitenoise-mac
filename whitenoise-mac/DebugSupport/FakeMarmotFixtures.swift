// coverage:ignore-file
//  Test support compiled into DEBUG app builds alongside `FakeMarmotRuntime`, which needs it.
//  See that file for why it lives in the app target. Ignored by coverage: it is a test double.

#if DEBUG
    import CryptoKit
    import Foundation
    import MarmotKit

    nonisolated func appMessage(
        id: String,
        direction: String = "inbound",
        groupIdHex: String,
        sender: String,
        plaintext: String,
        contentTokens: MarkdownDocumentFfi = emptyMarkdownDocument(),
        kind: UInt64,
        tags: [MessageTagFfi] = [],
        recordedAt: UInt64
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: id,
            direction: direction,
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: kind,
            tags: tags,
            sticker: nil,
            sourceEpoch: nil,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
            recordedAt: recordedAt,
            receivedAt: recordedAt,
            invalidated: false
        )
    }

    nonisolated func projectedTimeline(from messages: [AppMessageRecordFfi]) -> TimelinePageFfi {
        let deletedMessageIds = Set(
            messages
                .filter { $0.kind == 5 }
                .compactMap { firstTagValue("e", in: $0.tags) }
        )
        let visibleMessages = messages.filter { message in
            message.kind != 5
                && message.kind != 7
                && !deletedMessageIds.contains(message.messageIdHex)
        }
        let visibleById = visibleMessages.reduce(into: [String: AppMessageRecordFfi]()) { result, message in
            result[message.messageIdHex] = message
        }
        let reactionsByTarget = Dictionary(
            grouping: messages.compactMap { message -> TimelineUserReactionFfi? in
                guard message.kind == 7,
                    !deletedMessageIds.contains(message.messageIdHex),
                    let targetMessageId = firstTagValue("e", in: message.tags)
                else {
                    return nil
                }

                let emoji = message.plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !emoji.isEmpty else { return nil }
                return TimelineUserReactionFfi(
                    reactionMessageIdHex: message.messageIdHex,
                    targetMessageIdHex: targetMessageId,
                    sender: message.sender,
                    emoji: emoji,
                    reactedAt: message.recordedAt
                )
            }, by: \.targetMessageIdHex)

        let timelineMessages = visibleMessages.map { message in
            TimelineMessageRecordFfi(
                messageIdHex: message.messageIdHex,
                sourceMessageIdHex: nil,
                direction: message.direction,
                groupIdHex: message.groupIdHex,
                sender: message.sender,
                plaintext: message.plaintext,
                contentTokens: message.contentTokens,
                kind: message.kind,
                tags: message.tags,
                timelineAt: message.recordedAt,
                receivedAt: message.receivedAt,
                replyToMessageIdHex: firstTagValue("q", in: message.tags),
                replyPreview: firstTagValue("q", in: message.tags).flatMap { replyId in
                    visibleById[replyId].map { reply in
                        TimelineReplyPreviewFfi(
                            messageIdHex: reply.messageIdHex,
                            sender: reply.sender,
                            plaintext: reply.plaintext,
                            contentTokens: reply.contentTokens,
                            kind: reply.kind,
                            mediaJson: nil,
                            media: [],
                            deleted: false,
                            invalidationStatus: nil
                        )
                    }
                },
                mediaJson: nil,
                media: [],
                groupSystem: nil,
                reactions: projectedReactionSummary(reactionsByTarget[message.messageIdHex] ?? []),
                deleted: false,
                deletedByMessageIdHex: nil,
                invalidationStatus: nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.timelineAt != rhs.timelineAt { return lhs.timelineAt < rhs.timelineAt }
            return lhs.messageIdHex < rhs.messageIdHex
        }

        return TimelinePageFfi(messages: timelineMessages, hasMoreBefore: false, hasMoreAfter: false)
    }

    nonisolated func pagedTimeline(
        from messages: [TimelineMessageRecordFfi],
        query: TimelineMessageQueryFfi
    ) -> TimelinePageFfi {
        let sortedMessages = messages.sorted { lhs, rhs in
            if lhs.timelineAt != rhs.timelineAt { return lhs.timelineAt < rhs.timelineAt }
            return lhs.messageIdHex < rhs.messageIdHex
        }
        let limit = Int(query.limit ?? 50)

        if let before = query.before, let beforeMessageId = query.beforeMessageId {
            let olderMessages = sortedMessages.filter { message in
                message.timelineAt < before
                    || (message.timelineAt == before && message.messageIdHex < beforeMessageId)
            }
            let pageMessages = Array(olderMessages.suffix(limit))
            return TimelinePageFfi(
                messages: pageMessages,
                hasMoreBefore: olderMessages.count > pageMessages.count,
                hasMoreAfter: true
            )
        }

        if let after = query.after, let afterMessageId = query.afterMessageId {
            let newerMessages = sortedMessages.filter { message in
                message.timelineAt > after
                    || (message.timelineAt == after && message.messageIdHex > afterMessageId)
            }
            let pageMessages = Array(newerMessages.prefix(limit))
            return TimelinePageFfi(
                messages: pageMessages,
                hasMoreBefore: true,
                hasMoreAfter: newerMessages.count > pageMessages.count
            )
        }

        let pageMessages = Array(sortedMessages.suffix(limit))
        return TimelinePageFfi(
            messages: pageMessages,
            hasMoreBefore: sortedMessages.count > pageMessages.count,
            hasMoreAfter: false
        )
    }

    nonisolated func timelineMessage(
        id: String,
        clientToken: String? = nil,
        sourceMessageIdHex: String? = nil,
        direction: String = "inbound",
        groupIdHex: String,
        sender: String,
        plaintext: String,
        kind: UInt64 = 9,
        tags: [MessageTagFfi] = [],
        recordedAt: UInt64,
        mediaJson: String? = nil,
        media: [MediaAttachmentReferenceFfi] = [],
        thread: TimelineThreadRefFfi? = nil,
        groupSystem: GroupSystemEventFfi? = nil,
        replyToMessageIdHex: String? = nil,
        replyPreview: TimelineReplyPreviewFfi? = nil,
        reactions: TimelineReactionSummaryFfi = projectedReactionSummary([]),
        contentTokens: MarkdownDocumentFfi = emptyMarkdownDocument(),
        deleted: Bool = false,
        invalidationStatus: String? = nil
    ) -> TimelineMessageRecordFfi {
        TimelineMessageRecordFfi(
            clientToken: clientToken,
            messageIdHex: id,
            sourceMessageIdHex: sourceMessageIdHex,
            direction: direction,
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: kind,
            tags: tags,
            timelineAt: recordedAt,
            receivedAt: recordedAt,
            replyToMessageIdHex: replyToMessageIdHex,
            replyPreview: replyPreview,
            mediaJson: mediaJson,
            media: media,
            thread: thread,
            groupSystem: groupSystem,
            reactions: reactions,
            deleted: deleted,
            deletedByMessageIdHex: nil,
            invalidationStatus: invalidationStatus
        )
    }

    nonisolated func desktopAccount() -> AccountSummaryFfi {
        AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
    }

    nonisolated func encryptedMediaComponent() -> AppGroupEncryptedMediaComponentFfi {
        AppGroupEncryptedMediaComponentFfi(
            componentId: 0,
            component: "",
            required: false,
            mediaFormat: "",
            allowedLocatorKinds: [],
            defaultBlobEndpoints: []
        )
    }
    nonisolated func awaitSubscriptionCancellation<T>() async -> T? {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                break
            }
        }
        return nil
    }

    nonisolated func projectedReactionSummary(_ reactions: [TimelineUserReactionFfi]) -> TimelineReactionSummaryFfi {
        let byEmoji = Dictionary(grouping: reactions, by: \.emoji)
            .map { emoji, reactions in
                TimelineReactionEmojiFfi(emoji: emoji, count: UInt32(reactions.count), senders: reactions.map(\.sender))
            }
            .sorted { lhs, rhs in
                if lhs.senders.count != rhs.senders.count {
                    return lhs.senders.count > rhs.senders.count
                }
                return lhs.emoji < rhs.emoji
            }

        return TimelineReactionSummaryFfi(byEmoji: byEmoji, userReactions: reactions)
    }

    nonisolated func firstTagValue(_ name: String, in tags: [MessageTagFfi]) -> String? {
        tags.first { tag in
            tag.values.first == name && tag.values.count > 1
        }?.values[1]
    }
    nonisolated func emptyMarkdownDocument() -> MarkdownDocumentFfi {
        MarkdownDocumentFfi(blocks: [], truncated: false)
    }
    nonisolated func emptyTimelinePage() -> TimelinePageFfi {
        TimelinePageFfi(
            messages: [],
            hasMoreBefore: false,
            hasMoreAfter: false
        )
    }
    nonisolated func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
#endif
