import AVFoundation
import AppKit
import Foundation
import ImageIO
import MarmotKit
import UniformTypeIdentifiers

struct AccountItem: Identifiable, Hashable {
    let id: String
    let accountRef: String
    let displayName: String
    let accountIdHex: String
    let npub: String?
    let initials: String
    let pictureURL: String?
    /// Pre-sanitized avatar URL; `ProfileImageAvatarView` still applies `loadRemoteImages`.
    let sanitizedPictureURL: URL?
    let localSigning: Bool
    let isRunning: Bool
    /// True when the account has been signed out (non-destructive): local data is
    /// retained but it is not active until signed back in.
    let signedOut: Bool

    nonisolated init(
        id: String,
        accountRef: String,
        displayName: String,
        accountIdHex: String,
        npub: String? = nil,
        initials: String? = nil,
        pictureURL: String? = nil,
        sanitizedPictureURL: URL? = nil,
        localSigning: Bool = true,
        isRunning: Bool = true,
        signedOut: Bool = false
    ) {
        self.id = id
        self.accountRef = accountRef
        self.displayName = displayName
        self.accountIdHex = accountIdHex
        self.npub = npub
        self.initials = initials ?? DisplayText.initials(for: displayName, fallback: accountIdHex)
        self.pictureURL = pictureURL
        self.sanitizedPictureURL =
            sanitizedPictureURL ?? RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
        self.localSigning = localSigning
        self.isRunning = isRunning
        self.signedOut = signedOut
    }
}

nonisolated struct ChatItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let preview: String
    let updatedAt: Date?
    let avatarSeed: String
    let pictureURL: String?
    /// Pre-sanitized avatar URL for chat rows/headers; the view still applies `loadRemoteImages`.
    let sanitizedPictureURL: URL?
    let unreadCount: Int
    /// Unread messages in this chat that @-mention the active account.
    let unreadMentionCount: Int
    let isDirect: Bool
    let pendingConfirmation: Bool
    /// Precomputed once from `updatedAt` (which is immutable for a given value) to
    /// avoid re-formatting the date on every chat-row render.
    let timestampLabel: String

    /// Whether this chat has at least one unread @-mention of the active account.
    var hasMention: Bool { unreadMentionCount > 0 }

    init(
        id: String,
        title: String,
        subtitle: String,
        preview: String,
        updatedAt: Date?,
        avatarSeed: String,
        pictureURL: String?,
        sanitizedPictureURL: URL? = nil,
        unreadCount: Int,
        unreadMentionCount: Int = 0,
        isDirect: Bool = false,
        pendingConfirmation: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.preview = preview
        self.updatedAt = updatedAt
        self.avatarSeed = avatarSeed
        self.pictureURL = pictureURL
        self.sanitizedPictureURL =
            sanitizedPictureURL ?? RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
        self.unreadCount = unreadCount
        self.unreadMentionCount = unreadMentionCount
        self.isDirect = isDirect
        self.pendingConfirmation = pendingConfirmation
        if let updatedAt {
            self.timestampLabel = DisplayText.relativeTimestamp(for: updatedAt)
        } else {
            self.timestampLabel = ""
        }
    }
}

// `Sendable` so the timeline window/projection mapping can capture the resolved
// sender-profile map in the off-main `MessageItem.timeline(...)` closure
// (whitenoise-mac#285). All stored properties are value types, so the conformance is
// checked; `nonisolated` opts the value type out of the module's default main-actor
// isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), a prerequisite for `Sendable`.
nonisolated struct ChatPeerProfile: Hashable, Sendable {
    let accountIdHex: String
    let displayName: String?
    let pictureURL: String?
}

struct GroupMemberItem: Identifiable, Hashable {
    let id: String
    let displayName: String
    let npub: String
    let accountLabel: String?
    let isLocal: Bool
    let isAdmin: Bool
    let isSelf: Bool
    let canRemove: Bool
    let canPromote: Bool
    let canDemote: Bool

    var initials: String {
        DisplayText.initials(for: displayName, fallback: id)
    }

    var detailLabel: String {
        if isSelf {
            return L10n.string("You")
        }
        if let accountLabel, !accountLabel.isEmpty {
            return accountLabel
        }
        return DisplayText.short(npub, head: 12, tail: 8)
    }
}

struct GroupDetailsSnapshot: Hashable {
    let groupIdHex: String
    let endpoint: String
    let name: String
    let description: String
    let avatarURL: String?
    /// Pre-sanitized once from the group profile avatar URL for details/header rendering.
    let sanitizedAvatarURL: URL?
    let avatarDimension: String?
    let nostrGroupIdHex: String
    let relays: [String]
    let adminIds: [String]
    let archived: Bool
    let pendingConfirmation: Bool
    let members: [GroupMemberItem]
    let isSelfAdmin: Bool
    let isLastAdmin: Bool
    let canInvite: Bool
    let canLeave: Bool
    let requiresSelfDemoteBeforeLeave: Bool
    /// Per-group disappearing-message timer in seconds; `0` means messages never expire.
    let disappearingMessageSecs: UInt64

    var memberCountLabel: String {
        String(format: L10n.string("%d members"), members.count)
    }

    var disappearingMessagesEnabled: Bool { disappearingMessageSecs > 0 }
}

enum GroupDetailsHeaderAvatar {
    static func sanitizedURL(snapshot: GroupDetailsSnapshot?, fallback chat: ChatItem) -> URL? {
        snapshot?.sanitizedAvatarURL ?? chat.sanitizedPictureURL
    }
}

nonisolated struct MessageReaction: Identifiable, Hashable {
    let emoji: String
    let count: Int
    let isOwn: Bool
    let ownReactionMessageId: String?

    init(emoji: String, count: Int, isOwn: Bool, ownReactionMessageId: String? = nil) {
        self.emoji = emoji
        self.count = count
        self.isOwn = isOwn
        self.ownReactionMessageId = ownReactionMessageId
    }

    var id: String { emoji }

    var label: String {
        count > 1 ? "\(emoji) \(count)" : emoji
    }

    var canRemoveOwnReaction: Bool {
        ownReactionMessageId != nil
    }
}

nonisolated struct MessageReplyContext: Hashable {
    let targetMessageId: String
    let senderName: String
    let body: String
}

nonisolated enum MessageMediaKind: Hashable, Sendable {
    case image
    case audio
    case video
    case file

    var systemImageName: String {
        switch self {
        case .image:
            "photo"
        case .audio:
            "waveform"
        case .video:
            "play.rectangle"
        case .file:
            "doc"
        }
    }
}

nonisolated struct MessageMediaAttachment: Identifiable, Hashable {
    let id: String
    let reference: MediaAttachmentReferenceFfi

    var fileName: String {
        reference.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.string("Attachment")
            : reference.fileName
    }

    var mediaType: String {
        reference.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "application/octet-stream"
            : reference.mediaType
    }

    var kind: MessageMediaKind {
        let normalized = mediaType.lowercased()
        if normalized.hasPrefix("image/") {
            return .image
        }
        if normalized.hasPrefix("audio/") {
            return .audio
        }
        if normalized.hasPrefix("video/") {
            return .video
        }
        return .file
    }

    var previewLabel: String {
        switch kind {
        case .image:
            return L10n.string("Photo")
        case .audio:
            return L10n.string("Audio")
        case .video:
            return L10n.string("Video")
        case .file:
            return L10n.string("Attachment")
        }
    }

    static func previewText(for attachments: [MessageMediaAttachment]) -> String {
        guard let first = attachments.first else { return "" }
        if attachments.count == 1 {
            return first.previewLabel
        }
        return String(format: L10n.string("%d attachments"), attachments.count)
    }
}

