import Foundation
import MarmotKit

extension AccountItem {
    nonisolated init(summary: AccountSummaryFfi) {
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
            unreadCount: Int(row.unreadCount),
            isDirect: directPeer != nil,
            pendingConfirmation: row.pendingConfirmation
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
            invalidationStatus: nil,
            hasMediaAttachments: false
        )
        guard !text.isEmpty else {
            return presentation.isChatBubble ? L10n.string("Attachment") : L10n.string("Unsupported message")
        }
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
        let mediaAttachments = MessageMediaParser.attachments(
            mediaJson: record.mediaJson,
            tags: record.tags,
            messageIdHex: record.messageIdHex
        )
        self.init(
            id: record.messageIdHex,
            groupIdHex: record.groupIdHex,
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
                invalidationStatus: record.invalidationStatus,
                hasMediaAttachments: !mediaAttachments.isEmpty
            ),
            sentAt: Date(timeIntervalSince1970: TimeInterval(record.timelineAt)),
            timelineAt: record.timelineAt,
            timelineKind: record.kind,
            isDeleted: record.deleted,
            invalidationStatus: record.invalidationStatus,
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
        return page.messages.map { record in
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
        let messagePresentation = presentation(for: kind)

        // Plain chat messages never consult the JSON payload, so skip decoding it for
        // the common case (this runs for every message during mapping).
        if case .chat = messagePresentation {
            if !body.isEmpty {
                return body
            }
            return hasMediaAttachments ? "" : L10n.string("Unsupported message")
        }

        let payload = TimelinePayload.decode(from: body)

        switch messagePresentation {
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
            return firstNonBlank([
                payload?.text,
                payload?.status.map { "\(L10n.string("Agent activity")): \(humanized($0))" },
                payload == nil ? body : nil,
            ]) ?? L10n.string("Agent activity")
        case .agentOperation:
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
        let mediaAttachments = MessageMediaParser.attachments(
            mediaJson: preview.mediaJson,
            tags: [],
            messageIdHex: preview.messageIdHex
        )
        let body = displayText(
            kind: preview.kind,
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

private nonisolated enum MessageMediaParser {
    private static let maxMediaJSONTraversalDepth = 32

    static func attachments(
        mediaJson: String?,
        tags: [MessageTagFfi],
        messageIdHex: String
    ) -> [MessageMediaAttachment] {
        let tagReferences =
            tags
            .filter { $0.values.first == "imeta" }
            .compactMap { reference(fromIMetaTag: $0.values, sourceEpoch: 0) }
        let jsonReferences = references(fromMediaJson: mediaJson)
        let references = jsonReferences.isEmpty ? tagReferences : jsonReferences

        return references.enumerated().map { index, reference in
            MessageMediaAttachment(
                id: mediaAttachmentId(messageIdHex: messageIdHex, reference: reference, index: index),
                reference: reference
            )
        }
    }

    private static func references(fromMediaJson mediaJson: String?) -> [MediaAttachmentReferenceFfi] {
        guard let mediaJson,
            !mediaJSONNestingExceedsLimit(mediaJson, maxDepth: maxMediaJSONTraversalDepth),
            let data = mediaJson.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        return references(fromJSONObject: root, remainingDepth: maxMediaJSONTraversalDepth)
    }

    private static func references(
        fromJSONObject value: Any,
        remainingDepth: Int
    ) -> [MediaAttachmentReferenceFfi] {
        guard remainingDepth >= 0 else { return [] }

        if let dictionary = value as? [String: Any] {
            // Branches are mutually exclusive in precedence order so a single object
            // carrying multiple shapes (e.g. both `imeta` and the flat direct-reference
            // keys) cannot emit duplicate references for the same logical attachment.
            if let imeta = dictionary["imeta"] {
                // Safe without its own depth counter because the raw JSON pre-scan rejects
                // any object graph deeper than maxMediaJSONTraversalDepth before parsing.
                let imetaReferences = references(
                    fromIMetaValue: imeta,
                    sourceEpoch: unsignedInteger(dictionary["source_epoch"] ?? dictionary["sourceEpoch"])
                )
                if !imetaReferences.isEmpty {
                    return imetaReferences
                }
            }
            if let media = dictionary["media"] {
                let mediaReferences = references(fromJSONObject: media, remainingDepth: remainingDepth - 1)
                if !mediaReferences.isEmpty {
                    return mediaReferences
                }
            }
            if let direct = reference(fromJSONObject: dictionary) {
                return [direct]
            }

            return []
        }

        if let array = value as? [Any] {
            if let tagReferences = references(fromIMetaArray: array, sourceEpoch: nil), !tagReferences.isEmpty {
                return tagReferences
            }
            return array.flatMap { references(fromJSONObject: $0, remainingDepth: remainingDepth - 1) }
        }

        return []
    }

    private static func mediaJSONNestingExceedsLimit(_ json: String, maxDepth: Int) -> Bool {
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

    private static func references(fromIMetaValue value: Any, sourceEpoch: UInt64?) -> [MediaAttachmentReferenceFfi] {
        guard let array = value as? [Any],
            let references = references(fromIMetaArray: array, sourceEpoch: sourceEpoch)
        else { return [] }
        return references
    }

    private static func references(fromIMetaArray array: [Any], sourceEpoch: UInt64?) -> [MediaAttachmentReferenceFfi]?
    {
        let stringArray = array.compactMap { $0 as? String }
        if stringArray.count == array.count, stringArray.first == "imeta" {
            return reference(fromIMetaTag: stringArray, sourceEpoch: sourceEpoch ?? 0).map { [$0] } ?? []
        }

        var references: [MediaAttachmentReferenceFfi] = []
        var sawTag = false
        for item in array {
            guard let tagArray = item as? [Any] else { continue }
            let tag = tagArray.compactMap { $0 as? String }
            guard tag.count == tagArray.count, tag.first == "imeta" else { continue }
            sawTag = true
            if let reference = reference(fromIMetaTag: tag, sourceEpoch: sourceEpoch ?? 0) {
                references.append(reference)
            }
        }
        return sawTag ? references : nil
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
                return nil
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
        guard let locators = value as? [[String: Any]] else { return [] }
        return locators.compactMap { locator in
            guard let kind = string(locator, keys: ["kind"]),
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

private extension String {
    nonisolated func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
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
