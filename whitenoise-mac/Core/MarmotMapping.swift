import Foundation
import MarmotKit
import OSLog

extension AccountItem {
    nonisolated init(summary: AccountSummaryFfi) {
        let title = summary.label.isEmpty ? DisplayText.short(summary.accountIdHex) : summary.label
        self.init(
            id: summary.label.isEmpty ? summary.accountIdHex : summary.label,
            accountRef: summary.label,
            displayName: title,
            accountIdHex: summary.accountIdHex,
            localSigning: summary.localSigning,
            externalSigning: summary.externalSigning,
            isRunning: summary.running,
            signedOut: summary.signedOut
        )
    }
}

extension ChatSelfMembership {
    nonisolated init(_ membership: SelfMembershipFfi) {
        switch membership {
        case .member:
            self = .member
        case .left:
            self = .left
        case .removed:
            self = .removed
        }
    }
}

extension ChatItem {
    init(
        row: ChatListRowFfi,
        activeAccountIdHex: String?,
        directPeer: ChatPeerProfile? = nil,
        groupAvatarURL: String? = nil
    ) {
        let groupName = PeerDisplayText.sanitize(row.groupName) ?? ""
        let peerName = PeerDisplayText.sanitize(directPeer?.displayName)
        let projectedTitle = PeerDisplayText.sanitize(row.title) ?? ""
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
        let previewTimestamp = row.lastMessage?.timelineAt ?? 0
        let timestamp = previewTimestamp > 0 ? previewTimestamp : row.updatedAt
        let updatedAt = timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
        let subtitle: String
        if row.archived {
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
            unreadCount: Int(clamping: row.unreadCount),
            unreadMentionCount: Int(clamping: row.unreadMentionCount),
            isDirect: directPeer != nil,
            pendingConfirmation: row.pendingConfirmation,
            selfMembership: ChatSelfMembership(row.selfMembership)
        )
    }

    private static func previewText(for preview: ChatListMessagePreviewFfi, activeAccountIdHex: String?) -> String {
        if preview.deleted {
            return L10n.string("Message deleted")
        }

        let presentation = MessageItem.presentation(for: preview.kind)
        let text = MessageItem.displayText(
            presentation: presentation,
            plaintext: preview.plaintext,
            tags: [],
            deleted: preview.deleted,
            invalidationStatus: nil,
            hasMediaAttachments: false
        )
        // `ChatListMessagePreviewFfi` carries no media payload, so a media-only chat
        // message arrives with empty `plaintext` and `displayText` reports it as
        // "Unsupported message". Only treat that sentinel as media-only when the
        // source preview text is empty; a user can send that literal text.
        let sourceTextIsEmpty = preview.plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isMediaOnlyChat =
            presentation.isChatBubble
            && sourceTextIsEmpty
            && text == L10n.string("Unsupported message")
        // Resolve the body first so the sender prefix applies to media-only previews too, not
        // just text — otherwise a group attachment shows up unattributed.
        let body: String
        if text.isEmpty || isMediaOnlyChat {
            body = presentation.isChatBubble ? L10n.string("Attachment") : L10n.string("Unsupported message")
        } else {
            body = text
        }
        guard presentation.isChatBubble,
            preview.sender != activeAccountIdHex,
            let senderName = PeerDisplayText.sanitize(preview.senderDisplayName),
            !senderName.isEmpty
        else {
            return body
        }

        return "\(PeerDisplayText.templateFragment(senderName)): \(body)"
    }
}

nonisolated enum MessageEditMutation: Equatable, Sendable {
    case upsert(MessageEditOverlay)
    case retract(editMessageIdHex: String)
}

nonisolated struct MessageEditOverlay: Equatable, Sendable {
    let targetMessageIdHex: String
    let editMessageIdHex: String
    let sender: String
    let plaintext: String
    let timelineAt: UInt64

    static func mutations(from records: [TimelineMessageRecordFfi]) -> [MessageEditMutation] {
        records.compactMap { record in
            guard record.kind == MarmotTimelineKind.messageEdit else { return nil }
            if record.deleted || record.invalidationStatus != nil {
                return .retract(editMessageIdHex: record.messageIdHex)
            }
            guard let targetId = editTargetMessageId(in: record.tags) else {
                return .retract(editMessageIdHex: record.messageIdHex)
            }
            return .upsert(
                MessageEditOverlay(
                    targetMessageIdHex: targetId,
                    editMessageIdHex: record.messageIdHex,
                    sender: record.sender,
                    plaintext: record.plaintext,
                    timelineAt: record.timelineAt
                )
            )
        }
    }

    static func shouldPrefer(_ candidate: MessageEditOverlay, over existing: MessageEditOverlay?) -> Bool {
        guard let existing else { return true }
        if candidate.timelineAt != existing.timelineAt {
            return candidate.timelineAt > existing.timelineAt
        }
        return candidate.editMessageIdHex > existing.editMessageIdHex
    }

    fileprivate static func editTargetMessageId(in tags: [MessageTagFfi]) -> String? {
        var target: String?
        for tag in tags where tag.values.first == "e" {
            guard tag.values.count == 2,
                let candidate = tag.values.dropFirst().first?.nilIfBlank,
                target == nil
            else {
                return nil
            }
            target = candidate
        }
        return target
    }
}