nonisolated final class DownloadedMediaPayload: @unchecked Sendable, Hashable {
    let id: String
    private let storage: Data

    init(id: String = UUID().uuidString, data: Data) {
        self.id = id
        self.storage = data
    }

    var data: Data {
        storage
    }

    var byteCount: Int {
        storage.count
    }

    static func == (lhs: DownloadedMediaPayload, rhs: DownloadedMediaPayload) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated struct MessageMediaDownload: Hashable {
    let payload: DownloadedMediaPayload
    let fileName: String
    let mediaType: String
    let sizeBytes: UInt64
    let sizeLabel: String

    init(
        payload: DownloadedMediaPayload,
        fileName: String,
        mediaType: String,
        sizeBytes: UInt64
    ) {
        self.payload = payload
        self.fileName = fileName
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
        self.sizeLabel = Self.sizeLabel(for: sizeBytes)
    }

    init(
        data: Data,
        fileName: String,
        mediaType: String,
        sizeBytes: UInt64,
        payloadId: String = UUID().uuidString
    ) {
        self.init(
            payload: DownloadedMediaPayload(id: payloadId, data: data),
            fileName: fileName,
            mediaType: mediaType,
            sizeBytes: sizeBytes
        )
    }

    var data: Data {
        payload.data
    }

    func detailText(fallbackMediaType: String) -> String {
        "\(mediaType.nilIfBlank ?? fallbackMediaType) - \(sizeLabel)"
    }

    private static func sizeLabel(for sizeBytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: sizeBytes), countStyle: .file)
    }
}

nonisolated enum MessageMediaGridPresentation {
    static let maxVisibleItems = 4

    static func visibleCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), maxVisibleItems)
    }

    static func hiddenCount(totalCount: Int) -> Int {
        max(0, totalCount - maxVisibleItems)
    }

    static func columnCount(totalCount: Int) -> Int {
        totalCount <= 1 ? 1 : 2
    }

    static func rowCount(totalCount: Int) -> Int {
        totalCount <= 2 ? 1 : 2
    }

    static func tileSide(totalCount: Int, maxWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        let columns = columnCount(totalCount: totalCount)
        let totalSpacing = CGFloat(columns - 1) * spacing
        return max(1, (maxWidth - totalSpacing) / CGFloat(columns))
    }

    static func gridHeight(totalCount: Int, maxWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        let rows = rowCount(totalCount: totalCount)
        let side = tileSide(totalCount: totalCount, maxWidth: maxWidth, spacing: spacing)
        return CGFloat(rows) * side + CGFloat(rows - 1) * spacing
    }
}

