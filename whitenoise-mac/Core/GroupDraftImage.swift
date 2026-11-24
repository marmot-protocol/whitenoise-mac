//
//  GroupDraftImage.swift
//  whitenoise-mac
//
//  The picture chosen for a group that does not exist yet.
//

import Foundation
import MarmotKit

/// A cropped picture held by the New group flow until Create, when it founds the group with it.
///
/// Ported from `whitenoise-ios`'s `GroupImageUploadDraft`. The bytes are the crop editor's JPEG,
/// already stripped of everything but pixels by `AvatarImageCropper.attachment`, and they travel
/// only as the encrypted group-image component: no URL is ever offered as the legacy fallback.
nonisolated struct GroupDraftImage: Equatable, Sendable {
    let attachment: PendingMediaAttachment
    /// The same bytes, wrapped for the avatar views that draw the draft before it is a group.
    let preview: DownloadedMediaPayload

    init(attachment: PendingMediaAttachment) {
        self.attachment = attachment
        self.preview = DownloadedMediaPayload(
            id: "group-draft-image-\(attachment.plaintextSHA256)",
            data: attachment.data
        )
    }

    /// Prepares the crop editor's output as a founding picture.
    static func prepared(fromCroppedImageData data: Data) async throws -> GroupDraftImage {
        let attachment = try await AvatarImageCropper.attachment(fromCroppedImageData: data)
        guard attachment.kind == .image else {
            throw GroupImageSelectionError.notAnImage
        }
        return GroupDraftImage(attachment: attachment)
    }

    var initialImage: InitialGroupImageFfi {
        InitialGroupImageFfi(
            plaintext: attachment.data,
            mediaType: attachment.mediaType,
            // Never a URL: MDK would publish it to members whose clients lack the encrypted
            // component, and a picked file has no public URL to give anyway.
            sourceUrl: nil,
            dim: attachment.dim,
            thumbhash: attachment.thumbhash
        )
    }

    /// Identity by content, on purpose: two drafts of the same bytes are the same picture, whatever
    /// `PendingMediaAttachment.id` each was wrapped in. `whitenoise-ios`'s `==` compares every field;
    /// this one does not need to, because nothing but the bytes and their type reaches the group.
    static func == (lhs: GroupDraftImage, rhs: GroupDraftImage) -> Bool {
        lhs.attachment.plaintextSHA256 == rhs.attachment.plaintextSHA256
            && lhs.attachment.mediaType == rhs.attachment.mediaType
    }
}
