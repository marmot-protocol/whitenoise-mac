import CoreGraphics
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Downloads a GIPHY envelope's animation and validates that it really is an animated GIF before
/// anything draws it.
nonisolated enum GiphyRemoteMediaLoader {
    struct PreparedPlayback: Sendable, Equatable {
        let data: Data
        let aspectRatio: CGFloat
    }

    enum Failure: LocalizedError, Equatable {
        case invalidURL
        case invalidResponse

        var errorDescription: String? {
            L10n.string("This GIF couldn't be loaded.")
        }
    }

    private static let log = Logger(subsystem: "dev.ipf.whitenoise.mac", category: "giphy-playback")

    /// - Parameters:
    ///   - apiKey: needed only for a legacy MP4 envelope, which is resolved to its GIF rendition.
    ///   - fetch: the bounded remote download; injectable so tests never touch the network.
    static func preparePlayback(
        for media: RemoteGiphyMedia,
        apiKey: String? = GiphyBuildConfig.current().apiKey,
        fetch: @escaping GiphySearchClient.Fetch = { url in await RemoteImageLoader.shared.data(for: url) }
    ) async throws -> PreparedPlayback {
        guard RemoteGiphyMedia.validatedMediaURL(media.url.absoluteString) != nil else {
            throw Failure.invalidURL
        }

        let animatedMedia: RemoteGiphyMedia
        if media.url.pathExtension.lowercased() == "gif" {
            animatedMedia = media
        } else {
            guard let apiKey else {
                log.error("legacy_lookup_failed reason=missing_api_key")
                throw Failure.invalidResponse
            }
            animatedMedia = try await GiphySearchClient(apiKey: apiKey, fetch: fetch)
                .resolveAnimatedMedia(for: media.url)
        }

        let data = await fetch(animatedMedia.url)
        try Task.checkCancellation()
        guard let data, !data.isEmpty, data.count <= GiphySearchClient.maximumMediaBytes else {
            log.error("media_download_failed bytes=\(data?.count ?? 0, privacy: .public)")
            throw Failure.invalidResponse
        }
        let aspectRatio = try await Task.detached(priority: .utility) {
            try animatedImageAspectRatio(from: data)
        }.value
        return PreparedPlayback(data: data, aspectRatio: aspectRatio)
    }

    /// The admitted logical canvas's aspect ratio. The byte-level resource gate runs before
    /// ImageIO inspection, and neither downloaded metadata nor retries bypass it.
    static func animatedImageAspectRatio(from data: Data) throws -> CGFloat {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let metadata = GIFPlaybackAdmission.inspect(data),
            let source = CGImageSourceCreateWithData(data as CFData, options),
            CGImageSourceGetCount(source) == metadata.frameCount,
            CGImageSourceGetStatus(source) == .statusComplete,
            let type = CGImageSourceGetType(source),
            UTType(type as String)?.conforms(to: .gif) == true
        else {
            log.error("image_decode_failed bytes=\(data.count, privacy: .public)")
            throw Failure.invalidResponse
        }
        return CGFloat(metadata.width) / CGFloat(metadata.height)
    }
}