nonisolated enum MediaDurationLabel {
    static func string(for durationSeconds: Double) -> String {
        // The duration can be peer-derived (see MediaWaveformAnalyzer), so it may be
        // NaN, ±Infinity, negative, or larger than Int.max. The trapping Int(_:)
        // initializer would crash on non-finite or out-of-range values, so clamp the
        // floored duration into the representable range before converting.
        let total: Int
        if durationSeconds.isFinite {
            let flooredSeconds = durationSeconds.rounded(.down)
            if flooredSeconds <= 0 {
                total = 0
            } else if flooredSeconds >= Double(Int.max) {
                total = Int.max
            } else {
                total = Int(flooredSeconds)
            }
        } else {
            total = 0
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum MediaDownloadState: Equatable {
    case idle
    case loading
    case loaded(MessageMediaDownload)
    case failed(String)
}

nonisolated struct PendingMediaAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let mediaType: String
    let data: Data
    let dim: String?
    let thumbhash: String?
    let durationSeconds: Double?
    let waveformSamples: [CGFloat]

    init(
        id: UUID = UUID(),
        fileName: String,
        mediaType: String,
        data: Data,
        dim: String?,
        thumbhash: String? = nil,
        durationSeconds: Double? = nil,
        waveformSamples: [CGFloat] = []
    ) {
        self.id = id
        self.fileName = fileName
        self.mediaType = mediaType
        self.data = data
        self.dim = dim
        self.thumbhash = thumbhash
        self.durationSeconds = durationSeconds
        self.waveformSamples = waveformSamples
    }

    var kind: MessageMediaKind {
        OutgoingMediaAttachmentPolicy.kind(mediaType: mediaType, fileName: fileName)
    }

    var uploadRequest: MediaUploadAttachmentRequestFfi {
        MediaUploadAttachmentRequestFfi(
            fileName: fileName,
            mediaType: mediaType,
            plaintext: data,
            dim: dim,
            thumbhash: thumbhash
        )
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    var durationLabel: String? {
        guard let durationSeconds else { return nil }
        return MediaDurationLabel.string(for: durationSeconds)
    }
}

nonisolated struct VoiceRecordingResult: Sendable {
    let url: URL
    let fileName: String
    let durationSeconds: Double
    let waveformSamples: [CGFloat]
}

nonisolated enum OutgoingMediaAttachmentPolicy {
    static let supportedAudioMediaTypes: Set<String> = [
        "audio/aac",
        "audio/mp4",
        "audio/mpeg",
        "audio/wav",
        "audio/x-m4a",
        "audio/x-wav",
    ]

    static let supportedVideoMediaTypes: Set<String> = [
        "video/mp4",
        "video/quicktime",
    ]

    static let supportedDocumentMediaTypes: Set<String> = [
        "application/json",
        "application/msword",
        "application/pdf",
        "application/rtf",
        "application/vnd.ms-excel",
        "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "text/csv",
        "text/json",
        "text/plain",
        "text/rtf",
    ]

    static let supportedDocumentExtensions: Set<String> = [
        "csv",
        "doc",
        "docx",
        "json",
        "pdf",
        "ppt",
        "pptx",
        "rtf",
        "txt",
        "xls",
        "xlsx",
    ]

    static let fileImporterAllowedTypes: [UTType] = {
        var types: [UTType] = [.image, .movie, .audio, .pdf, .plainText, .rtf, .commaSeparatedText, .json]
        for ext in supportedDocumentExtensions.sorted() {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }()

    static func canonicalMediaType(_ mediaType: String) -> String {
        let base =
            mediaType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? mediaType
        let canonical = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return canonical == "image/jpg" ? "image/jpeg" : canonical
    }

    static func isDecodableImageMediaType(_ mediaType: String) -> Bool {
        let canonical = canonicalMediaType(mediaType)
        guard canonical.hasPrefix("image/") else { return false }
        return canonical != "image/svg+xml"
    }

    static func isSupported(mediaType: String, fileName: String? = nil) -> Bool {
        let canonical = canonicalMediaType(mediaType)
        if isDecodableImageMediaType(canonical) { return true }
        if supportedVideoMediaTypes.contains(canonical) { return true }
        if supportedAudioMediaTypes.contains(canonical) { return true }
        if supportedDocumentMediaTypes.contains(canonical) { return true }
        if let fileName,
            let fileExtension = fileName.split(separator: ".").last.map(String.init)
        {
            return supportedDocumentExtensions.contains(fileExtension.lowercased())
        }
        return false
    }

    static func mediaType(typeIdentifier: String?, fileName: String?, fallbackKind: MessageMediaKind?) -> String? {
        if let typeIdentifier,
            let type = UTType(typeIdentifier),
            let mediaType = type.preferredMIMEType
        {
            return canonicalMediaType(mediaType)
        }
        if let fileName,
            let fileExtension = fileName.split(separator: ".").last.map(String.init),
            let mediaType = mediaType(forFileExtension: fileExtension)
        {
            return canonicalMediaType(mediaType)
        }
        switch fallbackKind {
        case .video:
            return "video/mp4"
        case .audio:
            return "audio/mp4"
        case .image:
            return "image/jpeg"
        case .file, .none:
            return nil
        }
    }

    static func mediaType(forFileExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "m4a":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "mov":
            return "video/quicktime"
        case "mp4", "m4v":
            return "video/mp4"
        case "txt":
            return "text/plain"
        case "csv":
            return "text/csv"
        case "json":
            return "application/json"
        case "rtf":
            return "application/rtf"
        case "pdf":
            return "application/pdf"
        case "doc":
            return "application/msword"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls":
            return "application/vnd.ms-excel"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt":
            return "application/vnd.ms-powerpoint"
        case "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default:
            return UTType(filenameExtension: fileExtension.lowercased())?.preferredMIMEType
        }
    }

    static func fileExtension(for mediaType: String, fileName: String? = nil) -> String {
        if let fileName,
            let ext = fileName.split(separator: ".").last.map(String.init),
            !ext.isEmpty
        {
            return ext.lowercased()
        }
        switch canonicalMediaType(mediaType) {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/heic":
            return "heic"
        case "image/webp":
            return "webp"
        case "video/mp4":
            return "mp4"
        case "video/quicktime":
            return "mov"
        case "audio/aac", "audio/mp4", "audio/x-m4a":
            return "m4a"
        case "audio/mpeg":
            return "mp3"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "application/pdf":
            return "pdf"
        case "application/json", "text/json":
            return "json"
        case "application/rtf", "text/rtf":
            return "rtf"
        case "text/csv":
            return "csv"
        case "text/plain":
            return "txt"
        case "application/msword":
            return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return "docx"
        case "application/vnd.ms-excel":
            return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
            return "xlsx"
        case "application/vnd.ms-powerpoint":
            return "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
            return "pptx"
        default:
            return "bin"
        }
    }

    static func kind(mediaType: String, fileName: String? = nil) -> MessageMediaKind {
        let canonical = canonicalMediaType(mediaType)
        if isDecodableImageMediaType(canonical) { return .image }
        if canonical.hasPrefix("video/") { return .video }
        if canonical.hasPrefix("audio/") { return .audio }
        return .file
    }
}

nonisolated enum OutgoingMediaDraftProcessor {
    static let maxAttachmentCount = 10
    static let maxLongEdge: CGFloat = 2048
    static let maxImageAttachmentBytes = 10 * 1024 * 1024
    static let maxAttachmentBytes = 50 * 1024 * 1024

    enum Failure: LocalizedError {
        case unsupportedImage
        case unsupportedAttachment
        case encodingFailed
        case attachmentTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedImage:
                return "That image could not be opened."
            case .unsupportedAttachment:
                return "That file type is not supported."
            case .encodingFailed:
                return "That attachment could not be prepared."
            case .attachmentTooLarge:
                return "That attachment is too large to send."
            }
        }
    }

    private struct SendableAttachment: @unchecked Sendable {
        let attachment: PendingMediaAttachment
    }

    static func preparedAttachment(fromFileURL url: URL) async throws -> PendingMediaAttachment {
        let prepared = try await Task.detached(priority: .userInitiated) { () async throws -> SendableAttachment in
            let resourceValues = try url.resourceValues(forKeys: [
                .contentTypeKey, .nameKey, .fileSizeKey, .isDirectoryKey,
            ])
            guard resourceValues.isDirectory != true else {
                throw Failure.unsupportedAttachment
            }
            if let fileSize = resourceValues.fileSize, fileSize > maxAttachmentBytes {
                throw Failure.attachmentTooLarge(fileSize)
            }
            let data = try readAttachmentData(from: url)
            return try await SendableAttachment(
                attachment: preparedAttachmentValue(
                    from: data,
                    fileName: resourceValues.name ?? url.lastPathComponent,
                    typeIdentifier: resourceValues.contentType?.identifier
                ))
        }.value
        return prepared.attachment
    }

    private static func readAttachmentData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Read at most one byte past the cap so URLs without fileSize cannot force
        // unbounded buffering before the raw-size guard runs.
        let data = try handle.read(upToCount: maxAttachmentBytes + 1) ?? Data()
        try enforceRawAttachmentSize(data)
        return data
    }

    static func preparedVoiceAttachment(from recording: VoiceRecordingResult) async throws -> PendingMediaAttachment {
        let prepared = try await Task.detached(priority: .userInitiated) { () throws -> SendableAttachment in
            defer { try? FileManager.default.removeItem(at: recording.url) }
            let data = try Data(contentsOf: recording.url)
            guard data.count <= maxAttachmentBytes else {
                throw Failure.attachmentTooLarge(data.count)
            }
            return SendableAttachment(
                attachment: PendingMediaAttachment(
                    fileName: sanitizedFileName(
                        recording.fileName,
                        fallbackStem: "voice-\(Int(Date().timeIntervalSince1970))",
                        fallbackExtension: "m4a"
                    ),
                    mediaType: "audio/mp4",
                    data: data,
                    dim: nil,
                    durationSeconds: recording.durationSeconds,
                    waveformSamples: MediaWaveformAnalyzer.normalized(recording.waveformSamples)
                ))
        }.value
        return prepared.attachment
    }

    private static func preparedAttachmentValue(
        from data: Data,
        fileName: String?,
        typeIdentifier: String?
    ) async throws -> PendingMediaAttachment {
        // Keep the raw-size invariant in the common funnel too, so no caller can
        // branch into image decoding with unbounded data.
        try enforceRawAttachmentSize(data)
        let kind = kind(for: typeIdentifier, fileName: fileName)
        if kind == .image {
            return try imageAttachment(from: data, fileName: fileName)
        }
        guard
            let mediaType = OutgoingMediaAttachmentPolicy.mediaType(
                typeIdentifier: typeIdentifier,
                fileName: fileName,
                fallbackKind: kind
            ),
            OutgoingMediaAttachmentPolicy.isSupported(mediaType: mediaType, fileName: fileName)
        else {
            throw Failure.unsupportedAttachment
        }
        let videoDim = kind == .video ? await MediaVideoMetadata.dim(from: data, mediaType: mediaType) : nil
        return try genericAttachment(
            from: data,
            fileName: fileName,
            mediaType: mediaType,
            kind: kind,
            videoDim: videoDim
        )
    }

    private static func enforceRawAttachmentSize(_ data: Data) throws {
        guard data.count <= maxAttachmentBytes else {
            throw Failure.attachmentTooLarge(data.count)
        }
    }

    private static func kind(for typeIdentifier: String?, fileName: String?) -> MessageMediaKind? {
        if let typeIdentifier, let type = UTType(typeIdentifier) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .pdf) || type.conforms(to: .text) {
                return .file
            }
        }
        if let fileName,
            let fileExtension = fileName.split(separator: ".").last.map(String.init),
            let mediaType = OutgoingMediaAttachmentPolicy.mediaType(forFileExtension: fileExtension)
        {
            return OutgoingMediaAttachmentPolicy.kind(mediaType: mediaType, fileName: fileName)
        }
        return nil
    }

    private static func genericAttachment(
        from data: Data,
        fileName: String?,
        mediaType: String,
        kind: MessageMediaKind?,
        videoDim: String?
    ) throws -> PendingMediaAttachment {
        let sanitizedName = sanitizedFileName(
            fileName,
            fallbackStem: kind == .audio
                ? "audio-\(Int(Date().timeIntervalSince1970))" : "attachment-\(Int(Date().timeIntervalSince1970))",
            fallbackExtension: OutgoingMediaAttachmentPolicy.fileExtension(for: mediaType, fileName: fileName)
        )
        let audioMetadata = kind == .audio ? MediaWaveformAnalyzer.metadata(from: data, mediaType: mediaType) : nil
        return PendingMediaAttachment(
            fileName: sanitizedName,
            mediaType: mediaType,
            data: data,
            dim: videoDim,
            durationSeconds: audioMetadata?.durationSeconds,
            waveformSamples: audioMetadata?.samples ?? []
        )
    }

    private static func imageAttachment(from data: Data, fileName: String?) throws -> PendingMediaAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw Failure.unsupportedImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxLongEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unsupportedImage
        }
        let encoded = try encodeJPEG(image)
        guard encoded.count <= maxImageAttachmentBytes else {
            throw Failure.attachmentTooLarge(encoded.count)
        }
        return PendingMediaAttachment(
            fileName: sanitizedImageFileName(fileName),
            mediaType: "image/jpeg",
            data: encoded,
            dim: "\(image.width)x\(image.height)"
        )
    }

    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        for quality in [0.86, 0.74, 0.62, 0.52] as [CGFloat] {
            if let data = jpegData(from: image, quality: quality), data.count <= maxImageAttachmentBytes {
                return data
            }
        }
        throw Failure.encodingFailed
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func sanitizedImageFileName(_ fileName: String?) -> String {
        let name = sanitizedFileName(
            fileName,
            fallbackStem: "photo-\(Int(Date().timeIntervalSince1970))",
            fallbackExtension: "jpg"
        )
        let lower = name.lowercased()
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") {
            return name
        }
        return "\(name).jpg"
    }

    private static func sanitizedFileName(
        _ fileName: String?,
        fallbackStem: String,
        fallbackExtension: String
    ) -> String {
        let base = fileName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .last
            .map(String.init)
        let stem = base?
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        guard let stem, !stem.isEmpty else {
            return "\(fallbackStem).\(fallbackExtension)"
        }
        let capped = String(stem.prefix(120))
        if capped.contains(".") {
            return capped
        }
        return "\(capped).\(fallbackExtension)"
    }
}