// The whole timeline record → view-model transformation is pure (it only reads the
// `Sendable` FFI record and the resolved sender-profile map) and is deliberately run
// off the main actor while mapping a window/projection so the attributed-string /
// Markdown-AST build and media-JSON parse do not block the UI thread. `nonisolated`
// opts these out of the module's default main-actor isolation
// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) so they can be called from the
// `@Sendable` off-main closure in `WorkspaceState+Timeline`. See whitenoise-mac#285.
nonisolated extension MessageItem {
    private init(
        record: TimelineMessageRecordFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile],
        editedPlaintext: String? = nil,
        isEdited: Bool = false,
        reactions: [MessageReaction],
        replyContext: MessageReplyContext?
    ) {
        let senderProfile = senderProfiles[record.sender]
        let presentation = MessageItem.presentation(for: record.kind)
        let plaintext = editedPlaintext ?? record.plaintext
        let mediaAttachments = MessageMediaParser.attachments(
            resolvedMedia: record.media,
            mediaJson: record.mediaJson,
            tags: record.tags,
            messageIdHex: record.messageIdHex
        )
        let body =
            MessageItem.systemText(
                record.groupSystem,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            )
            ?? MessageItem.displayText(
                presentation: presentation,
                plaintext: plaintext,
                tags: record.tags,
                deleted: record.deleted,
                invalidationStatus: record.invalidationStatus,
                hasMediaAttachments: !mediaAttachments.isEmpty
            )

        self.init(
            id: record.messageIdHex,
            groupIdHex: record.groupIdHex,
            sourceMessageIdHex: record.sourceMessageIdHex,
            replyTargetIdHex: record.replyToMessageIdHex,
            senderAccountIdHex: record.sender,
            senderName: MessageItem.senderName(
                for: record.sender,
                profile: senderProfile,
                presentation: presentation
            ),
            senderPictureURL: senderProfile?.pictureURL,
            body: body,
            contentMarkdown: isEdited
                ? nil
                : MessageItem.renderableMarkdown(
                    document: record.contentTokens,
                    displayedBody: body,
                    deleted: record.deleted,
                    invalidationStatus: record.invalidationStatus,
                    presentation: presentation
                ),
            sentAt: Date(timeIntervalSince1970: TimeInterval(record.timelineAt)),
            timelineAt: record.timelineAt,
            timelineKind: record.kind,
            isDeleted: record.deleted,
            invalidationStatus: record.invalidationStatus,
            isEdited: isEdited,
            isOutgoing: presentation.isChatBubble
                && (record.sender == activeAccountIdHex || record.direction.lowercased() == "outbound"),
            reactions: presentation.isChatBubble ? reactions : [],
            replyContext: presentation.isChatBubble ? replyContext : nil,
            mediaAttachments: presentation.isChatBubble ? mediaAttachments : [],
            presentation: presentation
        )
    }

    static func timeline(
        from page: TimelinePageFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile] = [:]
    ) -> [MessageItem] {
        // MarmotKit returns an authoritative timeline window. Keep that order
        // intact: `timelineAt` is second-granular, and re-sorting in the client
        // can reshuffle records that the runtime/database already tie-broke.
        return page.messages.compactMap { record in
            guard record.kind != MarmotTimelineKind.messageEdit else { return nil }
            return MessageItem(
                record: record,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles,
                reactions: MessageReaction.summarize(
                    record.reactions,
                    activeAccountIdHex: activeAccountIdHex
                ),
                replyContext: MessageItem.replyContext(
                    for: record.replyPreview,
                    senderProfiles: senderProfiles
                )
            )
        }
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

    /// The core's structured rendering for a group-system row (member changes,
    /// disappearing-timer changes, etc.), or `nil` when the record isn't a system
    /// event — in which case the caller falls back to the kind-based decode.
    fileprivate static func systemText(
        _ event: GroupSystemEventFfi?,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> String? {
        guard let event else { return nil }
        switch event.systemType {
        case "member_added":
            if let text = memberAddedText(
                event,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            ) {
                return text
            }
        case "member_removed":
            if let text = memberRemovedText(
                event,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            ) {
                return text
            }
        case "member_left":
            if let text = memberLeftText(
                event,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            ) {
                return text
            }
        case "admin_added":
            if let text = adminAddedText(
                event,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            ) {
                return text
            }
        case "admin_removed":
            if let text = adminRemovedText(
                event,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            ) {
                return text
            }
        case "group_renamed":
            if let text = groupRenamedText(
                event,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            ) {
                return text
            }
        case "group_avatar_changed":
            if let text = groupAvatarChangedText(
                event,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            ) {
                return text
            }
        case "disappearing_timer_changed":
            if let text = disappearingTimerChangedText(
                event,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            ) {
                return text
            }
        default:
            break
        }

        return PeerDisplayText.sanitize(event.text) ?? groupSystemFallback(event.systemType)
    }

    private static func memberAddedText(
        _ event: GroupSystemEventFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> String? {
        let actorName = systemAccountName(
            event.actorAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )
        let subjectName = systemAccountName(
            event.subjectAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .object
        )
        let subjectStartName = systemAccountName(
            event.subjectAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )

        if let actorName, let subjectName {
            if event.actorAccountIdHex == event.subjectAccountIdHex {
                return String(format: L10n.string("%@ joined"), subjectStartName ?? actorName)
            }
            return String(format: L10n.string("%@ added %@"), actorName, subjectName)
        }
        if let subjectStartName {
            return String(format: L10n.string("%@ was added"), subjectStartName)
        }
        if let actorName {
            return String(format: L10n.string("%@ added a member"), actorName)
        }
        return nil
    }

    private static func memberRemovedText(
        _ event: GroupSystemEventFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> String? {
        let actorName = systemAccountName(
            event.actorAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )
        let subjectName = systemAccountName(
            event.subjectAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .object
        )
        let subjectStartName = systemAccountName(
            event.subjectAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )

        if let actorName, let subjectName {
            if event.actorAccountIdHex == event.subjectAccountIdHex {
                return String(format: L10n.string("%@ left the group"), subjectStartName ?? actorName)
            }
            if event.subjectAccountIdHex == activeAccountIdHex {
                return String(format: L10n.string("You were removed from the group by %@"), actorName)
            }
            return String(format: L10n.string("%@ removed %@"), actorName, subjectName)
        }
        if let subjectStartName {
            return String(format: L10n.string("%@ was removed"), subjectStartName)
        }
        if let actorName {
            return String(format: L10n.string("%@ removed a member"), actorName)
        }
        return nil
    }

    private static func memberLeftText(
        _ event: GroupSystemEventFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> String? {
        let subjectName =
            systemAccountName(
                event.subjectAccountIdHex,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles,
                position: .subject
            )
            ?? systemAccountName(
                event.actorAccountIdHex,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles,
                position: .subject
            )
        return subjectName.map { String(format: L10n.string("%@ left"), $0) }
    }

    private static func adminAddedText(
        _ event: GroupSystemEventFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> String? {
        let actorName = systemAccountName(
            event.actorAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )
        let subjectName = systemAccountName(
            event.subjectAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .object
        )
        let subjectStartName = systemAccountName(
            event.subjectAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )

        if let actorName, let subjectName {
            if event.actorAccountIdHex == event.subjectAccountIdHex {
                return String(format: L10n.string("%@ became an admin"), subjectStartName ?? actorName)
            }
            return String(format: L10n.string("%@ made %@ an admin"), actorName, subjectName)
        }
        if let subjectStartName {
            if event.subjectAccountIdHex == activeAccountIdHex {
                return L10n.string("You were made an admin")
            }
            return String(format: L10n.string("%@ was made an admin"), subjectStartName)
        }
        if let actorName {
            return String(format: L10n.string("%@ added an admin"), actorName)
        }
        return nil
    }

    private static func adminRemovedText(
        _ event: GroupSystemEventFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> String? {
        let actorName = systemAccountName(
            event.actorAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )
        let subjectName = systemAccountName(
            event.subjectAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .object
        )
        let subjectStartName = systemAccountName(
            event.subjectAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )

        if let actorName, let subjectName {
            if event.actorAccountIdHex == event.subjectAccountIdHex {
                return String(format: L10n.string("%@ stepped down as admin"), subjectStartName ?? actorName)
            }
            if event.subjectAccountIdHex == activeAccountIdHex {
                return String(format: L10n.string("You were removed as admin by %@"), actorName)
            }
            return String(format: L10n.string("%@ removed %@ as admin"), actorName, subjectName)
        }
        if let subjectStartName {
            return String(format: L10n.string("%@ is no longer an admin"), subjectStartName)
        }
        if let actorName {
            return String(format: L10n.string("%@ removed an admin"), actorName)
        }
        return nil
    }

    private static func groupRenamedText(
        _ event: GroupSystemEventFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> String? {
        guard let name = PeerDisplayText.sanitize(event.name) else { return nil }
        let actorName = systemAccountName(
            event.actorAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )
        let oldName = PeerDisplayText.sanitize(event.oldName)
        let isolatedName = PeerDisplayText.templateFragment(name)

        if let actorName, let oldName {
            return String(
                format: L10n.string("%@ renamed the group from \"%@\" to \"%@\""),
                actorName,
                PeerDisplayText.templateFragment(oldName),
                isolatedName
            )
        }
        if let actorName {
            return String(format: L10n.string("%@ renamed the group to \"%@\""), actorName, isolatedName)
        }
        if let oldName {
            return String(
                format: L10n.string("The group was renamed from \"%@\" to \"%@\""),
                PeerDisplayText.templateFragment(oldName),
                isolatedName
            )
        }
        return String(format: L10n.string("The group was renamed to \"%@\""), isolatedName)
    }

    private static func groupAvatarChangedText(
        _ event: GroupSystemEventFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> String? {
        let actorName = systemAccountName(
            event.actorAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )
        if let actorName {
            return String(format: L10n.string("%@ changed the group avatar"), actorName)
        }
        return L10n.string("The group avatar changed")
    }

    private static func disappearingTimerChangedText(
        _ event: GroupSystemEventFfi,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile]
    ) -> String? {
        let actorName = systemAccountName(
            event.actorAccountIdHex,
            activeAccountIdHex: activeAccountIdHex,
            senderProfiles: senderProfiles,
            position: .subject
        )
        let newLabel = event.newRetentionSeconds.map(retentionDurationLabel)
        let oldLabel = event.oldRetentionSeconds.map(retentionDurationLabel)

        if let actorName, let oldLabel, let newLabel {
            return String(
                format: L10n.string("%@ changed disappearing messages from %@ to %@"),
                actorName,
                oldLabel,
                newLabel
            )
        }
        if let oldLabel, let newLabel {
            return String(format: L10n.string("Disappearing messages changed from %@ to %@"), oldLabel, newLabel)
        }
        if let actorName, let newLabel {
            return String(format: L10n.string("%@ set disappearing messages to %@"), actorName, newLabel)
        }
        if let newLabel {
            return String(format: L10n.string("Disappearing messages set to %@"), newLabel)
        }
        if let actorName {
            return String(format: L10n.string("%@ changed disappearing messages"), actorName)
        }
        return nil
    }

    private static func systemAccountName(
        _ accountIdHex: String?,
        activeAccountIdHex: String?,
        senderProfiles: [String: ChatPeerProfile],
        position: SystemAccountNamePosition
    ) -> String? {
        guard let accountIdHex = nonBlank(accountIdHex) else { return nil }
        if accountIdHex == activeAccountIdHex {
            switch position {
            case .subject:
                return L10n.string("You")
            case .object:
                return L10n.string("you")
            }
        }
        return PeerDisplayText.templateFragment(
            displayName(for: accountIdHex, profile: senderProfiles[accountIdHex])
        )
    }

    private enum SystemAccountNamePosition {
        case subject
        case object
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func retentionDurationLabel(_ seconds: UInt64) -> String {
        switch seconds {
        case 0:
            return L10n.string("off")
        case 1:
            return L10n.string("1 second")
        case 60:
            return L10n.string("1 minute")
        case 3_600:
            return L10n.string("1 hour")
        case 86_400:
            return L10n.string("1 day")
        case 604_800:
            return L10n.string("1 week")
        case 2_592_000:
            return L10n.string("1 month")
        default:
            if seconds.isMultiple(of: 86_400) {
                return String(format: L10n.string("%llu days"), CUnsignedLongLong(seconds / 86_400))
            }
            if seconds.isMultiple(of: 3_600) {
                return String(format: L10n.string("%llu hours"), CUnsignedLongLong(seconds / 3_600))
            }
            if seconds.isMultiple(of: 60) {
                return String(format: L10n.string("%llu minutes"), CUnsignedLongLong(seconds / 60))
            }
            return String(format: L10n.string("%llu seconds"), CUnsignedLongLong(seconds))
        }
    }

    /// The Markdown document to render in a chat bubble, or `nil` when the bubble
    /// should fall back to plain text — system rows, deleted messages, or content
    /// the core parsed into no blocks (e.g. media-only / empty plaintext).
    fileprivate static func renderableMarkdown(
        document: MarkdownDocumentFfi,
        displayedBody: String,
        deleted: Bool,
        invalidationStatus: String?,
        presentation: MessagePresentation
    ) -> MarkdownDocumentFfi? {
        guard presentation.isChatBubble, !deleted, invalidationStatus == nil, !document.blocks.isEmpty else {
            return nil
        }
        // Fast path: an unstyled single-paragraph message renders identically to the plain
        // `Text(message.body)` fallback, which is dramatically cheaper for SwiftUI to size
        // than the Markdown block/inline view tree (VStack → ForEach → MarkdownBlockView →
        // MarkdownInlineText → fixed-size Text). Most chat messages are exactly this, and
        // sizing/re-measuring that tree for ~100–200 rows during scroll-anchor resolution was
        // the send-time main-thread freeze (Instruments: continuous StackLayout.sizeThatFits /
        // LazyStack.measureEstimates). Returning nil keeps the common message as light as the
        // pre-Markdown bubble — and, since `MessageItem.contentMarkdown` is then nil, also
        // shrinks the struct SwiftUI copies per row. See whitenoise-mac#205.
        if isPlainTextParagraph(document, displayedBody: displayedBody) { return nil }
        return document
    }

    /// True when `document` is a single paragraph of unstyled text runs — no emphasis, code,
    /// links, mentions, soft/hard breaks, or multiple blocks — and the parsed text exactly
    /// matches the displayed body. Escaped Markdown (`\*`) parses to a different displayed
    /// string (`*`), so it must keep the Markdown renderer even though the AST contains only
    /// a text run.
    fileprivate static func isPlainTextParagraph(
        _ document: MarkdownDocumentFfi,
        displayedBody: String
    ) -> Bool {
        guard !document.truncated, document.blocks.count == 1,
            case .paragraph(let inlines) = document.blocks[0]
        else { return false }

        var parsedText = ""
        for inline in inlines {
            guard case .text(let content) = inline else { return false }
            parsedText += content
        }
        return parsedText == displayedBody
    }

    static func displayText(
        presentation: MessagePresentation,
        plaintext: String,
        tags: [MessageTagFfi],
        deleted: Bool,
        invalidationStatus: String? = nil,
        hasMediaAttachments: Bool = false
    ) -> String {
        if invalidationStatus != nil {
            return L10n.string("Message did not reach the group")
        }

        if deleted {
            return L10n.string("Message deleted")
        }

        let body = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only the agent / group-system rows consult the JSON payload, so each of those
        // cases decodes it locally — the common chat path (and agent-stream-start) never
        // pays for the decode. This runs for every message during mapping.
        switch presentation {
        case .chat:
            if !body.isEmpty {
                return body
            }
            return hasMediaAttachments ? "" : L10n.string("Unsupported message")
        case .agentStreamStart:
            if tagValue("route", in: tags) == "quic" {
                return L10n.string("Agent started a live response")
            }
            return L10n.string("Agent started a response")
        case .agentActivity:
            let payload = TimelinePayload.decode(from: body)
            return firstNonBlank([
                payload?.text,
                payload?.status.map { "\(L10n.string("Agent activity")): \(humanized($0))" },
                payload == nil ? body : nil,
            ]) ?? L10n.string("Agent activity")
        case .agentOperation:
            let payload = TimelinePayload.decode(from: body)
            if let text = firstNonBlank([payload?.text, payload?.preview]) {
                return text
            }
            if let name = payload?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                let status = payload?.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty
            {
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
            let payload = TimelinePayload.decode(from: body)
            if let text = PeerDisplayText.sanitize(payload?.text) {
                return text
            }
            if payload == nil, let text = PeerDisplayText.sanitize(body) {
                return text
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
        let mediaAttachments = MessageMediaParser.attachments(
            resolvedMedia: preview.media,
            mediaJson: preview.mediaJson,
            tags: [],
            messageIdHex: preview.messageIdHex
        )
        let body = displayText(
            presentation: presentation(for: preview.kind),
            plaintext: preview.plaintext,
            tags: [],
            deleted: preview.deleted,
            hasMediaAttachments: !mediaAttachments.isEmpty
        )
        return MessageReplyContext(
            targetMessageId: preview.messageIdHex,
            senderName: MessageItem.displayName(for: preview.sender, profile: senderProfiles[preview.sender]),
            body: body.isEmpty ? MessageMediaAttachment.previewText(for: mediaAttachments) : body
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
        PeerDisplayText.sanitize(profile?.displayName) ?? DisplayText.short(sender)
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
        case "disappearing_timer_changed":
            return L10n.string("Disappearing timer changed")
        default:
            return L10n.string("Group updated")
        }
    }
}

private nonisolated enum MarmotTimelineKind {
    static let chat: UInt64 = 9
    static let messageEdit: UInt64 = 1009
    static let agentStreamStart: UInt64 = 1200
    static let agentActivity: UInt64 = 1201
    static let agentOperation: UInt64 = 1202
    static let groupSystem: UInt64 = 1210
}

private nonisolated enum UntrustedJSON {
    static let maxNestingDepth = 32

    static func nestingExceedsLimit(_ json: String, maxDepth: Int = maxNestingDepth) -> Bool {
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for scalar in json.unicodeScalars {
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if scalar.value == 0x5C {  // \\
                    isEscaped = true
                } else if scalar.value == 0x22 {  // "
                    isInsideString = false
                }
                continue
            }

            switch scalar.value {
            case 0x22:  // "
                isInsideString = true
            case 0x7B, 0x5B:  // { or [
                depth += 1
                if depth > maxDepth {
                    return true
                }
            case 0x7D, 0x5D:  // } or ]
                depth = max(0, depth - 1)
            default:
                continue
            }
        }

        return false
    }
}

private nonisolated enum MessageMediaParser {
    // Legacy inbound fallback parsing intentionally mirrors the compose cap for now,
    // but keeps its own policy name so it can diverge from outgoing media limits.
    private static let maxFallbackAttachmentsPerMessage =
        OutgoingMediaDraftProcessor.maxAttachmentCount
    private static let logger = Logger(subsystem: "com.whitenoise.media", category: "MessageMediaParser")

    static func attachments(
        resolvedMedia: [MediaAttachmentReferenceFfi],
        mediaJson: String?,
        tags: [MessageTagFfi],
        messageIdHex: String
    ) -> [MessageMediaAttachment] {
        // Prefer the core's already-resolved and validated media references
        // (`TimelineMessageRecordFfi.media`): they use the same resolution as
        // `list_media`, with malformed `imeta` attachments already dropped. Fall
        // back to local parsing only for records that predate FFI media resolution
        // (e.g. an empty `media` list paired with a populated `mediaJson`).
        let resolvedReferences: [MediaAttachmentReferenceFfi]
        if !resolvedMedia.isEmpty {
            resolvedReferences = resolvedMedia
        } else {
            let tagReferences = references(fromIMetaTags: tags)
            let jsonReferences = references(fromMediaJson: mediaJson)
            let fallbackReferences =
                jsonReferences.references.isEmpty ? tagReferences : jsonReferences
            if fallbackReferences.wasTruncated {
                logFallbackOverflow()
            }
            resolvedReferences = fallbackReferences.references
        }

        return resolvedReferences.enumerated().map { index, reference in
            MessageMediaAttachment(
                id: mediaAttachmentId(messageIdHex: messageIdHex, reference: reference, index: index),
                reference: reference
            )
        }
    }

    private struct FallbackReferenceParseResult {
        var references: [MediaAttachmentReferenceFfi] = []
        var wasTruncated = false
    }

    private static func references(fromIMetaTags tags: [MessageTagFfi]) -> FallbackReferenceParseResult {
        var result = FallbackReferenceParseResult()
        for tag in tags where tag.values.first == "imeta" {
            guard result.references.count < maxFallbackAttachmentsPerMessage else {
                result.wasTruncated = true
                break
            }
            if let reference = reference(fromIMetaTag: tag.values, sourceEpoch: 0) {
                result.references.append(reference)
            }
        }
        return result
    }

    private static func logFallbackOverflow() {
        logger.notice(
            "Dropped fallback media attachment references after reaching cap \(maxFallbackAttachmentsPerMessage)"
        )
    }

    private static func references(fromMediaJson mediaJson: String?) -> FallbackReferenceParseResult {
        guard let mediaJson,
            !UntrustedJSON.nestingExceedsLimit(mediaJson),
            let data = mediaJson.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else { return FallbackReferenceParseResult() }

        var result = FallbackReferenceParseResult()
        collectReferences(fromJSONObject: root, remainingDepth: UntrustedJSON.maxNestingDepth, into: &result)
        return result
    }

    private static func collectReferences(
        fromJSONObject value: Any,
        remainingDepth: Int,
        into result: inout FallbackReferenceParseResult
    ) {
        guard remainingDepth >= 0, !result.wasTruncated else { return }

        if let dictionary = value as? [String: Any] {
            // Branches are mutually exclusive in precedence order so a single object
            // carrying multiple shapes (e.g. both `imeta` and the flat direct-reference
            // keys) cannot emit duplicate references for the same logical attachment.
            if let imeta = dictionary["imeta"] {
                // any object graph deeper than UntrustedJSON.maxNestingDepth before parsing.
                let beforeCount = result.references.count
                collectReferences(
                    fromIMetaValue: imeta,
                    sourceEpoch: unsignedInteger(dictionary["source_epoch"] ?? dictionary["sourceEpoch"]),
                    into: &result
                )
                if result.wasTruncated || result.references.count > beforeCount {
                    return
                }
            }
            if let media = dictionary["media"] {
                let beforeCount = result.references.count
                collectReferences(
                    fromJSONObject: media,
                    remainingDepth: remainingDepth - 1,
                    into: &result
                )
                if result.wasTruncated || result.references.count > beforeCount {
                    return
                }
            }
            if let direct = reference(fromJSONObject: dictionary) {
                append(direct, into: &result)
            }
            return
        }

        if let array = value as? [Any] {
            let stringArray = array.compactMap { $0 as? String }
            if stringArray.count == array.count, stringArray.first == "imeta" {
                if let reference = reference(fromIMetaTag: stringArray, sourceEpoch: 0) {
                    append(reference, into: &result)
                }
                return
            }

            for item in array {
                guard result.references.count < maxFallbackAttachmentsPerMessage else {
                    result.wasTruncated = true
                    return
                }
                collectReferences(fromJSONObject: item, remainingDepth: remainingDepth - 1, into: &result)
                if result.wasTruncated { return }
            }
        }
    }

    private static func collectReferences(
        fromIMetaValue value: Any,
        sourceEpoch: UInt64?,
        into result: inout FallbackReferenceParseResult
    ) {
        guard let array = value as? [Any] else { return }
        collectReferences(fromIMetaArray: array, sourceEpoch: sourceEpoch, into: &result)
    }

    private static func collectReferences(
        fromIMetaArray array: [Any],
        sourceEpoch: UInt64?,
        into result: inout FallbackReferenceParseResult
    ) {
        let stringArray = array.compactMap { $0 as? String }
        if stringArray.count == array.count, stringArray.first == "imeta" {
            if let reference = reference(fromIMetaTag: stringArray, sourceEpoch: sourceEpoch ?? 0) {
                append(reference, into: &result)
            }
            return
        }

        for item in array {
            guard let tagArray = item as? [Any] else { continue }
            let tag = tagArray.compactMap { $0 as? String }
            guard tag.count == tagArray.count, tag.first == "imeta" else { continue }
            guard result.references.count < maxFallbackAttachmentsPerMessage else {
                result.wasTruncated = true
                return
            }
            if let reference = reference(fromIMetaTag: tag, sourceEpoch: sourceEpoch ?? 0) {
                result.references.append(reference)
            }
        }
    }

    private static func append(
        _ reference: MediaAttachmentReferenceFfi,
        into result: inout FallbackReferenceParseResult
    ) {
        guard result.references.count < maxFallbackAttachmentsPerMessage else {
            result.wasTruncated = true
            return
        }
        result.references.append(reference)
    }

    private static func reference(fromJSONObject dictionary: [String: Any]) -> MediaAttachmentReferenceFfi? {
        guard let ciphertextSha256 = string(dictionary, keys: ["ciphertext_sha256", "ciphertextSha256"]),
            let plaintextSha256 = string(dictionary, keys: ["plaintext_sha256", "plaintextSha256"]),
            let nonceHex = string(dictionary, keys: ["nonce_hex", "nonceHex", "nonce"]),
            let fileName = string(dictionary, keys: ["file_name", "fileName", "filename"]),
            let mediaType = string(dictionary, keys: ["media_type", "mediaType", "m"]),
            let version = string(dictionary, keys: ["version", "v"])
        else { return nil }

        return MediaAttachmentReferenceFfi(
            locators: locators(fromJSONObject: dictionary["locators"]),
            ciphertextSha256: ciphertextSha256,
            plaintextSha256: plaintextSha256,
            nonceHex: nonceHex,
            fileName: fileName,
            mediaType: mediaType,
            version: version,
            sourceEpoch: unsignedInteger(dictionary["source_epoch"] ?? dictionary["sourceEpoch"]) ?? 0,
            dim: string(dictionary, keys: ["dim"]),
            thumbhash: string(dictionary, keys: ["thumbhash"])
        )
    }

    private static func reference(fromIMetaTag tag: [String], sourceEpoch: UInt64) -> MediaAttachmentReferenceFfi? {
        var locators: [MediaLocatorFfi] = []
        var fields: [String: String] = [:]

        for field in tag.dropFirst() {
            if field.hasPrefix("blurhash ") {
                // Recognized NIP-92 placeholder; unsupported locally, but keep the attachment.
                continue
            }
            if let locator = field.dropPrefix("locator "),
                let split = locator.firstIndex(of: " ")
            {
                let kind = String(locator[..<split])
                let value = String(locator[locator.index(after: split)...])
                guard !kind.isEmpty, !value.isEmpty else { continue }
                locators.append(MediaLocatorFfi(kind: kind, value: value))
                continue
            }
            guard let split = field.firstIndex(of: " ") else { continue }
            let key = String(field[..<split])
            let value = String(field[field.index(after: split)...])
            fields[key] = value
        }

        guard let ciphertextSha256 = required("ciphertext_sha256", in: fields),
            let plaintextSha256 = required("plaintext_sha256", in: fields),
            let nonce = required("nonce", in: fields),
            let fileName = required("filename", in: fields),
            let mediaType = required("m", in: fields),
            let version = required("v", in: fields)
        else { return nil }

        return MediaAttachmentReferenceFfi(
            locators: locators,
            ciphertextSha256: ciphertextSha256,
            plaintextSha256: plaintextSha256,
            nonceHex: nonce,
            fileName: fileName,
            mediaType: mediaType,
            version: version,
            sourceEpoch: sourceEpoch,
            dim: fields["dim"],
            thumbhash: fields["thumbhash"]
        )
    }

    private static func locators(fromJSONObject value: Any?) -> [MediaLocatorFfi] {
        guard let locators = value as? [Any] else { return [] }
        return locators.compactMap { locator in
            guard let locator = locator as? [String: Any],
                let kind = string(locator, keys: ["kind"]),
                let value = string(locator, keys: ["value"])
            else { return nil }
            return MediaLocatorFfi(kind: kind, value: value)
        }
    }

    private static func string(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            if let string = value as? String {
                if let value = string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
                    return value
                }
            } else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    // JSON booleans bridge as NSNumber. Skip them rather than returning
                    // "1"/"0", and allow later alias keys to supply the real string.
                    continue
                }
                return number.stringValue
            }
        }
        return nil
    }

    private static func required(_ key: String, in fields: [String: String]) -> String? {
        fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            // `uint64Value` silently wraps negatives (`-1` -> `UInt64.max`) and truncates
            // fractions (`3.9` -> `3`). A peer-controlled `source_epoch` feeds MLS epoch
            // selection, so reject anything that is not an exact, in-range unsigned integer
            // rather than letting garbage flow into the crypto layer. Round-tripping through
            // the string value keeps this path semantically aligned with the `String` branch.
            return UInt64(number.stringValue)
        }
        if let string = value as? String {
            return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func mediaAttachmentId(
        messageIdHex: String,
        reference: MediaAttachmentReferenceFfi,
        index: Int
    ) -> String {
        let stableHash =
            reference.plaintextSha256.nilIfBlank
            ?? reference.ciphertextSha256.nilIfBlank
            ?? reference.fileName
        return "\(messageIdHex)#\(index)#\(stableHash)"
    }
}

private nonisolated struct TimelinePayload: Decodable {
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
        guard !UntrustedJSON.nestingExceedsLimit(text),
            let data = text.data(using: .utf8)
        else { return nil }
        return try? decoder.decode(TimelinePayload.self, from: data)
    }
}

private extension String {
    nonisolated func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

private nonisolated extension MessageReaction {
    static func summarize(_ summary: TimelineReactionSummaryFfi, activeAccountIdHex: String?) -> [MessageReaction] {
        let ownReactionIdsByEmoji =
            activeAccountIdHex.map { accountIdHex in
                Dictionary(
                    summary.userReactions.lazy
                        .filter { $0.sender == accountIdHex }
                        .map { ($0.emoji, $0.reactionMessageIdHex) },
                    uniquingKeysWith: { first, _ in first }
                )
            } ?? [:]

        return summary.byEmoji.map { reaction in
            MessageReaction(
                emoji: reaction.emoji,
                count: reaction.senders.count,
                isOwn: activeAccountIdHex.map { reaction.senders.contains($0) } ?? false,
                ownReactionMessageId: ownReactionIdsByEmoji[reaction.emoji]
            )
        }
    }
}
