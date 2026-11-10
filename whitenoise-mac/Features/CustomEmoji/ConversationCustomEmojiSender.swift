import Foundation
import MarmotKit
import Observation

/// Sends custom emoji messages and reactions for one conversation.
///
/// Owned by `ConversationViewModel`, so it lives exactly as long as one account's view of one chat:
/// `stop()` cancels in-flight uploads and nothing that completes afterwards reaches MDK. Uploaded
/// references are kept per plaintext digest and reused for every later send and retry, so a
/// failed send never uploads the same image twice; concurrent sends share one in-flight upload.
@MainActor
@Observable
final class ConversationCustomEmojiSender {
    enum State: Equatable {
        case idle
        case sending
        case failed(String)
    }

    /// The last outcome, for the composer's inline notice.
    private(set) var state: State = .idle

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var isSending: Bool { state == .sending }

    /// How many uploaded references stay cached.
    static let uploadLimit = 64

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let groupIdHex: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    /// The chat's emoji images, handed each image as it is uploaded so this device's own message
    /// draws it at once (`CustomEmojiImageStore.adopt`).
    @ObservationIgnored private let images: CustomEmojiImageStore?
    @ObservationIgnored private var uploaded: [String: MediaAttachmentReferenceFfi] = [:]
    @ObservationIgnored private var uploadOrder: [String] = []
    @ObservationIgnored private var inFlight: [String: Task<(MediaAttachmentReferenceFfi, Data), Error>] = [:]
    @ObservationIgnored private var isStopped = false
    /// Upload calls made, for tests asserting a retry never re-uploads.
    @ObservationIgnored private(set) var uploadCount = 0

    init(accountRef: String, groupIdHex: String, runtime: any MarmotRuntime, images: CustomEmojiImageStore? = nil) {
        self.accountRef = accountRef
        self.groupIdHex = groupIdHex
        self.runtime = runtime
        self.images = images
    }

    // MARK: - Composer and reaction entry points

    /// Sends a composer draft that uses custom emoji. Returns true once MDK accepted the message;
    /// on failure the notice says why and the draft stays for a retry. Refused while another send
    /// is in flight.
    @discardableResult
    func submit(text: String, replyTargetId: String?, emoji: [CustomEmojiSendable]) async -> Bool {
        guard state != .sending else { return false }
        state = .sending
        do {
            try await sendMessage(text: text, replyTargetId: replyTargetId, emoji: emoji)
            state = .idle
            return true
        } catch is CancellationError {
            state = .idle
            return false
        } catch {
            state = .failed((error as? CustomEmojiSendError ?? .sendFailed).message)
            return false
        }
    }

    /// Reacts with one custom emoji, showing a failure in the same notice.
    func react(with emoji: CustomEmojiSendable, to targetMessageId: String) async {
        do {
            try await sendReaction(emoji, to: targetMessageId)
            if case .failed = state { state = .idle }
        } catch is CancellationError {
            return
        } catch {
            guard state != .sending else { return }
            state = .failed((error as? CustomEmojiSendError ?? .sendFailed).message)
        }
    }

    func report(_ error: CustomEmojiSendError) {
        guard state != .sending else { return }
        state = .failed(error.message)
    }

    func dismissError() {
        guard state != .sending else { return }
        state = .idle
    }

