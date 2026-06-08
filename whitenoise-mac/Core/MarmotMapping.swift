import Foundation
import MarmotKit

extension AccountItem {
    init(summary: AccountSummaryFfi) {
        let title = summary.label.isEmpty ? DisplayText.short(summary.accountIdHex) : summary.label
        self.init(
            id: summary.label.isEmpty ? summary.accountIdHex : summary.label,
            accountRef: summary.label,
            displayName: title,
            accountIdHex: summary.accountIdHex,
            localSigning: summary.localSigning,
            isRunning: summary.running
        )
    }
}

extension ChatItem {
    init(row: ChatListRowFfi, activeAccountIdHex: String?, directPeer: ChatPeerProfile? = nil) {
        let groupName = row.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let peerName = directPeer?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectedTitle = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let peerName, !peerName.isEmpty {
            title = peerName
        } else if !projectedTitle.isEmpty {
            title = projectedTitle
        } else if !groupName.isEmpty {
            title = groupName
        } else {
            title = DisplayText.short(directPeer?.accountIdHex ?? row.groupIdHex)
        }
        let preview = row.lastMessage.map { ChatItem.previewText(for: $0, activeAccountIdHex: activeAccountIdHex) }
        let timestamp = row.lastMessage?.timelineAt ?? row.updatedAt
        let updatedAt = timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
        let subtitle: String
        if row.pendingConfirmation {
            subtitle = L10n.string("Pending invite")
        } else if row.archived {
            subtitle = L10n.string("Archived")
        } else if directPeer != nil {
            subtitle = L10n.string("Direct message")
        } else if !groupName.isEmpty {
            subtitle = groupName
        } else {
            subtitle = L10n.string("Group message")
        }

        self.init(
            id: row.groupIdHex,
            title: title,
            subtitle: subtitle,
            preview: preview?.isEmpty == false ? preview! : L10n.string("No messages yet"),
            updatedAt: updatedAt,
            avatarSeed: directPeer?.accountIdHex ?? row.groupIdHex,
            pictureURL: directPeer?.pictureURL,
            unreadCount: Int(row.unreadCount)
        )
    }

    private static func previewText(for preview: ChatListMessagePreviewFfi, activeAccountIdHex: String?) -> String {
        if preview.deleted {
            return L10n.string("Message deleted")
        }

        let text = preview.plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return L10n.string("Unsupported message") }
        guard preview.sender != activeAccountIdHex,
              let senderName = preview.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !senderName.isEmpty
        else {
            return text
        }

        return "\(senderName): \(text)"
    }
}

extension MessageItem {
    init(record: TimelineMessageRecordFfi, activeAccountIdHex: String?) {
        self.init(
            record: record,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: [:],
            reactions: MessageReaction.summarize(record.reactions, activeAccountIdHex: activeAccountIdHex),
            replyContext: MessageItem.replyContext(
                for: record.replyPreview,
                senderProfiles: [:]
            )
        )
    }

    private init(
        record: TimelineMessageRecordFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile],
        reactions: [MessageReaction],
        replyContext: MessageReplyContext?
    ) {
        let senderProfile = senderProfiles[record.sender]
        self.init(
            id: record.messageIdHex,
            senderAccountIdHex: record.sender,
            senderName: MessageItem.displayName(for: record.sender, profile: senderProfile),
            senderPictureURL: senderProfile?.pictureURL,
            body: MessageItem.bodyText(plaintext: record.plaintext, deleted: record.deleted),
            sentAt: Date(timeIntervalSince1970: TimeInterval(record.timelineAt)),
            timelineKind: record.kind,
            isDeleted: record.deleted,
            isOutgoing: record.sender == activeAccountIdHex || record.direction.lowercased() == "outbound",
            reactions: reactions,
            replyContext: replyContext
        )
    }

    static func timeline(
        from page: TimelinePageFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile] = [:]
    ) -> [MessageItem] {
        page.messages
            .map { record in
                MessageItem(
                    record: record,
                    activeAccountIdHex: activeAccountIdHex,
                    senderProfiles: senderProfiles,
                    reactions: MessageReaction.summarize(record.reactions, activeAccountIdHex: activeAccountIdHex),
                    replyContext: MessageItem.replyContext(
                        for: record.replyPreview,
                        senderProfiles: senderProfiles
                    )
                )
            }
            .sorted { $0.sentAt < $1.sentAt }
    }

    private static func bodyText(plaintext: String, deleted: Bool) -> String {
        if deleted {
            return L10n.string("Message deleted")
        }

        let body = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? L10n.string("Unsupported message") : body
    }

    private static func replyContext(
        for preview: TimelineReplyPreviewFfi?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> MessageReplyContext? {
        guard let preview else { return nil }
        return MessageReplyContext(
            targetMessageId: preview.messageIdHex,
            senderName: MessageItem.displayName(for: preview.sender, profile: senderProfiles[preview.sender]),
            body: bodyText(plaintext: preview.plaintext, deleted: preview.deleted)
        )
    }

    private static func displayName(for sender: String, profile: ChatPeerProfile?) -> String {
        for value in [profile?.displayName] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return DisplayText.short(sender)
    }
}

private extension MessageReaction {
    static func summarize(_ summary: TimelineReactionSummaryFfi, activeAccountIdHex: String?) -> [MessageReaction] {
        summary.byEmoji
            .map { reaction in
                MessageReaction(
                    emoji: reaction.emoji,
                    count: reaction.senders.count,
                    isOwn: activeAccountIdHex.map { reaction.senders.contains($0) } ?? false
                )
        }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.emoji < rhs.emoji
            }
    }
}
