import AppKit
import Foundation
import MarmotKit
import Observation

/// The decoded images behind one conversation's NIP-30 custom emoji, for message text and for
/// reactions alike.
///
/// A message's emoji image is one of its own attachments, so its reference is in hand. A
/// reaction's is the attachment of the kind-7 that `ConversationReactionFfi.reactionMessageIdHex`
/// names, which `listMedia` resolves. Either way the bytes come through `downloadMedia` under the
/// shared attachment-download cap, and keep their media epoch secret, so they stay decryptable
/// after the group advances.
///
/// The media disk cache is read, never written: an emoji image is small and lives in memory for
/// as long as the conversation does. Writing would need the purge fencing `WorkspaceState` keeps
/// for ordinary attachments, without which a download finishing after Settings cleared the cache
/// (or the account was removed) would put the bytes back.
@MainActor
@Observable
final class CustomEmojiImageStore {
    /// Decoded images, keyed by `key(for:)`.
    private(set) var images: [String: NSImage] = [:]
    /// Keys with no image to draw right now: the bytes are not an image (final), or a download
    /// failed and is waiting to be retried. Their shortcode shows as the literal `:shortcode:`.
    private(set) var unavailable: Set<String> = []
    /// Reaction kind-7 id → the attachment `listMedia` lists for it. Filled from whole listings, so
    /// a reaction scrolled into view later usually resolves without another one.
    private(set) var reactionReferences: [String: MediaAttachmentReferenceFfi] = [:]

    /// Large enough for the bubble-free single-emoji treatment at 2x; inline text uses far less.
    static let maxPixelSize: CGFloat = 160
    /// How long a reaction id `listMedia` did not know is left alone before it is looked up again.
    /// The kind-7 and its media can project a moment apart, so a miss is not final, but a
    /// transcript full of them must not turn every scroll into another full media listing.
    static let unresolvedReactionRetryInterval: TimeInterval = 30
    /// Waits before each retry of a failed download; once they are spent the image is given up.
    /// The attachment has no tile or Download action of its own (it draws as text), so this is
    /// its only way back from a timeout or a relay hiccup.
    static let defaultRetryDelays: [Duration] = [.seconds(15), .seconds(60), .seconds(240)]

    @ObservationIgnored private let accountId: String
    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let groupIdHex: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private let diskCache: MessageMediaDiskCache
    @ObservationIgnored private let limiter: MediaAttachmentDownloadLimiter
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var loading: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloads: [String: Task<MediaDownloadResultFfi, Error>] = [:]
    @ObservationIgnored private var retries: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var permanentlyFailed: Set<String> = []
    @ObservationIgnored private var pendingReactionIds: Set<String> = []
    @ObservationIgnored private var unresolvedReactionIds: [String: Date] = [:]
    @ObservationIgnored private var reactionLookup: Task<Void, Never>?

    init(
        accountId: String,
        accountRef: String,
        groupIdHex: String,
        runtime: any MarmotRuntime,
        diskCache: MessageMediaDiskCache = .shared,
        limiter: MediaAttachmentDownloadLimiter = .shared,
        retryDelays: [Duration] = defaultRetryDelays,
        now: @escaping () -> Date = Date.init
    ) {
        self.accountId = accountId
        self.accountRef = accountRef
        self.groupIdHex = groupIdHex
        self.runtime = runtime
        self.diskCache = diskCache
        self.limiter = limiter
        self.retryDelays = retryDelays
        self.now = now
    }

    nonisolated static func key(for reference: MediaAttachmentReferenceFfi) -> String {
        reference.plaintextSha256.lowercased()
    }

    func image(for reference: MediaAttachmentReferenceFfi) -> NSImage? {
        images[Self.key(for: reference)]
    }

    /// No image to draw now, nor one loading: show the literal `:shortcode:`.
    func isUnavailable(_ reference: MediaAttachmentReferenceFfi) -> Bool {
        unavailable.contains(Self.key(for: reference))
    }

    /// The image for a reaction, once its kind-7's attachment has been resolved and loaded.
    func reactionImage(for reaction: MessageReaction) -> NSImage? {
        guard reaction.customEmojiShortcode != nil, let messageIdHex = reaction.reactionMessageIdHex,
            let reference = reactionReferences[messageIdHex]
        else { return nil }
        return image(for: reference)
    }

    /// Starts loading `reference` unless it is loaded, loading, waiting to retry, or given up.
    func load(_ reference: MediaAttachmentReferenceFfi) {
        let key = Self.key(for: reference)
        guard images[key] == nil, !unavailable.contains(key), loading[key] == nil else { return }
        loading[key] = Task { [weak self] in
            await self?.fetch(reference, key: key)
        }
    }