    func stop() {
        isStopped = true
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Sending

    /// Sends `text` as a kind-9 whose attachments are the `emoji` images, in text order, each named
    /// by an `emoji` tag; a reply adds `e` + `q`. A reference MDK refuses as encrypted under an
    /// earlier epoch is dropped and re-encrypted once for the current one.
    func sendMessage(text: String, replyTargetId: String?, emoji: [CustomEmojiSendable]) async throws {
        guard !emoji.isEmpty else { throw CustomEmojiSendError.malformedTag }
        try CustomEmojiTags.precheck(emojiCount: emoji.count, isReply: replyTargetId != nil)
        if let replyTargetId {
            try CustomEmojiTags.validate([[CustomEmojiTags.eventRefTag, replyTargetId]])
        }
        try await retryingOnceWhenStale {
            let references = try await self.upload(emoji)
            let tags = try CustomEmojiTags.messageTags(
                emoji: zip(emoji, references).map { ($0.shortcode, $1) }, replyTargetId: replyTargetId)
            // Shortcode aliases of one image share an upload: one attachment, one `emoji` tag each.
            var seen = Set<MediaAttachmentReferenceFfi>()
            let attachments = references.filter { seen.insert($0).inserted }
            try self.ensureRunning()
            do {
                _ = try await self.runtime.sendTaggedMedia(
                    accountRef: self.accountRef, groupIdHex: self.groupIdHex, attachments: attachments,
                    caption: text, tags: tags)
            } catch {
                throw self.classify(error, references: attachments)
            }
        }
    }

    /// Reacts to `targetMessageId` with one custom emoji: a kind-7 whose content is `:shortcode:`,
    /// carrying the image re-encrypted into the chat and named by one `emoji` tag.
    func sendReaction(_ emoji: CustomEmojiSendable, to targetMessageId: String) async throws {
        guard !targetMessageId.isEmpty else { throw CustomEmojiSendError.emptyEventTarget }
        try await retryingOnceWhenStale {
            guard let reference = try await self.upload([emoji]).first else {
                throw CustomEmojiSendError.uploadFailed
            }
            let tags = [try CustomEmojiTags.emojiTag(emoji.shortcode, reference: reference)]
            try CustomEmojiTags.validate(tags)
            try self.ensureRunning()
            let summary: SendSummaryFfi
            do {
                summary = try await self.runtime.reactWithMedia(
                    accountRef: self.accountRef, groupIdHex: self.groupIdHex, targetMessageId: targetMessageId,
                    emoji: emoji.token, tags: tags, attachments: [reference])
            } catch {
                throw self.classify(error, references: [reference])
            }
            self.images?.recordOwnReaction(messageIds: summary.messageIds, reference: reference)
        }
    }

    private func retryingOnceWhenStale(_ attempt: () async throws -> Void) async throws {
        do {
            try await attempt()
        } catch CustomEmojiSendError.staleEpoch {
            try ensureRunning()
            try await attempt()
        }
    }

    private func upload(_ emoji: [CustomEmojiSendable]) async throws -> [MediaAttachmentReferenceFfi] {
        var references: [MediaAttachmentReferenceFfi] = []
        for item in emoji {
            references.append(try await reference(for: item))
            try ensureRunning()
        }
        return references
    }

    /// A reference for `sendable` encrypted into this chat, uploading it at most once at a time.
    private func reference(for sendable: CustomEmojiSendable) async throws -> MediaAttachmentReferenceFfi {
        try ensureRunning()
        let key = sendable.plaintextSha256
        if let cached = uploaded[key] { return cached }
        if let pending = inFlight[key] { return try await pending.value.0 }
        let task = Task { [runtime, accountRef, groupIdHex] () throws -> (MediaAttachmentReferenceFfi, Data) in
            let request = try await Self.request(
                for: sendable, runtime: runtime, accountRef: accountRef, groupIdHex: groupIdHex)
            try Task.checkCancellation()
            let result: MediaUploadResultFfi
            do {
                result = try await runtime.uploadMedia(
                    accountRef: accountRef, groupIdHex: groupIdHex,
                    request: MediaUploadRequestFfi(
                        attachments: [request], caption: nil, send: false, blossomServer: nil, messageTags: []))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CustomEmojiSendError.uploadFailed
            }
            guard let reference = result.attachments.first?.reference,
                reference.plaintextSha256.lowercased() == key,
                reference.locators.first.map({ !$0.value.isEmpty }) == true
            else { throw CustomEmojiSendError.uploadFailed }
            return (reference, request.plaintext)
        }
        inFlight[key] = task
        uploadCount += 1
        defer { inFlight[key] = nil }
        let (reference, plaintext) = try await task.value
        try ensureRunning()
        store(reference, for: key)
        // Before the send, so the row MDK projects for it already has its image.
        await images?.adopt(plaintext, plaintextSha256: key)
        return reference
    }

    /// The plaintext to upload: a chat image MDK still holds, an installed set emoji, or a
    /// built-in. Every byte source is checked against the digest the emoji is known by.
    private nonisolated static func request(
        for sendable: CustomEmojiSendable, runtime: any MarmotRuntime, accountRef: String, groupIdHex: String
    ) async throws -> MediaUploadAttachmentRequestFfi {
        switch sendable.artwork {
        case .builtin(let builtin):
            return CustomEmojiUploadRequest.builtin(builtin)
        case .chat(let reference):
            let data = try await bytes {
                try await runtime.downloadMedia(accountRef: accountRef, groupIdHex: groupIdHex, reference: reference)
                    .plaintext
            }
            guard CustomEmojiDigest.hex(data) == sendable.plaintextSha256 else {
                throw CustomEmojiSendError.imageUnavailable
            }
            return CustomEmojiUploadRequest.chat(reference, plaintext: data)
        case .installed(let emoji):
            let data = try await bytes {
                try await runtime.readInstalledCustomEmoji(
                    accountRef: accountRef, coordinate: emoji.setCoordinate, shortcode: emoji.shortcode
                ).bytes
            }
            guard CustomEmojiDigest.hex(data) == sendable.plaintextSha256 else {
                throw CustomEmojiSendError.imageUnavailable
            }
            return CustomEmojiUploadRequest.installed(emoji, plaintext: data)
        }
    }

    private nonisolated static func bytes(_ read: () async throws -> Data) async throws -> Data {
        do {
            return try await read()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CustomEmojiSendError.imageUnavailable
        }
    }

    private func ensureRunning() throws {
        guard !isStopped, !Task.isCancelled else { throw CancellationError() }
    }

    private func store(_ reference: MediaAttachmentReferenceFfi, for key: String) {
        if uploaded.updateValue(reference, forKey: key) == nil { uploadOrder.append(key) }
        while uploadOrder.count > Self.uploadLimit {
            uploaded[uploadOrder.removeFirst()] = nil
        }
    }

    private func invalidate(_ reference: MediaAttachmentReferenceFfi) {
        for (key, value) in uploaded where value == reference {
            uploaded[key] = nil
            uploadOrder.removeAll { $0 == key }
        }
    }

    /// A reference encrypted under an earlier epoch, or another branch at the same epoch, can never
    /// be sent: forget it so the retry re-encrypts once for the current one. While the epoch is
    /// unsettled the reference may still be good, so it is kept. Any other failure keeps it too.
    private func classify(_ error: Error, references: [MediaAttachmentReferenceFfi]) -> Error {
        if error is CancellationError || error is CustomEmojiSendError { return error }
        switch error as? MarmotKitError {
        case .MediaReferenceStaleEpoch?, .InvalidMediaReference?:
            references.forEach(invalidate)
            return CustomEmojiSendError.staleEpoch
        case .MediaReferenceEpochUnsettled?:
            return CustomEmojiSendError.epochUnsettled
        default:
            return CustomEmojiSendError.sendFailed
        }
    }
}