nonisolated enum MediaWaveformAnalyzer {
    struct Metadata: Equatable, Sendable {
        let durationSeconds: Double?
        let samples: [CGFloat]
    }

    static let sampleCount = 36
    static let fallbackSamples: [CGFloat] = fallback()
    static let chunkFrameCapacityCeiling: AVAudioFrameCount = 65_536
    static let maxChunkBytes: Int = 4 * 1024 * 1024
    static let maxChannelCount: AVAudioChannelCount = 32
    static let maxAnalyzedFrames: AVAudioFramePosition = 48_000 * 60 * 30

    static func normalized(_ values: [CGFloat], count: Int = sampleCount) -> [CGFloat] {
        let bounded = values.map { min(1, max(0.05, $0)) }
        guard !bounded.isEmpty else { return fallback(count: count) }
        if bounded.count == count { return bounded }
        let bucketSize = Double(bounded.count) / Double(count)
        return (0..<count).map { index in
            let start = Int((Double(index) * bucketSize).rounded(.down))
            let end = min(bounded.count, Int((Double(index + 1) * bucketSize).rounded(.up)))
            let slice = bounded[max(0, start)..<max(start + 1, end)]
            return max(0.08, slice.reduce(0, +) / CGFloat(slice.count))
        }
    }

    static func fallback(count: Int = sampleCount) -> [CGFloat] {
        (0..<count).map { index in
            let phase = CGFloat(index % 9) / 8
            return 0.24 + sin(phase * .pi) * 0.48
        }
    }

    static func chunkFrameCapacity(
        channelCount: AVAudioChannelCount,
        bytesPerSample: Int
    ) -> AVAudioFrameCount {
        let channels = max(1, Int(channelCount))
        let sampleBytes = max(1, bytesPerSample)
        let perFrameBytes = channels * sampleBytes
        let framesInBudget = max(1, maxChunkBytes / perFrameBytes)
        return AVAudioFrameCount(min(framesInBudget, Int(chunkFrameCapacityCeiling)))
    }

    static func analyzedFrameCount(totalFrames: AVAudioFramePosition) -> AVAudioFramePosition {
        guard totalFrames > 0 else { return 0 }
        return min(totalFrames, maxAnalyzedFrames)
    }

    static func nextChunkFrameCount(
        analyzedFrames: AVAudioFramePosition,
        framesProcessed: AVAudioFramePosition,
        chunkCapacity: AVAudioFrameCount
    ) -> AVAudioFrameCount {
        let remaining = analyzedFrames - framesProcessed
        guard remaining > 0 else { return 0 }
        return AVAudioFrameCount(min(AVAudioFramePosition(chunkCapacity), remaining))
    }

    static func bucketIndex(
        forFrame frame: AVAudioFramePosition,
        analyzedFrames: AVAudioFramePosition,
        bucketCount: Int = sampleCount
    ) -> Int {
        guard analyzedFrames > 0, bucketCount > 0 else { return 0 }
        let index = Int(frame * AVAudioFramePosition(bucketCount) / analyzedFrames)
        return min(bucketCount - 1, max(0, index))
    }

    static func metadata(from data: Data, mediaType: String) -> Metadata {
        TemporaryOutgoingMediaFile.withURL(
            data: data,
            fileExtension: OutgoingMediaAttachmentPolicy.fileExtension(for: mediaType)
        ) { url in
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let sampleRate = format.sampleRate
                let totalFrames = file.length
                let duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : nil

                let analyzedFrames = analyzedFrameCount(totalFrames: totalFrames)
                guard analyzedFrames > 0 else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                let channelCount = format.channelCount
                guard channelCount > 0, channelCount <= maxChannelCount else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                let bitsPerChannel = Int(format.streamDescription.pointee.mBitsPerChannel)
                let bytesPerSample =
                    bitsPerChannel > 0
                    ? (bitsPerChannel + 7) / 8
                    : MemoryLayout<Float>.size
                let chunkCapacity = chunkFrameCapacity(
                    channelCount: channelCount,
                    bytesPerSample: bytesPerSample
                )

                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                var peaks = [Float](repeating: 0, count: sampleCount)
                var counts = [Int](repeating: 0, count: sampleCount)
                var framesProcessed: AVAudioFramePosition = 0

                while true {
                    let toRead = nextChunkFrameCount(
                        analyzedFrames: analyzedFrames,
                        framesProcessed: framesProcessed,
                        chunkCapacity: chunkCapacity
                    )
                    guard toRead > 0 else { break }
                    buffer.frameLength = 0
                    try file.read(into: buffer, frameCount: toRead)
                    let read = Int(buffer.frameLength)
                    guard read > 0, let channel = buffer.floatChannelData?[0] else { break }
                    for offset in 0..<read {
                        let bucket = bucketIndex(
                            forFrame: framesProcessed + AVAudioFramePosition(offset),
                            analyzedFrames: analyzedFrames
                        )
                        let value = abs(channel[offset])
                        if value > peaks[bucket] { peaks[bucket] = value }
                        counts[bucket] += 1
                    }
                    framesProcessed += AVAudioFramePosition(read)
                }

                guard framesProcessed > 0 else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                let samples = (0..<sampleCount).map { index -> CGFloat in
                    guard counts[index] > 0 else { return 0.08 }
                    return CGFloat(min(1, max(0.05, sqrt(peaks[index]))))
                }
                return Metadata(durationSeconds: duration, samples: normalized(samples))
            } catch {
                return Metadata(durationSeconds: nil, samples: fallback())
            }
        }
    }
}

