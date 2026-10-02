import AppKit
import Foundation
import MarmotKit
import Observation

/// The decoded images behind one conversation's NIP-30 custom emoji, for message text and for
/// reactions alike.
///
/// A message's emoji image is one of its own attachments, so its reference is in hand. A
/// reaction's is the attachment of the kind-7 that `ConversationReactionFfi.reactionMessageIdHex`
/// names, which `listMedia` resolves. Either way the bytes come through the same disk cache and
/// `downloadMedia` as an ordinary attachment, and keep their media epoch secret, so they stay
/// decryptable after the group advances.
@MainActor
@Observable
final class CustomEmojiImageStore {
    /// Decoded images, keyed by `key(for:)`.
    private(set) var images: [String: NSImage] = [:]
    /// Keys whose image could not be loaded. Their shortcode stays the literal `:shortcode:`.
    private(set) var failed: Set<String> = []
    /// Reaction kind-7 id → the attachment `listMedia` lists for it.
    private(set) var reactionReferences: [String: MediaAttachmentReferenceFfi] = [:]

    /// Large enough for the bubble-free single-emoji treatment at 2x; inline text uses far less.
    static let maxPixelSize: CGFloat = 160
    /// How long a reaction id `listMedia` did not know is left alone before it is looked up again.
    /// The kind-7 and its media can project a moment apart, so a miss is not final, but a
    /// transcript full of them must not turn every scroll into another full media listing.
    static let unresolvedReactionRetryInterval: TimeInterval = 30

    @ObservationIgnored private let accountId: String
    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let groupIdHex: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private let diskCache: MessageMediaDiskCache
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var loading: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingReactionIds: Set<String> = []
    @ObservationIgnored private var unresolvedReactionIds: [String: Date] = [:]
    @ObservationIgnored private var reactionLookup: Task<Void, Never>?

    init(
        accountId: String,
        accountRef: String,
        groupIdHex: String,
        runtime: any MarmotRuntime,
        diskCache: MessageMediaDiskCache = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.accountId = accountId
        self.accountRef = accountRef
        self.groupIdHex = groupIdHex
        self.runtime = runtime
        self.diskCache = diskCache
        self.now = now
    }

    nonisolated static func key(for reference: MediaAttachmentReferenceFfi) -> String {
        reference.plaintextSha256.lowercased()
    }

    func image(for reference: MediaAttachmentReferenceFfi) -> NSImage? {
        images[Self.key(for: reference)]
    }

    func hasFailed(_ reference: MediaAttachmentReferenceFfi) -> Bool {
        failed.contains(Self.key(for: reference))
    }

    /// The image for a reaction, once its kind-7's attachment has been resolved and loaded.
    func reactionImage(for reaction: MessageReaction) -> NSImage? {
        guard reaction.customEmojiShortcode != nil, let messageIdHex = reaction.reactionMessageIdHex,
            let reference = reactionReferences[messageIdHex]
        else { return nil }
        return image(for: reference)
    }

    /// Starts loading `reference` unless it is loaded, loading, or known to fail.
    func load(_ reference: MediaAttachmentReferenceFfi) {
        let key = Self.key(for: reference)
        guard images[key] == nil, !failed.contains(key), loading[key] == nil else { return }
        loading[key] = Task { [weak self] in
            await self?.fetch(reference, key: key)
        }
    }

    /// Resolves each custom-emoji reaction's image through `listMedia`, then loads it.
    func loadReactions(_ reactions: [MessageReaction]) {
        for reaction in reactions {
            guard reaction.customEmojiShortcode != nil, let messageIdHex = reaction.reactionMessageIdHex else {
                continue
            }
            if let reference = reactionReferences[messageIdHex] {
                load(reference)
            } else if let missedAt = unresolvedReactionIds[messageIdHex],
                now().timeIntervalSince(missedAt) < Self.unresolvedReactionRetryInterval
            {
                continue
            } else {
                pendingReactionIds.insert(messageIdHex)
            }
        }
        guard !pendingReactionIds.isEmpty, reactionLookup == nil else { return }
        reactionLookup = Task { [weak self] in
            await self?.resolvePendingReactions()
        }
    }

    /// Lists the group's media until no requested id is left waiting. Ids requested while a
    /// listing is in flight are answered by the next pass, not by a listing taken before they
    /// were asked for.
    private func resolvePendingReactions() async {
        defer { reactionLookup = nil }
        while !pendingReactionIds.isEmpty {
            let batch = pendingReactionIds
            pendingReactionIds.removeAll()
            let runtime = runtime
            let accountRef = accountRef
            let groupIdHex = groupIdHex
            let records: [MediaRecordFfi]
            do {
                records = try await FFIExecutor.run {
                    try runtime.listMedia(accountRef: accountRef, groupIdHex: groupIdHex, limit: nil)
                }
            } catch {
                let missedAt = now()
                for id in batch { unresolvedReactionIds[id] = missedAt }
                continue
            }
            guard !Task.isCancelled else { return }
            let resolved = Self.reactionReferences(in: records, for: batch)
            let missedAt = now()
            for id in batch {
                if let reference = resolved[id] {
                    reactionReferences[id] = reference
                    unresolvedReactionIds[id] = nil
                    load(reference)
                } else {
                    unresolvedReactionIds[id] = missedAt
                }
            }
        }
    }

    /// The first attachment `records` lists for each of `messageIds`.
    nonisolated static func reactionReferences(
        in records: [MediaRecordFfi],
        for messageIds: Set<String>
    ) -> [String: MediaAttachmentReferenceFfi] {
        var best: [String: MediaRecordFfi] = [:]
        for record in records where messageIds.contains(record.messageIdHex) {
            if let current = best[record.messageIdHex], current.attachmentIndex <= record.attachmentIndex {
                continue
            }
            best[record.messageIdHex] = record
        }
        return best.mapValues(\.reference)
    }

    private func fetch(_ reference: MediaAttachmentReferenceFfi, key: String) async {
        defer { loading[key] = nil }
        let cacheKey = MessageMediaDiskCacheKey(accountId: accountId, groupIdHex: groupIdHex, reference: reference)
        var download = await diskCache.cachedDownload(for: cacheKey)
        if download == nil {
            let runtime = runtime
            let accountRef = accountRef
            let groupIdHex = groupIdHex
            do {
                let result = try await withMediaAttachmentDownloadTimeout {
                    try await runtime.downloadMedia(
                        accountRef: accountRef, groupIdHex: groupIdHex, reference: reference)
                }
                let fetched = MessageMediaDownload(
                    data: result.plaintext,
                    fileName: result.fileName,
                    mediaType: result.mediaType,
                    sizeBytes: result.sizeBytes,
                    payloadId: "custom-emoji-\(key)"
                )
                await diskCache.store(fetched, for: cacheKey)
                download = fetched
            } catch is CancellationError {
                return
            } catch {
                failed.insert(key)
                return
            }
        }
        guard let download,
            let loaded = await RemoteImageLoader.shared.image(for: download.payload, maxPixelSize: Self.maxPixelSize)
        else {
            failed.insert(key)
            return
        }
        images[key] = loaded.nsImage
    }
}