    /// Stops every download, retry and lookup. The conversation is going away, or its account is.
    func cancelAll() {
        for task in loading.values { task.cancel() }
        for task in downloads.values { task.cancel() }
        for task in retries.values { task.cancel() }
        reactionLookup?.cancel()
        loading.removeAll()
        downloads.removeAll()
        retries.removeAll()
        reactionLookup = nil
        pendingReactionIds.removeAll()
        // A download cut short is not a failure: let the next `load` start over.
        unavailable.formIntersection(permanentlyFailed)
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
        while !pendingReactionIds.isEmpty, !Task.isCancelled {
            let batch = pendingReactionIds
            pendingReactionIds.removeAll()
            let runtime = runtime
            let accountRef = accountRef
            let groupIdHex = groupIdHex
            let listed: [String: MediaAttachmentReferenceFfi]
            do {
                // Built off the main actor: a long-lived group lists a lot of media.
                listed = try await FFIExecutor.run {
                    Self.reactionReferences(
                        in: try runtime.listMedia(accountRef: accountRef, groupIdHex: groupIdHex, limit: nil))
                }
            } catch {
                let missedAt = now()
                for id in batch { unresolvedReactionIds[id] = missedAt }
                continue
            }
            guard !Task.isCancelled else { return }
            reactionReferences.merge(listed) { _, latest in latest }
            let missedAt = now()
            for id in batch {
                if let reference = listed[id] {
                    unresolvedReactionIds[id] = nil
                    load(reference)
                } else {
                    unresolvedReactionIds[id] = missedAt
                }
            }
        }
    }

    /// Each message's first attachment in `records`.
    nonisolated static func reactionReferences(in records: [MediaRecordFfi]) -> [String: MediaAttachmentReferenceFfi] {
        var best: [String: MediaRecordFfi] = [:]
        for record in records {
            if let current = best[record.messageIdHex], current.attachmentIndex <= record.attachmentIndex {
                continue
            }
            best[record.messageIdHex] = record
        }
        return best.mapValues(\.reference)
    }

    private func fetch(_ reference: MediaAttachmentReferenceFfi, key: String) async {
        defer { loading[key] = nil }
        let payload: DownloadedMediaPayload
        let cacheKey = MessageMediaDiskCacheKey(accountId: accountId, groupIdHex: groupIdHex, reference: reference)
        if let cached = await diskCache.cachedDownload(for: cacheKey) {
            payload = cached.payload
        } else {
            let download = startDownload(reference, key: key)
            do {
                // The timeout waits on the download rather than holding its permit, so a timed-out
                // FFI call keeps its slot until it actually returns.
                let result = try await withMediaAttachmentDownloadTimeout { try await download.value }
                downloads[key] = nil
                payload = DownloadedMediaPayload(id: "custom-emoji-\(UUID().uuidString)", data: result.plaintext)
            } catch is CancellationError {
                return
            } catch {
                downloads[key] = nil
                scheduleRetry(reference, key: key)
                return
            }
        }
        guard !Task.isCancelled else { return }
        guard
            let loaded = await RemoteImageLoader.shared.image(for: payload, maxPixelSize: Self.maxPixelSize)
        else {
            // The bytes arrived and are not an image: no retry will change that.
            permanentlyFailed.insert(key)
            unavailable.insert(key)
            return
        }
        guard !Task.isCancelled else { return }
        attempts[key] = nil
        images[key] = loaded.nsImage
    }

    private func startDownload(
        _ reference: MediaAttachmentReferenceFfi,
        key: String
    ) -> Task<MediaDownloadResultFfi, Error> {
        if let existing = downloads[key] { return existing }
        let task = Task.detached(priority: .userInitiated) {
            [runtime, accountRef, groupIdHex, limiter] in
            try await limiter.withPermit {
                try await runtime.downloadMedia(accountRef: accountRef, groupIdHex: groupIdHex, reference: reference)
            }
        }
        downloads[key] = task
        return task
    }

    /// Shows the literal shortcode while the next attempt waits, then tries again; gives up once
    /// `retryDelays` is spent.
    private func scheduleRetry(_ reference: MediaAttachmentReferenceFfi, key: String) {
        unavailable.insert(key)
        let attempt = attempts[key, default: 0]
        guard attempt < retryDelays.count else {
            permanentlyFailed.insert(key)
            return
        }
        attempts[key] = attempt + 1
        let delay = retryDelays[attempt]
        retries[key] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retries[key] = nil
            self.unavailable.remove(key)
            self.load(reference)
        }
    }
}
