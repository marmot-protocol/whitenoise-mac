//
//  GroupSharedMediaModel.swift
//  whitenoise-mac
//
//  Stable, pre-sorted projection for the group-details shared-media browser.
//

import MarmotKit

nonisolated struct GroupSharedMediaItem: Identifiable, Hashable, Sendable {
    let id: String
    let reference: MediaAttachmentReferenceFfi
    let groupIdHex: String
    let timestamp: UInt64

    var attachment: MessageMediaAttachment { MessageMediaAttachment(id: id, reference: reference) }
    var isVisual: Bool { attachment.kind == .image || attachment.kind == .video }

    init(record: MediaRecordFfi) {
        let recordIdentity: String
        if record.messageIdHex.isEmpty {
            // Some imported records have no message id. Frame every stable content field so
            // separators inside peer/file data cannot create accidental identity collisions.
            recordIdentity = Self.framed([
                record.reference.plaintextSha256.lowercased(),
                record.reference.ciphertextSha256.lowercased(),
                record.sender,
                String(record.recordedAt),
                String(record.receivedAt),
            ])
        } else {
            recordIdentity = Self.framed([record.messageIdHex])
        }
        id =
            "shared-media:"
            + Self.framed([
                record.groupIdHex,
                recordIdentity,
                String(record.attachmentIndex),
            ])
        reference = record.reference
        groupIdHex = record.groupIdHex
        timestamp = max(record.recordedAt, record.receivedAt)
    }

    private static func framed(_ components: [String]) -> String {
        components.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

nonisolated struct GroupSharedMediaProjection: Sendable {
    let media: [GroupSharedMediaItem]
    let files: [GroupSharedMediaItem]

    static let empty = GroupSharedMediaProjection(records: [])

    init(records: [MediaRecordFfi]) {
        // Exact duplicate runtime rows represent the same attachment. Coalescing them also keeps
        // SwiftUI's `ForEach` identity unique without falling back to list position.
        var itemsByID: [String: GroupSharedMediaItem] = [:]
        for record in records {
            let item = GroupSharedMediaItem(record: record)
            itemsByID[item.id] = item
        }
        let items = itemsByID.values.sorted { lhs, rhs in
            lhs.timestamp != rhs.timestamp ? lhs.timestamp > rhs.timestamp : lhs.id > rhs.id
        }
        media = items.filter(\.isVisual)
        files = items.filter { !$0.isVisual }
    }

    var isEmpty: Bool { media.isEmpty && files.isEmpty }
}