nonisolated final class MessageAudioMetadataCache: @unchecked Sendable {
    typealias Analyzer = @Sendable (DownloadedMediaPayload, String) -> MediaWaveformAnalyzer.Metadata

    static let shared = MessageAudioMetadataCache()

    private let lock = NSLock()
    private let entryLimit: Int
    private let analyzer: Analyzer
    private var cached: [String: MediaWaveformAnalyzer.Metadata] = [:]
    private var accessOrder: [String] = []
    private var inFlight: [String: Task<MediaWaveformAnalyzer.Metadata, Never>] = [:]
    private var generation = 0

    init(
        entryLimit: Int = 128,
        analyzer: @escaping Analyzer = { payload, mediaType in
            MediaWaveformAnalyzer.metadata(from: payload.data, mediaType: mediaType)
        }
    ) {
        self.entryLimit = max(1, entryLimit)
        self.analyzer = analyzer
    }

    func metadata(for download: MessageMediaDownload) async -> MediaWaveformAnalyzer.Metadata {
        await metadata(for: download.payload, mediaType: download.mediaType)
    }

    func metadata(
        for payload: DownloadedMediaPayload,
        mediaType: String
    ) async -> MediaWaveformAnalyzer.Metadata {
        let key = payload.id
        let task: Task<MediaWaveformAnalyzer.Metadata, Never>
        let taskGeneration: Int

        // Scoped `withLock` rather than manual lock/unlock: `lock()`/`unlock()` are unavailable
        // from async contexts (a lock must not be held across a suspension). The critical
        // sections here are fully synchronous — the `await`s happen *outside* the lock — so the
        // behavior is unchanged; resolve what to do under the lock, then suspend without it.
        enum Lookup {
            case cached(MediaWaveformAnalyzer.Metadata)
            case awaitInFlight(Task<MediaWaveformAnalyzer.Metadata, Never>)
            case started(Task<MediaWaveformAnalyzer.Metadata, Never>, generation: Int)
        }

        let lookup: Lookup = lock.withLock {
            if let value = cached[key] {
                markRecentlyUsed(key)
                return .cached(value)
            }
            if let existing = inFlight[key] {
                return .awaitInFlight(existing)
            }
            let started = Task.detached(priority: .utility) { [analyzer] in
                analyzer(payload, mediaType)
            }
            inFlight[key] = started
            return .started(started, generation: generation)
        }

        switch lookup {
        case .cached(let value):
            return value
        case .awaitInFlight(let existing):
            return await existing.value
        case .started(let started, let gen):
            task = started
            taskGeneration = gen
        }

        let value = await task.value

        lock.withLock {
            if generation == taskGeneration {
                inFlight[key] = nil
                cached[key] = value
                markRecentlyUsed(key)
                trimIfNeeded()
            }
        }

        return value
    }

    func clear() {
        let tasks: [Task<MediaWaveformAnalyzer.Metadata, Never>]
        lock.lock()
        generation += 1
        cached.removeAll()
        accessOrder.removeAll()
        tasks = Array(inFlight.values)
        inFlight.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    #if DEBUG
        var cachedEntryCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return cached.count
        }
    #endif

    private func markRecentlyUsed(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimIfNeeded() {
        while cached.count > entryLimit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            cached[oldest] = nil
        }
    }
}

nonisolated private enum MediaVideoMetadata {
    static func dim(from data: Data, mediaType: String) async -> String? {
        await TemporaryOutgoingMediaFile.withURL(
            data: data,
            fileExtension: OutgoingMediaAttachmentPolicy.fileExtension(for: mediaType)
        ) { url in
            let asset = AVURLAsset(url: url)
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    return nil
                }
                async let naturalSize = track.load(.naturalSize)
                async let preferredTransform = track.load(.preferredTransform)
                let (size, transform) = try await (naturalSize, preferredTransform)
                let transformed = size.applying(transform)
                let width = max(1, Int(abs(transformed.width).rounded()))
                let height = max(1, Int(abs(transformed.height).rounded()))
                return "\(width)x\(height)"
            } catch {
                return nil
            }
        }
    }
}

