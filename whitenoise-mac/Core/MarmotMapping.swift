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
    init(
        row: ChatListRowFfi,
        activeAccountIdHex: String?,
        directPeer: ChatPeerProfile? = nil,
        groupAvatarURL: String? = nil
    ) {
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
            pictureURL: directPeer?.pictureURL ?? groupAvatarURL,
            unreadCount: Int(row.unreadCount),
            isDirect: directPeer != nil
        )
    }

    private static func previewText(for preview: ChatListMessagePreviewFfi, activeAccountIdHex: String?) -> String {
        if preview.deleted {
            return L10n.string("Message deleted")
        }

        let presentation = MessageItem.presentation(for: preview.kind)
        let text = MessageItem.displayText(
            kind: preview.kind,
            plaintext: preview.plaintext,
            tags: [],
            deleted: preview.deleted,
            invalidationStatus: nil
        )
        guard !text.isEmpty else { return L10n.string("Unsupported message") }
        guard presentation.isChatBubble,
              preview.sender != activeAccountIdHex,
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
        let presentation = MessageItem.presentation(for: record.kind)
        self.init(
            id: record.messageIdHex,
            senderAccountIdHex: record.sender,
            senderName: MessageItem.senderName(
                for: record.sender,
                profile: senderProfile,
                presentation: presentation
            ),
            senderPictureURL: senderProfile?.pictureURL,
            body: MessageItem.displayText(
                kind: record.kind,
                plaintext: record.plaintext,
                tags: record.tags,
                deleted: record.deleted,
                invalidationStatus: record.invalidationStatus
            ),
            sentAt: Date(timeIntervalSince1970: TimeInterval(record.timelineAt)),
            timelineAt: record.timelineAt,
            timelineKind: record.kind,
            isDeleted: record.deleted,
            invalidationStatus: record.invalidationStatus,
            isOutgoing: presentation.isChatBubble && (record.sender == activeAccountIdHex || record.direction.lowercased() == "outbound"),
            reactions: presentation.isChatBubble ? reactions : [],
            replyContext: presentation.isChatBubble ? replyContext : nil,
            presentation: presentation
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

    fileprivate static func presentation(for kind: UInt64) -> MessagePresentation {
        switch kind {
        case MarmotTimelineKind.chat:
            return .chat
        case MarmotTimelineKind.agentStreamStart:
            return .agentStreamStart
        case MarmotTimelineKind.agentActivity:
            return .agentActivity
        case MarmotTimelineKind.agentOperation:
            return .agentOperation
        case MarmotTimelineKind.groupSystem:
            return .groupSystem
        default:
            return .unsupported
        }
    }

    fileprivate static func displayText(
        kind: UInt64,
        plaintext: String,
        tags: [MessageTagFfi],
        deleted: Bool,
        invalidationStatus: String? = nil
    ) -> String {
        if invalidationStatus != nil {
            return L10n.string("Message did not reach the group")
        }

        if deleted {
            return L10n.string("Message deleted")
        }

        let body = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        let messagePresentation = presentation(for: kind)

        // Plain chat messages never consult the JSON payload, so skip decoding it for
        // the common case (this runs for every message during mapping).
        if case .chat = messagePresentation {
            return body.isEmpty ? L10n.string("Unsupported message") : body
        }

        let payload = TimelinePayload.decode(from: body)

        switch messagePresentation {
        case .chat:
            return body.isEmpty ? L10n.string("Unsupported message") : body
        case .agentStreamStart:
            if tagValue("route", in: tags) == "quic" {
                return L10n.string("Agent started a live response")
            }
            return L10n.string("Agent started a response")
        case .agentActivity:
            return firstNonBlank([
                payload?.text,
                payload?.status.map { "\(L10n.string("Agent activity")): \(humanized($0))" },
                payload == nil ? body : nil
            ]) ?? L10n.string("Agent activity")
        case .agentOperation:
            if let text = firstNonBlank([payload?.text, payload?.preview]) {
                return text
            }
            if let name = payload?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
               let status = payload?.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
                return "\(name) \(humanized(status))"
            }
            if let eventType = payload?.eventType?.trimmingCharacters(in: .whitespacesAndNewlines), !eventType.isEmpty {
                return "\(L10n.string("Agent operation")): \(humanized(eventType))"
            }
            if payload == nil, !body.isEmpty {
                return body
            }
            return L10n.string("Agent operation")
        case .groupSystem:
            if let text = firstNonBlank([payload?.text]) {
                return text
            }
            if payload == nil, !body.isEmpty {
                return body
            }
            return groupSystemFallback(payload?.systemType ?? tagValue("system", in: tags))
        case .unsupported:
            return body.isEmpty ? L10n.string("Unsupported message") : body
        }
    }

    private static func replyContext(
        for preview: TimelineReplyPreviewFfi?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> MessageReplyContext? {
        guard let preview else { return nil }
        return MessageReplyContext(
            targetMessageId: preview.messageIdHex,
            senderName: MessageItem.displayName(for: preview.sender, profile: senderProfiles[preview.sender]),
            body: displayText(
                kind: preview.kind,
                plaintext: preview.plaintext,
                tags: [],
                deleted: preview.deleted
            )
        )
    }

    private static func senderName(
        for sender: String,
        profile: ChatPeerProfile?,
        presentation: MessagePresentation
    ) -> String {
        switch presentation {
        case .agentStreamStart, .agentActivity, .agentOperation:
            return L10n.string("Agent")
        case .groupSystem:
            return L10n.string("System")
        case .chat, .unsupported:
            return displayName(for: sender, profile: profile)
        }
    }

    private static func displayName(for sender: String, profile: ChatPeerProfile?) -> String {
        firstNonBlank([profile?.displayName]) ?? DisplayText.short(sender)
    }

    private static func tagValue(_ name: String, in tags: [MessageTagFfi]) -> String? {
        tags.first { $0.values.first == name }?.values.dropFirst().first
    }

    private static func humanized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func groupSystemFallback(_ systemType: String?) -> String {
        switch systemType {
        case "member_added":
            return L10n.string("Member added")
        case "member_removed":
            return L10n.string("Member removed")
        case "member_left":
            return L10n.string("Member left")
        case "admin_added":
            return L10n.string("Admin added")
        case "admin_removed":
            return L10n.string("Admin removed")
        case "group_renamed":
            return L10n.string("Group renamed")
        case "group_avatar_changed":
            return L10n.string("Group avatar changed")
        default:
            return L10n.string("Group updated")
        }
    }
}

private enum MarmotTimelineKind {
    static let chat: UInt64 = 9
    static let agentStreamStart: UInt64 = 1200
    static let agentActivity: UInt64 = 1201
    static let agentOperation: UInt64 = 1202
    static let groupSystem: UInt64 = 1210
}

private struct TimelinePayload: Decodable {
    let text: String?
    let status: String?
    let eventType: String?
    let name: String?
    let preview: String?
    let systemType: String?

    enum CodingKeys: String, CodingKey {
        case text
        case status
        case eventType = "event_type"
        case name
        case preview
        case systemType = "system_type"
    }

    private static let decoder = JSONDecoder()

    static func decode(from text: String) -> TimelinePayload? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? decoder.decode(TimelinePayload.self, from: data)
    }
}

private extension MessageReaction {
    static func summarize(_ summary: TimelineReactionSummaryFfi, activeAccountIdHex: String?) -> [MessageReaction] {
        summary.byEmoji
            .map { reaction in
                let ownReactionMessageId = activeAccountIdHex.flatMap { accountIdHex in
                    summary.userReactions.first { userReaction in
                        userReaction.emoji == reaction.emoji && userReaction.sender == accountIdHex
                    }?.reactionMessageIdHex
                }
                let isOwn = activeAccountIdHex.map { reaction.senders.contains($0) } ?? false

                return MessageReaction(
                    emoji: reaction.emoji,
                    count: reaction.senders.count,
                    isOwn: isOwn,
                    ownReactionMessageId: ownReactionMessageId
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.emoji < rhs.emoji
            }
    }
}
