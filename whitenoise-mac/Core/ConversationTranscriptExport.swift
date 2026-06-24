import Foundation
import MarmotKit

/// Builds a chronological JSON dump of inner Marmot/Nostr app events for debugging.
/// `nonisolated` so the (blocking) FFI pagination + JSON encoding can run off the main
/// thread under the project's default `@MainActor` isolation.
nonisolated enum ConversationTranscriptExport {
    static let pageLimit: UInt32 = 200

    enum ExportError: LocalizedError {
        /// The FFI reported more history exists (`hasMoreBefore == true`) but returned an
        /// empty page, so the `before` cursor cannot advance. Surfacing this prevents
        /// silently truncating the transcript (issue #139).
        case emptyPageWithMoreHistory

        var errorDescription: String? {
            switch self {
            case .emptyPageWithMoreHistory:
                return
                    "Transcript export stopped early: the timeline reported more history but returned an empty page, "
                    + "so older messages could not be loaded."
            }
        }
    }

    struct Document: Encodable {
        var v: Int = 1
        var exportedAt: String
        var groupIdHex: String
        var groupName: String
        var eventCount: Int
        var events: [Event]

        enum CodingKeys: String, CodingKey {
            case v
            case exportedAt = "exported_at"
            case groupIdHex = "group_id_hex"
            case groupName = "group_name"
            case eventCount = "event_count"
            case events
        }
    }

    struct Event: Encodable {
        var index: Int
        var messageIdHex: String
        var sourceMessageIdHex: String?
        var kind: UInt64
        var content: String
        var tags: [[String]]
        var direction: String
        var sender: String
        var timelineAt: UInt64
        var receivedAt: UInt64
        var replyToMessageIdHex: String?
        var mediaJson: String?
        var agentTextStreamJson: String?
        var deleted: Bool
        var deletedByMessageIdHex: String?
        var invalidationStatus: String?

        enum CodingKeys: String, CodingKey {
            case index
            case messageIdHex = "message_id_hex"
            case sourceMessageIdHex = "source_message_id_hex"
            case kind
            case content
            case tags
            case direction
            case sender
            case timelineAt = "timeline_at"
            case receivedAt = "received_at"
            case replyToMessageIdHex = "reply_to_message_id_hex"
            case mediaJson = "media_json"
            case agentTextStreamJson = "agent_text_stream_json"
            case deleted
            case deletedByMessageIdHex = "deleted_by_message_id_hex"
            case invalidationStatus = "invalidation_status"
        }
    }

    static func fetchAllMessages(
        client: any MarmotRuntime,
        accountRef: String,
        groupIdHex: String
    ) throws -> [TimelineMessageRecordFfi] {
        var collectedById: [String: TimelineMessageRecordFfi] = [:]
        var before: UInt64?
        var beforeMessageId: String?

        while true {
            let page = try client.timelineMessages(
                accountRef: accountRef,
                query: TimelineMessageQueryFfi(
                    groupIdHex: groupIdHex,
                    search: nil,
                    before: before,
                    beforeMessageId: beforeMessageId,
                    after: nil,
                    afterMessageId: nil,
                    limit: pageLimit
                )
            )
            for message in page.messages {
                collectedById[message.messageIdHex] = message
            }

            guard page.hasMoreBefore else { break }
            let orderedPage = sortChronologically(page.messages)
            guard let oldest = orderedPage.first else {
                // `hasMoreBefore` is true but the page is empty, so the `before` cursor
                // cannot advance. Fail loudly instead of silently truncating history (#139).
                throw ExportError.emptyPageWithMoreHistory
            }
            let nextBefore = oldest.timelineAt
            let nextBeforeMessageId = oldest.messageIdHex
            guard nextBefore != before || nextBeforeMessageId != beforeMessageId else { break }
            before = nextBefore
            beforeMessageId = nextBeforeMessageId
        }

        return sortChronologically(Array(collectedById.values))
    }

    static func makeDocument(
        groupIdHex: String,
        groupName: String,
        messages: [TimelineMessageRecordFfi],
        exportedAt: Date = Date()
    ) -> Document {
        let ordered = sortChronologically(messages)
        let events = ordered.enumerated().map { index, record in
            Event(
                index: index,
                messageIdHex: record.messageIdHex,
                sourceMessageIdHex: record.sourceMessageIdHex,
                kind: record.kind,
                content: record.plaintext,
                tags: record.tags.map(\.values),
                direction: record.direction,
                sender: record.sender,
                timelineAt: record.timelineAt,
                receivedAt: record.receivedAt,
                replyToMessageIdHex: record.replyToMessageIdHex,
                mediaJson: record.mediaJson,
                agentTextStreamJson: record.agentTextStreamJson,
                deleted: record.deleted,
                deletedByMessageIdHex: record.deletedByMessageIdHex,
                invalidationStatus: record.invalidationStatus
            )
        }
        return Document(
            exportedAt: iso8601Timestamp(exportedAt),
            groupIdHex: groupIdHex,
            groupName: groupName,
            eventCount: events.count,
            events: events
        )
    }

    static func encodeJSON(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    static func encodeJSONString(_ document: Document) throws -> String {
        let data = try encodeJSON(document)
        return String(decoding: data, as: UTF8.self)
    }

    private static func sortChronologically(_ messages: [TimelineMessageRecordFfi]) -> [TimelineMessageRecordFfi] {
        messages.sorted { lhs, rhs in
            if lhs.timelineAt == rhs.timelineAt {
                return lhs.messageIdHex < rhs.messageIdHex
            }
            return lhs.timelineAt < rhs.timelineAt
        }
    }

    private static func iso8601Timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
