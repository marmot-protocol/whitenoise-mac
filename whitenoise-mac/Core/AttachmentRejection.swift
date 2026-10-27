import Foundation

/// A file the composer refused to stage, and why.
///
/// A multi-file selection stages everything it can and reports the rest one by one, so the user
/// only has to deal with the files that failed. The reason is kept as data rather than as a
/// pre-rendered string so the notice localizes it against the view's `\.locale`, and so a size
/// limit is formatted in the language it is shown in.
nonisolated struct AttachmentRejection: Equatable, Sendable {
    /// What the user picked, as they would recognize it.
    enum Source: Equatable, Sendable {
        case file(name: String)
        /// Image bytes pasted from the clipboard, which carry no name of their own.
        case pastedImage

        init(pasteboardItem: OutgoingMediaPasteboardAttachment) {
            switch pasteboardItem.payload {
            case .fileURL(let url): self = .file(name: url.lastPathComponent)
            case .imageData: self = .pastedImage
            }
        }
    }

    enum Reason: Equatable, Sendable {
        case tooLarge(limitBytes: Int)
        case unsupportedType
        case unreadableImage
        case preparationFailed
        /// The selection went past the per-message attachment cap.
        case attachmentLimitReached(maxCount: Int)
        static var perMessageLimitReached: Reason {
            .attachmentLimitReached(maxCount: OutgoingMediaDraftProcessor.maxAttachmentCount)
        }

        /// Anything else, already localized by whoever threw it (a file-system error, usually).
        case other(String)

        init(_ error: any Error) {
            guard let failure = error as? OutgoingMediaDraftProcessor.Failure else {
                self = .other(error.localizedDescription)
                return
            }
            switch failure {
            case .attachmentTooLarge(_, let limit): self = .tooLarge(limitBytes: limit)
            case .unsupportedAttachment: self = .unsupportedType
            case .unsupportedImage: self = .unreadableImage
            case .encodingFailed: self = .preparationFailed
            }
        }
    }

    let source: Source
    let reason: Reason

    init(source: Source, reason: Reason) {
        self.source = source
        self.reason = reason
    }

    init(fileURL url: URL, reason: Reason) {
        self.init(source: .file(name: url.lastPathComponent), reason: reason)
    }

    func displayName(locale: Locale) -> String {
        switch source {
        case .file(let name): name
        case .pastedImage: L10n.string("Pasted image", locale: locale)
        }
    }

    func reasonDescription(locale: Locale) -> String {
        switch reason {
        case .tooLarge(let limitBytes):
            String(
                format: L10n.string("That attachment is too large to send. The limit is %@.", locale: locale),
                Self.formattedLimit(limitBytes, locale: locale)
            )
        case .unsupportedType:
            L10n.string("That file type is not supported.", locale: locale)
        case .unreadableImage:
            L10n.string("That image could not be opened.", locale: locale)
        case .preparationFailed:
            L10n.string("That attachment could not be prepared.", locale: locale)
        case .attachmentLimitReached(let maxCount):
            String(
                format: L10n.string("You can send up to %lld attachments at once", locale: locale),
                Int64(maxCount)
            )
        case .other(let description):
            description
        }
    }

    /// The limit in binary units, so the 50 MiB cap reads "50 MB" rather than "52.4 MB".
    static func formattedLimit(_ bytes: Int, locale: Locale) -> String {
        Int64(bytes).formatted(ByteCountFormatStyle(style: .binary, locale: locale))
    }
}