nonisolated private enum TemporaryOutgoingMediaFile {
    static func withURL<T>(data: Data, fileExtension: String, _ work: (URL) -> T) -> T {
        let url = makeTempURL(data: data, fileExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        return work(url)
    }

    static func withURL<T>(data: Data, fileExtension: String, _ work: (URL) async -> T) async -> T {
        let url = makeTempURL(data: data, fileExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        return await work(url)
    }

    private static func makeTempURL(data: Data, fileExtension: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteNoiseMediaWork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url =
            directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try? data.write(to: url, options: [.atomic])
        return url
    }
}

nonisolated enum MessagePresentation: Hashable {
    case chat
    case agentStreamStart
    case agentActivity
    case agentOperation
    case groupSystem
    case unsupported

    var isChatBubble: Bool {
        self == .chat
    }

    var systemImage: String {
        switch self {
        case .chat:
            return "text.bubble"
        case .agentStreamStart:
            return "sparkles"
        case .agentActivity:
            return "waveform.path"
        case .agentOperation:
            return "hammer"
        case .groupSystem:
            return "person.2"
        case .unsupported:
            return "questionmark.bubble"
        }
    }

    var debugLabel: String {
        switch self {
        case .chat:
            return "chat"
        case .agentStreamStart:
            return "agent-stream-start"
        case .agentActivity:
            return "agent-activity"
        case .agentOperation:
            return "agent-operation"
        case .groupSystem:
            return "group-system"
        case .unsupported:
            return "unsupported"
        }
    }
}

struct MessageItem: Identifiable, Hashable {
    let id: String
    let groupIdHex: String
    let senderAccountIdHex: String
    let senderName: String
    let senderPictureURL: String?
    let body: String
    /// Pre-rendered Markdown display model for the message body. The Marmot core supplies
    /// parsed tokens; `MessageItem` converts them once so SwiftUI body/layout passes do not
    /// rebuild attributed strings or enumerated block arrays while scrolling.
    let contentMarkdown: MarkdownDisplayDocument?
    let trimmedBody: String
    let sentAt: Date
    let timelineAt: UInt64
    let timelineKind: UInt64
    let isDeleted: Bool
    let invalidationStatus: String?
    let isOutgoing: Bool
    let reactions: [MessageReaction]
    let replyContext: MessageReplyContext?
    let mediaAttachments: [MessageMediaAttachment]
    let visualMediaAttachments: [MessageMediaAttachment]
    let nonvisualMediaAttachments: [MessageMediaAttachment]
    let hasBubbleContent: Bool
    let presentation: MessagePresentation
    let timeLabel: String
    let statusLabel: String?
    let metadataLabel: String

    /// Whether the bubble should render the parsed Markdown AST instead of plain text.
    var rendersMarkdown: Bool { contentMarkdown != nil }

    // `nonisolated` so the timeline record → view-model mapping (`MessageItem.timeline`)
    // can build items in the off-main window/projection closure (whitenoise-mac#285)
    // without inheriting the module's default main-actor isolation.
    nonisolated init(
        id: String,
        groupIdHex: String = "",
        senderAccountIdHex: String? = nil,
        senderName: String,
        senderPictureURL: String? = nil,
        body: String,
        contentMarkdown: MarkdownDocumentFfi? = nil,
        sentAt: Date,
        timelineAt: UInt64? = nil,
        timelineKind: UInt64 = 9,
        isDeleted: Bool = false,
        invalidationStatus: String? = nil,
        isOutgoing: Bool,
        reactions: [MessageReaction] = [],
        replyContext: MessageReplyContext? = nil,
        mediaAttachments: [MessageMediaAttachment] = [],
        presentation: MessagePresentation = .chat
    ) {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let partitionedAttachments = Self.partitionMediaAttachments(mediaAttachments)

        self.id = id
        self.groupIdHex = groupIdHex
        self.senderAccountIdHex = senderAccountIdHex ?? senderName
        self.senderName = senderName
        self.senderPictureURL = senderPictureURL
        self.body = body
        self.contentMarkdown = contentMarkdown.map(MarkdownDisplayDocument.init(document:))
        self.trimmedBody = trimmedBody
        self.sentAt = sentAt
        // `timelineAt` is normally supplied by the core mapping; the fallback derives it from
        // `sentAt`. A pre-epoch, non-finite, or oversized `sentAt` would trap the `UInt64(_:)`
        // conversion, so clamp the floored timestamp into the representable range first.
        let fallbackTimeline = sentAt.timeIntervalSince1970
        let resolvedTimelineAt: UInt64
        if let timelineAt = timelineAt {
            resolvedTimelineAt = timelineAt
        } else if fallbackTimeline.isFinite {
            let flooredTimeline = fallbackTimeline.rounded(.down)
            if flooredTimeline <= 0 {
                resolvedTimelineAt = 0
            } else if flooredTimeline >= Double(UInt64.max) {
                resolvedTimelineAt = UInt64.max
            } else {
                resolvedTimelineAt = UInt64(flooredTimeline)
            }
        } else {
            resolvedTimelineAt = 0
        }
        self.timelineAt = resolvedTimelineAt
        self.timelineKind = timelineKind
        self.isDeleted = isDeleted
        self.invalidationStatus = invalidationStatus
        self.isOutgoing = isOutgoing
        self.reactions = reactions
        self.replyContext = replyContext
        self.mediaAttachments = mediaAttachments
        self.visualMediaAttachments = partitionedAttachments.visual
        self.nonvisualMediaAttachments = partitionedAttachments.nonvisual
        self.hasBubbleContent = replyContext != nil || !trimmedBody.isEmpty
        self.presentation = presentation
        let timeLabel = DisplayText.messageTimestamp(for: sentAt)
        self.timeLabel = timeLabel
        let statusLabel: String?
        if presentation.isChatBubble {
            if invalidationStatus != nil {
                statusLabel = L10n.string("Did not reach group")
            } else {
                statusLabel = isOutgoing ? L10n.string("Sent") : nil
            }
        } else {
            statusLabel = nil
        }
        self.statusLabel = statusLabel
        self.metadataLabel = statusLabel.map { "\(timeLabel)  \($0)" } ?? timeLabel
    }

    nonisolated private static func partitionMediaAttachments(_ attachments: [MessageMediaAttachment]) -> (
        visual: [MessageMediaAttachment], nonvisual: [MessageMediaAttachment]
    ) {
        var visual: [MessageMediaAttachment] = []
        var nonvisual: [MessageMediaAttachment] = []

        for attachment in attachments {
            switch attachment.kind {
            case .image, .video:
                visual.append(attachment)
            case .audio, .file:
                nonvisual.append(attachment)
            }
        }

        return (visual, nonvisual)
    }

    var debugTitle: String {
        "kind \(timelineKind) - \(presentation.debugLabel)"
    }

    var debugDetail: String {
        "\(DisplayText.short(id, head: 10, tail: 8)) - \(timelineAt)"
    }

    private var hasCopyableBody: Bool {
        !trimmedBody.isEmpty
    }

    var replyPreviewText: String {
        if !trimmedBody.isEmpty {
            return trimmedBody
        }
        return MessageMediaAttachment.previewText(for: mediaAttachments)
    }

    private var isActionableContent: Bool {
        !isDeleted && invalidationStatus == nil
    }

    private var isActionableChatBubble: Bool {
        presentation.isChatBubble && isActionableContent
    }

    var supportsChatActions: Bool {
        isActionableChatBubble
    }

    var canCopyText: Bool {
        isActionableContent && hasCopyableBody
    }

    var canReact: Bool {
        isActionableChatBubble
    }

    var canReply: Bool {
        isActionableChatBubble
    }

    var canDelete: Bool {
        isActionableChatBubble && isOutgoing
    }
}

extension MessageItem {
    // Hand-written `Equatable`/`Hashable` so equality and hashing stay O(1) instead of
    // recursively walking `contentMarkdown`'s pre-rendered Markdown tree.
    //
    // `contentMarkdown` is a deterministic display projection of the message content
    // (the core's `contentTokens`), fully determined by the content-bearing fields
    // compared below — chiefly `body`, `isDeleted`, and `presentation`. Two items that
    // agree on those always carry the same AST, so excluding it from equality is sound
    // while avoiding an O(AST) traversal on every comparison. That traversal otherwise
    // ran for each row whenever SwiftUI diffed the transcript (and on any Set/Dictionary
    // use), adding up across a live-update burst. The remaining fields are the
    // independent inputs; rendered labels are compared too because they are cheap and
    // directly displayed by the row. The rest of the stored properties (`trimmedBody`, the
    // media partitions, `hasBubbleContent`) are pure functions of these, so comparing them
    // too would be redundant.
    static func == (lhs: MessageItem, rhs: MessageItem) -> Bool {
        lhs.id == rhs.id
            && lhs.groupIdHex == rhs.groupIdHex
            && lhs.senderAccountIdHex == rhs.senderAccountIdHex
            && lhs.senderName == rhs.senderName
            && lhs.senderPictureURL == rhs.senderPictureURL
            && lhs.body == rhs.body
            && lhs.sentAt == rhs.sentAt
            && lhs.timelineAt == rhs.timelineAt
            && lhs.timelineKind == rhs.timelineKind
            && lhs.isDeleted == rhs.isDeleted
            && lhs.invalidationStatus == rhs.invalidationStatus
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.reactions == rhs.reactions
            && lhs.replyContext == rhs.replyContext
            && lhs.mediaAttachments == rhs.mediaAttachments
            && lhs.presentation == rhs.presentation
            && lhs.timeLabel == rhs.timeLabel
            && lhs.statusLabel == rhs.statusLabel
            && lhs.metadataLabel == rhs.metadataLabel
    }

    // Hashes a cheap, well-distributed subset of the equality fields. Hashing only a
    // subset is valid — equal values still hash equally — and keeps the message id (which
    // is unique per message) doing the bulk of the distribution work.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(timelineAt)
        hasher.combine(body)
    }
}

enum WorkspaceSelection: Equatable {
    case chat(String)
    case settings(SettingsPage)
}

enum SettingsPage: Equatable {
    case overview
    case accounts
    case profile
    case identityKeys
    case relays
    case keyPackages
    case appearance
    case privacySecurity
    case notifications
    case developerMode

    static let sidebarPages: [SettingsPage] = [
        .profile,
        .accounts,
        .identityKeys,
        .relays,
        .keyPackages,
        .appearance,
        .privacySecurity,
        .notifications,
        .developerMode,
    ]

    var title: String {
        switch self {
        case .overview:
            L10n.string("Settings")
        case .accounts:
            L10n.string("Accounts")
        case .profile:
            L10n.string("Profile")
        case .identityKeys:
            L10n.string("Identity & Keys")
        case .relays:
            L10n.string("Relays")
        case .keyPackages:
            L10n.string("Key Packages")
        case .appearance:
            L10n.string("Appearance")
        case .privacySecurity:
            L10n.string("Privacy & Security")
        case .notifications:
            L10n.string("Notifications")
        case .developerMode:
            L10n.string("Developer mode")
        }
    }

    var sidebarSubtitle: String {
        switch self {
        case .overview:
            L10n.string("Settings home")
        case .accounts:
            L10n.string("Switch identities")
        case .profile:
            L10n.string("Public display info")
        case .identityKeys:
            L10n.string("Public and private keys")
        case .relays:
            L10n.string("Relay lists")
        case .keyPackages:
            L10n.string("Invite packages")
        case .appearance:
            L10n.string("Theme")
        case .privacySecurity:
            L10n.string("Telemetry and audit logs")
        case .notifications:
            L10n.string("Local alerts")
        case .developerMode:
            L10n.string("Storage and diagnostics")
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "gearshape"
        case .accounts:
            "person.2"
        case .profile:
            "person.crop.circle"
        case .identityKeys:
            "key.viewfinder"
        case .relays:
            "antenna.radiowaves.left.and.right"
        case .keyPackages:
            "key"
        case .appearance:
            "circle.lefthalf.filled"
        case .privacySecurity:
            "lock.shield"
        case .notifications:
            "bell.badge"
        case .developerMode:
            "stethoscope"
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:
            L10n.string("System")
        case .light:
            L10n.string("Light")
        case .dark:
            L10n.string("Dark")
        }
    }
}

enum LocalNotificationAuthorizationStatus: String, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var label: String {
        switch self {
        case .notDetermined:
            L10n.string("Not requested")
        case .denied:
            L10n.string("Denied")
        case .authorized:
            L10n.string("Allowed")
        case .provisional:
            L10n.string("Allowed quietly")
        case .ephemeral:
            L10n.string("Allowed for now")
        }
    }

    var canPostNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        }
    }
}

