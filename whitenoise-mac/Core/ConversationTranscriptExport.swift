import Foundation
import MarmotKit

/// Streams a chronological JSON dump of inner Marmot/Nostr app events to disk.
/// `nonisolated` keeps blocking FFI pagination and file encoding off the main actor.
nonisolated enum ConversationTranscriptExport {
    static let pageLimit: UInt32 = 200

    enum ExportError: LocalizedError {
        /// The FFI reported more history exists (`hasMoreBefore == true`) but the `before`
        /// cursor cannot advance — either the page was empty, or its oldest message matched
        /// the current cursor. Surfacing this prevents silently truncating the transcript.
        case emptyPageWithMoreHistory
        case unableToCreateTemporaryFile(URL)
        case invalidSpoolData
        case destinationIsDirectory(URL)

        var errorDescription: String? {
            switch self {
            case .emptyPageWithMoreHistory:
                return
                    "Transcript export stopped early: the timeline reported more history but the pagination "
                    + "cursor could not advance, so older messages could not be loaded."
            case .unableToCreateTemporaryFile(let url):
                return "Transcript export could not create a temporary file at \(url.path)."
            case .invalidSpoolData:
                return "Transcript export could not read its temporary data."
            case .destinationIsDirectory(let url):
                return "Transcript export cannot replace the folder at \(url.path) with a JSON file."
            }
        }
    }

    struct ExportResult {
        var eventCount: Int
        var destinationURL: URL
    }

    private struct Metadata: Encodable {
        var v: Int = 1
        var exportedAt: String
        var groupIdHex: String
        var groupName: String
        var eventCount: Int

        enum CodingKeys: String, CodingKey {
            case v
            case exportedAt = "exported_at"
            case groupIdHex = "group_id_hex"
            case groupName = "group_name"
            case eventCount = "event_count"
        }
    }

    struct Event: Codable {
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

    private struct SpoolSummary {
        var chunkCount: Int
        var eventCount: Int
    }

    static func suggestedFilename(exportedAt: Date = Date()) -> String {
        let timestamp = iso8601Timestamp(exportedAt).replacingOccurrences(of: ":", with: "-")
        return "White Noise Transcript \(timestamp).json"
    }

    /// Paginates newest-to-oldest into bounded disk chunks, then replays the chunks oldest-first.
    /// A disk-backed message-id index preserves whole-export deduplication without retaining every
    /// record or id in memory. The selected destination is published only after the complete JSON
    /// document has been written and synchronized to a sibling temporary file.
    static func export(
        client: any MarmotRuntime,
        accountRef: String,
        groupIdHex: String,
        groupName: String,
        to destinationURL: URL,
        exportedAt: Date = Date(),
        fileManager: FileManager = .default,
        scratchDirectory: URL? = nil,
        checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> ExportResult {
        try checkCancellation()

        let scratchRoot = (scratchDirectory ?? fileManager.temporaryDirectory)
            .appendingPathComponent("WhiteNoiseTranscriptExport-\(UUID().uuidString)", isDirectory: true)
        let chunksDirectory = scratchRoot.appendingPathComponent("chunks", isDirectory: true)
        let markersDirectory = scratchRoot.appendingPathComponent("message-ids", isDirectory: true)
        // Register cleanup before the first directory operation: creating `chunks` can create the
        // export root even if creating `message-ids` fails immediately afterward.
        defer { try? fileManager.removeItem(at: scratchRoot) }
        try fileManager.createDirectory(
            at: chunksDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: markersDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let summary = try spoolTranscript(
            client: client,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            chunksDirectory: chunksDirectory,
            markersDirectory: markersDirectory,
            fileManager: fileManager,
            checkCancellation: checkCancellation
        )
        try checkCancellation()

        let temporaryURL = temporaryDestinationURL(for: destinationURL)
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try writeDocument(
            groupIdHex: groupIdHex,
            groupName: groupName,
            exportedAt: exportedAt,
            summary: summary,
            chunksDirectory: chunksDirectory,
            markersDirectory: markersDirectory,
            temporaryURL: temporaryURL,
            fileManager: fileManager,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        try publish(temporaryURL: temporaryURL, to: destinationURL, fileManager: fileManager)
        shouldRemoveTemporaryFile = false

        return ExportResult(eventCount: summary.eventCount, destinationURL: destinationURL)
    }

    private static func spoolTranscript(
        client: any MarmotRuntime,
        accountRef: String,
        groupIdHex: String,
        chunksDirectory: URL,
        markersDirectory: URL,
        fileManager: FileManager,
        checkCancellation: @Sendable () throws -> Void
    ) throws -> SpoolSummary {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var before: UInt64?
        var beforeMessageId: String?
        var chunkCount = 0
        var uniqueEventCount = 0
        var nextOccurrence: UInt64 = 0
        var preparedMarkerShards = Set<String>()

        while true {
            try checkCancellation()
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
            try checkCancellation()

            if !page.messages.isEmpty {
                let chunkURL = chunksDirectory.appendingPathComponent(chunkFilename(chunkCount))
                guard
                    fileManager.createFile(
                        atPath: chunkURL.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                else {
                    throw ExportError.unableToCreateTemporaryFile(chunkURL)
                }
                let handle = try FileHandle(forWritingTo: chunkURL)
                defer { try? handle.close() }

                do {
                    for record in sortChronologically(page.messages) {
                        try checkCancellation()
                        nextOccurrence += 1
                        let markerURL = try markerURL(
                            for: record.messageIdHex,
                            in: markersDirectory,
                            preparedShards: &preparedMarkerShards,
                            fileManager: fileManager
                        )
                        if !fileManager.fileExists(atPath: markerURL.path) {
                            guard
                                fileManager.createFile(
                                    atPath: markerURL.path,
                                    contents: data(for: nextOccurrence),
                                    attributes: [.posixPermissions: 0o600]
                                )
                            else {
                                throw ExportError.unableToCreateTemporaryFile(markerURL)
                            }
                            uniqueEventCount += 1
                        }

                        let eventData = try encoder.encode(event(from: record, index: 0))
                        try handle.write(contentsOf: data(for: nextOccurrence))
                        try handle.write(contentsOf: data(for: UInt64(eventData.count)))
                        try handle.write(contentsOf: eventData)
                    }
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                chunkCount += 1
            }

            guard page.hasMoreBefore else { break }
            guard
                let oldest = page.messages.min(by: { lhs, rhs in
                    lhs.timelineAt != rhs.timelineAt
                        ? lhs.timelineAt < rhs.timelineAt
                        : lhs.messageIdHex < rhs.messageIdHex
                })
            else {
                throw ExportError.emptyPageWithMoreHistory
            }
            let nextBefore = oldest.timelineAt
            let nextBeforeMessageId = oldest.messageIdHex
            guard nextBefore != before || nextBeforeMessageId != beforeMessageId else {
                throw ExportError.emptyPageWithMoreHistory
            }
            before = nextBefore
            beforeMessageId = nextBeforeMessageId
        }

        return SpoolSummary(chunkCount: chunkCount, eventCount: uniqueEventCount)
    }

    private static func writeDocument(
        groupIdHex: String,
        groupName: String,
        exportedAt: Date,
        summary: SpoolSummary,
        chunksDirectory: URL,
        markersDirectory: URL,
        temporaryURL: URL,
        fileManager: FileManager,
        checkCancellation: @Sendable () throws -> Void
    ) throws {
        guard
            fileManager.createFile(
                atPath: temporaryURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw ExportError.unableToCreateTemporaryFile(temporaryURL)
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        do {
            var metadata = try encoder.encode(
                Metadata(
                    exportedAt: iso8601Timestamp(exportedAt),
                    groupIdHex: groupIdHex,
                    groupName: groupName,
                    eventCount: summary.eventCount
                ))
            guard metadata.last == Character("}").asciiValue else {
                throw ExportError.invalidSpoolData
            }
            metadata.removeLast()
            try handle.write(contentsOf: metadata)
            try handle.write(contentsOf: Data(",\"events\":[".utf8))

            var emittedCount = 0
            if summary.chunkCount > 0 {
                for chunkIndex in (0..<summary.chunkCount).reversed() {
                    try checkCancellation()
                    let chunkURL = chunksDirectory.appendingPathComponent(chunkFilename(chunkIndex))
                    let chunkHandle = try FileHandle(forReadingFrom: chunkURL)
                    defer { try? chunkHandle.close() }

                    do {
                        while let occurrence = try readUInt64OrEnd(from: chunkHandle) {
                            try checkCancellation()
                            let byteCount = try readUInt64(from: chunkHandle)
                            guard byteCount <= UInt64(Int.max) else {
                                throw ExportError.invalidSpoolData
                            }
                            let eventData = try readExactly(Int(byteCount), from: chunkHandle)
                            var event = try decoder.decode(Event.self, from: eventData)
                            let marker = markerURL(for: event.messageIdHex, in: markersDirectory)
                            guard try readMarker(at: marker) == occurrence else { continue }

                            event.index = emittedCount
                            if emittedCount > 0 {
                                try handle.write(contentsOf: Data(",".utf8))
                            }
                            try handle.write(contentsOf: encoder.encode(event))
                            emittedCount += 1
                        }
                        try chunkHandle.close()
                    } catch {
                        try? chunkHandle.close()
                        throw error
                    }
                }
            }

            guard emittedCount == summary.eventCount else {
                throw ExportError.invalidSpoolData
            }
            try handle.write(contentsOf: Data("]}".utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func publish(temporaryURL: URL, to destinationURL: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw ExportError.destinationIsDirectory(destinationURL)
            }
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private static func temporaryDestinationURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial",
            isDirectory: false
        )
    }

    private static func markerURL(
        for messageIdHex: String,
        in markersDirectory: URL,
        preparedShards: inout Set<String>,
        fileManager: FileManager
    ) throws -> URL {
        let (shard, filename) = markerComponents(for: messageIdHex)
        let shardDirectory = markersDirectory.appendingPathComponent(shard, isDirectory: true)
        if preparedShards.insert(shard).inserted {
            try fileManager.createDirectory(
                at: shardDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return shardDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private static func markerURL(for messageIdHex: String, in markersDirectory: URL) -> URL {
        let (shard, filename) = markerComponents(for: messageIdHex)
        return markersDirectory
            .appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private static func markerComponents(for messageIdHex: String) -> (shard: String, filename: String) {
        let encoded = Data(messageIdHex.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let safeKey = encoded.isEmpty ? "_" : encoded
        let shard = String(safeKey.prefix(2))
        return (shard, "id-\(safeKey)")
    }

    private static func readMarker(at url: URL) throws -> UInt64 {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == MemoryLayout<UInt64>.size else {
            throw ExportError.invalidSpoolData
        }
        return uint64(from: data)
    }

    private static func chunkFilename(_ index: Int) -> String {
        String(format: "chunk-%020d.bin", index)
    }

    private static func data(for value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private static func uint64(from data: Data) -> UInt64 {
        var value: UInt64 = 0
        withUnsafeMutableBytes(of: &value) { destination in
            data.copyBytes(to: destination)
        }
        return UInt64(bigEndian: value)
    }

    private static func readUInt64OrEnd(from handle: FileHandle) throws -> UInt64? {
        guard let data = try readExactlyOrEnd(MemoryLayout<UInt64>.size, from: handle) else {
            return nil
        }
        return uint64(from: data)
    }

    private static func readUInt64(from handle: FileHandle) throws -> UInt64 {
        guard let data = try readExactlyOrEnd(MemoryLayout<UInt64>.size, from: handle) else {
            throw ExportError.invalidSpoolData
        }
        return uint64(from: data)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard let data = try readExactlyOrEnd(count, from: handle) else {
            throw ExportError.invalidSpoolData
        }
        return data
    }

    private static func readExactlyOrEnd(_ count: Int, from handle: FileHandle) throws -> Data? {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard
                let chunk = try handle.read(upToCount: count - result.count),
                !chunk.isEmpty
            else {
                if result.isEmpty { return nil }
                throw ExportError.invalidSpoolData
            }
            result.append(chunk)
        }
        return result
    }

    private static func event(from record: TimelineMessageRecordFfi, index: Int) -> Event {
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
