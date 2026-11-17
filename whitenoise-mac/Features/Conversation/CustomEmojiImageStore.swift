import AppKit
import Foundation
import MarmotKit
import Observation

/// The decoded images behind one conversation's NIP-30 custom emoji, for message text and for
/// reactions alike.
///
/// A message's emoji image is one of its own attachments, so its reference is in hand. A
/// reaction's is the attachment of the kind-7 that `ConversationReactionFfi.reactionMessageIdHex`
/// names, which MarmotKit 0.15's `reactionAttachment` resolves with one bounded local read.
///
/// Bytes come from MDK's retained copy of the attachment's source slot first, as on iOS: a local
/// read with no network, so an emoji the device already holds draws about as soon as the row does.
/// A slot MDK does not hold yet is asked for with `requestAutomaticAttachment`, which puts it ahead
/// of other automatic work and keeps it for the next open, and awaited for a bounded time. Only
/// when that is not possible (no slot, automatic downloads off, a terminal transfer, a timeout) do
/// the bytes come through `downloadMedia`, under the emoji's own download cap so tiny images never
/// queue behind the photos and videos of the same chat.
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
    /// Reaction kind-7 id → the image attachment `reactionAttachment` resolved for it.
    private(set) var reactionReferences: [String: MediaAttachmentReferenceFfi] = [:]
    /// Reaction kind-7 id → the source slot MDK resolved its image from.
    @ObservationIgnored private var reactionTargets: [String: AttachmentLocalTargetFfi] = [:]
    /// Reaction kind-7 ids MDK holds no image for. A built-in shortcode among them draws the
    /// bundled image, as on iOS; any other stays its literal `:shortcode:`.
    private(set) var reactionsWithoutArtwork: Set<String> = []

    /// Large enough for the bubble-free single-emoji treatment at 2x; inline text uses far less.
    static let maxPixelSize: CGFloat = 160
    /// How long a reaction id MDK had no artwork for is left alone before it is looked up again.
    /// The kind-7 and its media can project a moment apart, so a miss is not final, but a
    /// transcript full of them must not re-read on every scroll.
    static let unresolvedReactionRetryInterval: TimeInterval = 30
    /// Waits before each retry of a failed download; once they are spent the image is given up.
    /// The attachment has no tile or Download action of its own (it draws as text), so this is
    /// its only way back from a timeout or a relay hiccup.
    static let defaultRetryDelays: [Duration] = [.seconds(15), .seconds(60), .seconds(240)]
    /// How long an emoji waits on MDK's own acquisition of its slot before falling back to
    /// `downloadMedia`. MDK moves it ahead of other automatic work, so this only runs out when the
    /// relay is slow, and the fallback then fetches it directly.
    static let retainedAcquisitionTimeout: Duration = .seconds(20)
    /// A retained emoji larger than this is not read into memory: it is no emoji.
    static let maxRetainedBytes: UInt64 = 8 * 1024 * 1024
    /// Emoji downloads get a cap of their own rather than `MediaAttachmentDownloadLimiter.shared`:
    /// each is a few kilobytes, and behind a chat's photos and videos they took seconds to appear.
    static let downloadLimiter = MediaAttachmentDownloadLimiter(
        maxConcurrent: MediaAttachmentDownloadConcurrency.maxConcurrentDownloads)

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
    /// The source slot MDK retains each key's bytes under, when the caller knew it.
    @ObservationIgnored private var targets: [String: AttachmentLocalTargetFfi] = [:]
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
        limiter: MediaAttachmentDownloadLimiter = CustomEmojiImageStore.downloadLimiter,
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

    /// The image for a reaction, once its kind-7's attachment has been resolved and loaded, or
    /// the built-in of that name when the reaction carries no image.
    func reactionImage(for reaction: MessageReaction) -> NSImage? {
        guard let shortcode = reaction.customEmojiShortcode, let messageIdHex = reaction.reactionMessageIdHex
        else { return nil }
        // Until its own image decodes, a built-in shortcode keeps the bundled glyph rather than
        // flipping back to text while a late-found image downloads.
        if let reference = reactionReferences[messageIdHex] {
            return image(for: reference) ?? CustomEmojiBuiltinImages.image(for: shortcode)
        }
        guard reactionsWithoutArtwork.contains(messageIdHex) else { return nil }
        return CustomEmojiBuiltinImages.image(for: shortcode)
    }

    /// Names the image this device attached to its own reaction, under the ids MDK returned for
    /// it. Right after the send MDK may not link the kind-7 to its image yet, and a miss is only
    /// looked up again after `unresolvedReactionRetryInterval`.
    func recordOwnReaction(messageIds: [String], reference: MediaAttachmentReferenceFfi) {
        for messageIdHex in messageIds where !messageIdHex.isEmpty {
            reactionReferences[messageIdHex] = reference
            reactionTargets[messageIdHex] = nil
            reactionsWithoutArtwork.remove(messageIdHex)
            unresolvedReactionIds[messageIdHex] = nil
            pendingReactionIds.remove(messageIdHex)
        }
        load(reference)
    }

    /// Starts loading `reference` unless it is loaded, loading, waiting to retry, or given up.
    /// `target` is the source slot MDK retains the attachment under; with it the bytes are read
    /// locally when MDK holds them, which is what makes an emoji draw without a network round trip.
    func load(_ reference: MediaAttachmentReferenceFfi, target: AttachmentLocalTargetFfi? = nil) {
        let key = Self.key(for: reference)
        if let target { targets[key] = target }
        guard images[key] == nil, !unavailable.contains(key), loading[key] == nil else { return }
        loading[key] = Task { [weak self] in
            await self?.fetch(reference, key: key)
        }
    }

    /// Draws `plaintext` for every attachment with this digest, with no download: the bytes of an
    /// emoji this device just uploaded. MDK serves a sender's own attachment locally only once the
    /// message is confirmed, and `downloadMedia` would fetch it back from the server, so without
    /// this the sent message shows its literal `:shortcode:` until a retry.
    func adopt(_ plaintext: Data, plaintextSha256: String) async {
        let key = plaintextSha256.lowercased()
        guard images[key] == nil else { return }
        let payload = DownloadedMediaPayload(id: "custom-emoji-\(UUID().uuidString)", data: plaintext)
        guard let loaded = await RemoteImageLoader.shared.image(for: payload, maxPixelSize: Self.maxPixelSize),
            images[key] == nil
        else { return }
        retries[key]?.cancel()
        retries[key] = nil
        attempts[key] = nil
        permanentlyFailed.remove(key)
        unavailable.remove(key)
        images[key] = loaded.nsImage
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

    /// Resolves each custom-emoji reaction's image through `reactionAttachment`, then loads it.
    func loadReactions(_ reactions: [MessageReaction]) {
        for reaction in reactions {
            guard reaction.customEmojiShortcode != nil, let messageIdHex = reaction.reactionMessageIdHex else {
                continue
            }
            if let reference = reactionReferences[messageIdHex] {
                load(reference, target: reactionTargets[messageIdHex])
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

    /// Reads each requested reaction's artwork, one at a time, until none is left waiting. Ids
    /// requested while a read is in flight are picked up by the next pass.
    private func resolvePendingReactions() async {
        defer { reactionLookup = nil }
        while let reactionMessageIdHex = pendingReactionIds.first, !Task.isCancelled {
            pendingReactionIds.remove(reactionMessageIdHex)
            let entry: AttachmentEntryFfi?
            do {
                entry = try await runtime.reactionAttachment(
                    accountRef: accountRef, groupIdHex: groupIdHex, reactionMessageIdHex: reactionMessageIdHex)
            } catch {
                guard !Task.isCancelled else { return }
                unresolvedReactionIds[reactionMessageIdHex] = now()
                continue
            }
            // Recorded by this device's own send while the read was in flight.
            guard !Task.isCancelled, reactionReferences[reactionMessageIdHex] == nil else { continue }
            if let reference = Self.reactionReference(entry, reactionMessageIdHex: reactionMessageIdHex) {
                unresolvedReactionIds[reactionMessageIdHex] = nil
                reactionsWithoutArtwork.remove(reactionMessageIdHex)
                reactionReferences[reactionMessageIdHex] = reference
                reactionTargets[reactionMessageIdHex] = entry.map(Self.localTarget)
                load(reference, target: reactionTargets[reactionMessageIdHex])
            } else {
                unresolvedReactionIds[reactionMessageIdHex] = now()
                reactionsWithoutArtwork.insert(reactionMessageIdHex)
            }
        }
    }

    /// The loadable image MDK resolved for a reaction: an accepted image attachment of that same
    /// kind-7. Anything else (no entry, another event's slot, a rejected or non-image attachment)
    /// counts as no artwork: the built-in of that name, or else the literal shortcode.
    nonisolated static func reactionReference(
        _ entry: AttachmentEntryFfi?, reactionMessageIdHex: String
    ) -> MediaAttachmentReferenceFfi? {
        guard let entry, entry.messageIdHex.caseInsensitiveCompare(reactionMessageIdHex) == .orderedSame,
            entry.category == .image,
            case .accepted(_, let reference) = entry.attachment,
            reference.mediaType.lowercased().hasPrefix("image/")
        else { return nil }
        return reference
    }

    /// The original source slot of a resolved reaction image, which MDK's local reads take.
    nonisolated static func localTarget(_ entry: AttachmentEntryFfi) -> AttachmentLocalTargetFfi {
        let attachmentIndex: UInt32 =
            switch entry.attachment {
            case .accepted(let index, _), .rejected(let index, _): index
            }
        return AttachmentLocalTargetFfi(
            messageIdHex: entry.messageIdHex, sourceMessageIdHex: entry.sourceMessageIdHex,
            attachmentIndex: attachmentIndex)
    }

    private func fetch(_ reference: MediaAttachmentReferenceFfi, key: String) async {
        defer { loading[key] = nil }
        let payload: DownloadedMediaPayload
        let cacheKey = MessageMediaDiskCacheKey(accountId: accountId, groupIdHex: groupIdHex, reference: reference)
        if let cached = await diskCache.cachedDownload(for: cacheKey) {
            payload = cached.payload
        } else if let target = targets[key], let retained = await retainedBytes(reference, target: target) {
            guard !Task.isCancelled else { return }
            payload = DownloadedMediaPayload(id: "custom-emoji-\(UUID().uuidString)", data: retained)
        } else {
            guard !Task.isCancelled else { return }
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
            guard images[key] == nil else { return }
            permanentlyFailed.insert(key)
            unavailable.insert(key)
            return
        }
        guard !Task.isCancelled else { return }
        attempts[key] = nil
        images[key] = loaded.nsImage
    }

    /// The emoji's bytes from MDK's retained copy of `target`, asking MDK to acquire the slot when
    /// it holds none yet. Nil hands the load to `downloadMedia`: no automatic acquisition possible,
    /// a terminal transfer, a timeout, a read error, or bytes that are not the referenced image.
    private func retainedBytes(
        _ reference: MediaAttachmentReferenceFfi, target: AttachmentLocalTargetFfi
    ) async -> Data? {
        let data: Data?
        do {
            data = try await withMediaAttachmentDownloadTimeout(
                nanoseconds: UInt64(Self.retainedAcquisitionTimeout.components.seconds) * 1_000_000_000
            ) { [runtime, accountRef, groupIdHex] in
                try await CustomEmojiRetainedBytes.acquire(
                    runtime: runtime, accountRef: accountRef, groupIdHex: groupIdHex, target: target,
                    maxBytes: Self.maxRetainedBytes)
            }
        } catch {
            return nil
        }
        guard let data, CustomEmojiDigest.hex(data) == reference.plaintextSha256.lowercased() else { return nil }
        return data
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
        // Adopted while this download was failing: there is an image to draw.
        guard images[key] == nil else { return }
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
            self.load(reference, target: self.targets[key])
        }
    }
}