struct NotificationSettingsSnapshot: Equatable {
    var localNotificationsEnabled: Bool

    static let defaults = NotificationSettingsSnapshot(
        localNotificationsEnabled: false
    )
}

/// Controls how much of an incoming message is revealed in a macOS local
/// notification. macOS renders notification content as banners, persists it in
/// Notification Center, and shows it on the lock screen, so for an E2EE
/// messenger the notification body is content that leaves the app's control.
/// This lets a user trade convenience for privacy, mirroring the conservative,
/// individually-toggleable defaults used elsewhere in Privacy & Security.
enum NotificationPreviewMode: String, CaseIterable, Identifiable {
    /// Show the sender/group name and the decrypted message text (legacy behavior).
    case full
    /// Show who the message is from (and the group name), but never the message text.
    case senderOnly
    /// Reveal nothing: generic "New message" with no sender, group, or content.
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full:
            L10n.string("Show message preview")
        case .senderOnly:
            L10n.string("Sender only")
        case .hidden:
            L10n.string("Hide all")
        }
    }

    var detail: String {
        switch self {
        case .full:
            L10n.string("Notifications show who sent the message and its contents.")
        case .senderOnly:
            L10n.string("Notifications show who sent the message but not its contents.")
        case .hidden:
            L10n.string("Notifications only say a new message arrived.")
        }
    }
}

struct PrivacySecuritySettingsSnapshot: Equatable {
    var relayTelemetryEnabled: Bool
    var relayTelemetryIntervalSeconds: UInt64
    var auditLoggingEnabled: Bool
    /// When true the audit log records decrypted content and full identifiers
    /// (`AuditDataModeFfi.fullData`); otherwise identifiers are obfuscated/hashed.
    var auditFullDataLogging: Bool
    var telemetryCredentialsAvailable: Bool
    var auditLogCredentialsAvailable: Bool

    static let defaults = PrivacySecuritySettingsSnapshot(
        relayTelemetryEnabled: false,
        relayTelemetryIntervalSeconds: 60,
        auditLoggingEnabled: false,
        auditFullDataLogging: false,
        telemetryCredentialsAvailable: false,
        auditLogCredentialsAvailable: false
    )
}

struct DiagnosticsInfoItem: Identifiable, Equatable {
    let title: String
    let value: String

    var id: String { title }
}

enum RelaySettingsSection: String, CaseIterable, Identifiable {
    case nip65 = "NIP-65"
    case inbox = "Inbox"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nip65:
            rawValue
        case .inbox:
            L10n.string("Inbox")
        }
    }

    var description: String {
        switch self {
        case .nip65:
            L10n.string("Profile relay list")
        case .inbox:
            L10n.string("Message delivery relays")
        }
    }
}

struct ProfileDraft: Equatable {
    var name: String
    var displayName: String
    var about: String
    var picture: String {
        didSet {
            guard picture != oldValue else { return }
            sanitizedPictureURL = RemoteImageURLPolicy.sanitizedURL(from: picture)
        }
    }
    private(set) var sanitizedPictureURL: URL?
    var nip05: String
    var lud16: String

    init(
        name: String = "",
        displayName: String = "",
        about: String = "",
        picture: String = "",
        nip05: String = "",
        lud16: String = ""
    ) {
        self.name = name
        self.displayName = displayName
        self.about = about
        self.picture = picture
        self.sanitizedPictureURL = RemoteImageURLPolicy.sanitizedURL(from: picture)
        self.nip05 = nip05
        self.lud16 = lud16
    }
}

struct RelaySettingsSnapshot: Equatable {
    var nip65: [String]
    var inbox: [String]
    var defaultRelays: [String]
    var bootstrapRelays: [String]
    var publishedNip65: [String]
    var publishedInbox: [String]
    var missing: [String]
    var isComplete: Bool

    static let defaults = RelaySettingsSnapshot(
        nip65: MarmotClient.seedRelays,
        inbox: MarmotClient.seedRelays,
        defaultRelays: MarmotClient.seedRelays,
        bootstrapRelays: MarmotClient.seedRelays,
        publishedNip65: MarmotClient.seedRelays,
        publishedInbox: MarmotClient.seedRelays,
        missing: [],
        isComplete: true
    )

    func relays(for section: RelaySettingsSection) -> [String] {
        switch section {
        case .nip65: nip65
        case .inbox: inbox
        }
    }

    mutating func setRelays(_ relays: [String], for section: RelaySettingsSection) {
        switch section {
        case .nip65:
            nip65 = relays
        case .inbox:
            inbox = relays
        }
    }

    var publishRelays: [String] {
        firstNonEmpty([defaultRelays, nip65, inbox])
    }

    var networkBootstrapRelays: [String] {
        firstNonEmpty([bootstrapRelays, defaultRelays, nip65, inbox])
    }

    private func firstNonEmpty(_ candidates: [[String]]) -> [String] {
        candidates
            .map(Self.normalizedRelayURLs)
            .first { !$0.isEmpty }
            ?? MarmotClient.seedRelays
    }

