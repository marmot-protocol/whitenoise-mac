//
//  AvatarImageCropSource.swift
//  whitenoise-mac
//
//  Where the bytes the crop editor opens come from.
//

import Foundation

/// The two places a profile or group picture comes from, reduced to the same thing — bounded
/// bytes — so the crop editor that follows never knows which one it was handed.
nonisolated enum AvatarImageCropSource {
    enum Failure: LocalizedError, Equatable {
        case invalidWebImage
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .invalidWebImage:
                L10n.string("The selected web image URL is not safe to download.")
            case .downloadFailed:
                L10n.string("The selected web image could not be downloaded.")
            }
        }
    }

    /// A file the open panel handed back, read no further than one byte past the cap so a huge
    /// file cannot be buffered whole before it is refused.
    static func data(
        fromFileURL url: URL,
        maximumBytes: Int = AvatarImageCropper.maximumEncodedBytes
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values.isDirectory != true else {
                throw OutgoingMediaDraftProcessor.Failure.unsupportedImage
            }
            if let fileSize = values.fileSize, fileSize > maximumBytes {
                throw OutgoingMediaDraftProcessor.Failure.attachmentTooLarge(fileSize)
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else {
                throw OutgoingMediaDraftProcessor.Failure.attachmentTooLarge(data.count)
            }
            guard !data.isEmpty else { throw OutgoingMediaDraftProcessor.Failure.unsupportedImage }
            return data
        }.value
    }

    /// A web search result, fetched through the same loader — and the same URL policy — every
    /// other remote picture goes through.
    static func data(
        for result: GroupImageSearchResult,
        using loader: any GroupImageSourceLoading
    ) async throws -> Data {
        guard let url = RemoteImageURLPolicy.sanitizedURL(from: result.imageURL) else {
            throw Failure.invalidWebImage
        }
        guard let data = await loader.data(for: url) else {
            throw Failure.downloadFailed
        }
        try Task.checkCancellation()
        return data
    }
}