    nonisolated private static func normalizedRelayURLs(_ relays: [String]) -> [String] {
        var seen = Set<String>()
        return
            relays
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

struct KeyPackageItem: Identifiable, Equatable {
    let accountRef: String?
    let accountIdHex: String
    let keyPackageId: String
    let keyPackageRefHex: String
    let eventIdHex: String
    let publishedAt: Date?
    let keyPackageBytes: UInt64
    let sourceRelays: [String]
    let isLocal: Bool
    let isRelayDiscovered: Bool

    var id: String {
        if !eventIdHex.isEmpty { return eventIdHex }
        if !keyPackageRefHex.isEmpty { return keyPackageRefHex }
        return keyPackageId
    }

    var sourceLabel: String {
        switch (isLocal, isRelayDiscovered) {
        case (true, true):
            L10n.string("Local + fetched")
        case (true, false):
            L10n.string("Local")
        case (false, true):
            L10n.string("Fetched")
        case (false, false):
            L10n.string("Unknown")
        }
    }

    var publishedLabel: String {
        guard let publishedAt else { return L10n.string("Unknown") }
        return DisplayText.dateTimeTimestamp(for: publishedAt)
    }
}

struct NewChatRecipient: Equatable {
    let sourceQuery: String
    let memberRef: String
    let accountIdHex: String
    let npub: String
    let displayName: String?
    let pictureURL: String?
    /// Pre-sanitized once from the peer-controlled raw URL so recipient rows only read it.
    let sanitizedPictureURL: URL?

    init(
        sourceQuery: String,
        memberRef: String,
        accountIdHex: String,
        npub: String,
        displayName: String?,
        pictureURL: String?
    ) {
        self.sourceQuery = sourceQuery
        self.memberRef = memberRef
        self.accountIdHex = accountIdHex
        self.npub = npub
        self.displayName = displayName
        self.pictureURL = pictureURL
        self.sanitizedPictureURL = RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
    }

    var title: String {
        guard let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !displayName.isEmpty
        else { return DisplayText.short(accountIdHex) }

        return displayName
    }

    var subtitle: String {
        npub.isEmpty ? DisplayText.short(accountIdHex, head: 12, tail: 10) : npub
    }

    func matches(query: String) -> Bool {
        sourceQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ChatFilter {
    static func filtered(_ chats: [ChatItem], query: String) -> [ChatItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return chats }
        return chats.filter { chat in
            chat.title.localizedCaseInsensitiveContains(needle)
                || chat.subtitle.localizedCaseInsensitiveContains(needle)
                || chat.preview.localizedCaseInsensitiveContains(needle)
        }
    }
}

nonisolated enum DisplayText {
    // Cached so per-message timestamp formatting during mapping does not re-resolve the
    // calendar or rebuild a format style for every message.
    private static let calendar = Calendar.autoupdatingCurrent
    private static let timeOnlyStyle = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let dateTimeStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
    private static let weekdayStyle = Date.FormatStyle.dateTime.weekday(.abbreviated)
    private static let monthDayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()

    static func short(_ value: String, head: Int = 8, tail: Int = 6) -> String {
        guard value.count > head + tail + 3 else { return value }
        return "\(value.prefix(head))...\(value.suffix(tail))"
    }

    static func initials(for value: String, fallback: String) -> String {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
        let parts =
            source
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        if !letters.isEmpty { return letters }
        return String(source.prefix(2)).uppercased()
    }

    static func relativeTimestamp(for date: Date, now: Date = Date(), locale: Locale = AppLanguage.currentLocale)
        -> String
    {
        if calendar.isDateInToday(date) {
            return date.formatted(timeOnlyStyle.locale(locale))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(weekdayStyle.locale(locale))
        }
        return date.formatted(monthDayStyle.locale(locale))
    }

    static func messageTimestamp(for date: Date, now: Date = Date(), locale: Locale = AppLanguage.currentLocale)
        -> String
    {
        if calendar.isDateInToday(date) {
            return date.formatted(timeOnlyStyle.locale(locale))
        }
        return dateTimeTimestamp(for: date, locale: locale)
    }

    static func dateTimeTimestamp(for date: Date, locale: Locale = AppLanguage.currentLocale) -> String {
        date.formatted(dateTimeStyle.locale(locale))
    }
}

extension AccountItem {
    static let samples: [AccountItem] = [
        AccountItem(
            id: "account-jeff",
            accountRef: "jeff",
            displayName: "Jeff",
            accountIdHex: "93f7d85ef9279a03e21b7a0f0716db579d45bbab0a664707d0af6c2e2d25aa11",
            initials: "JG"
        ),
        AccountItem(
            id: "account-lab",
            accountRef: "lab",
            displayName: "Lab",
            accountIdHex: "f46f35698b7d724aa0d746c7f6ef463d979df5e45756b7519e87f98535a44c01",
            initials: "LB"
        ),
        AccountItem(
            id: "account-field",
            accountRef: "field",
            displayName: "Field",
            accountIdHex: "20b014f1701db12b8d4732ad506ce310419eb86539913b010fe09f114d9ae51f",
            initials: "FD"
        ),
    ]
}

extension ChatItem {
    static let samples: [ChatItem] = [
        ChatItem(
            id: "chat-design",
            title: "Marmot Design",
            subtitle: "8 members",
            preview: "The desktop shell can own layout while Rust owns identity and transport.",
            updatedAt: Date().addingTimeInterval(-820),
            avatarSeed: "chat-design",
            pictureURL: nil,
            unreadCount: 3
        ),
        ChatItem(
            id: "chat-nvk",
            title: "NVK",
            subtitle: "Direct message",
            preview: "Let's keep the left rail fast for account switching.",
            updatedAt: Date().addingTimeInterval(-7_600),
            avatarSeed: "chat-nvk",
            pictureURL: nil,
            unreadCount: 0,
            isDirect: true
        ),
        ChatItem(
            id: "chat-relays",
            title: "Relay Ops",
            subtitle: "5 members",
            preview: "EU and US White Noise relays both caught up on the last run.",
            updatedAt: Date().addingTimeInterval(-90_000),
            avatarSeed: "chat-relays",
            pictureURL: nil,
            unreadCount: 1
        ),
    ]
}

extension MessageItem {
    static let samples: [String: [MessageItem]] = [
        "chat-design": [
            MessageItem(
                id: "m1",
                senderName: "NVK",
                body:
                    "We should keep accounts visible all the time. Switching identities is core, not a settings errand.",
                sentAt: Date().addingTimeInterval(-4_500),
                isOutgoing: false
            ),
            MessageItem(
                id: "m2",
                senderName: "Jeff",
                body: "Agree. Narrow account rail, wider chat drawer, detail area does the heavy lifting.",
                sentAt: Date().addingTimeInterval(-3_900),
                isOutgoing: true
            ),
            MessageItem(
                id: "m3",
                senderName: "Shaka",
                body: "I will wire the app frame around MarmotKit so real accounts and chats have a place to land.",
                sentAt: Date().addingTimeInterval(-800),
                isOutgoing: false
            ),
        ],
        "chat-nvk": [
            MessageItem(
                id: "m4",
                senderName: "NVK",
                body: "Desktop should feel denser than mobile without turning into a spreadsheet.",
                sentAt: Date().addingTimeInterval(-7_600),
                isOutgoing: false
            )
        ],
        "chat-relays": [
            MessageItem(
                id: "m5",
                senderName: "Relay Ops",
                body: "Seed relays now point at the EU and US White Noise relays for the initial Marmot runtime.",
                sentAt: Date().addingTimeInterval(-90_000),
                isOutgoing: false
            )
        ],
    ]
}
