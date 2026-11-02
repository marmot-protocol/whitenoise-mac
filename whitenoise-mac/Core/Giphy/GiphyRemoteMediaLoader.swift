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

    /// `invalidResponse` is transient (nothing usable came back from the network, so asking
    /// again may work); `invalidURL` and `unsupportedMedia` are verdicts on the media itself and
    /// fail the same way every time. `isPermanent(_:)` is the one place that tells them apart.
    enum Failure: LocalizedError, Equatable {
        case invalidURL
        case invalidResponse
        case unsupportedMedia

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

        guard media.url.pathExtension.lowercased() != "gif" else {
            return try await prepareAnimatedImage(at: media.url, fetch: fetch)
        }
        guard let apiKey else {
            log.error("legacy_lookup_failed reason=missing_api_key")
            throw Failure.unsupportedMedia
        }
        let candidates = try await GiphySearchClient(apiKey: apiKey, fetch: fetch)
            .resolveAnimatedCandidates(for: media.url)
        return try await firstAdmitted(of: candidates) { candidate in
            try await prepareAnimatedImage(at: candidate.url, fetch: fetch)
        }.playback
    }

    /// Whether `error` is a verdict on the media itself, so retrying the same URL cannot help.
    /// Cancellation and everything transport-shaped count as transient.
    static func isPermanent(_ error: Error) -> Bool {
        switch error {
        case let failure as Failure: failure != .invalidResponse
        case let failure as GiphySearchError: failure == .invalidRequest || failure == .unsupportedMedia
        default: false
        }
    }

    /// Prepares `candidates` in order and returns the first one admission and ImageIO accept.
    /// A permanent refusal moves on to the next rendition; anything else — a transport failure,
    /// cancellation — ends the walk, since a later rendition is not more likely to download.
    static func firstAdmitted(
        of candidates: [RemoteGiphyMedia],
        prepare: (RemoteGiphyMedia) async throws -> PreparedPlayback
    ) async throws -> (media: RemoteGiphyMedia, playback: PreparedPlayback) {
        for candidate in candidates {
            do {
                return (candidate, try await prepare(candidate))
            } catch  where isPermanent(error) {
                continue
            }
        }
        throw Failure.unsupportedMedia
    }

    private static func prepareAnimatedImage(at url: URL, fetch: GiphySearchClient.Fetch) async throws
        -> PreparedPlayback
    {
        let data = await fetch(url)
        try Task.checkCancellation()
        guard let data, !data.isEmpty else {
            log.error("media_download_failed bytes=0")
            throw Failure.invalidResponse
        }
        guard data.count <= GiphySearchClient.maximumMediaBytes else {
            log.error("media_download_failed bytes=\(data.count, privacy: .public)")
            throw Failure.unsupportedMedia
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
        let metadata: GIFPlaybackAdmission.Metadata
        switch GIFPlaybackAdmission.evaluate(data) {
        case .success(let admitted):
            metadata = admitted
        case .failure(let rejection):
            log.error(
                "gif_admission_refused reason=\(rejection.rawValue, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            throw Failure.unsupportedMedia
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
            CGImageSourceGetCount(source) == metadata.frameCount,
            CGImageSourceGetStatus(source) == .statusComplete,
            let type = CGImageSourceGetType(source),
            UTType(type as String)?.conforms(to: .gif) == true,
            // Header checks cannot predict ImageIO's own decode limits, and an undecodable
            // frame crashes the animator; the area cap bounds this raster to 16 MiB.
            CGImageSourceCreateImageAtIndex(source, 0, options) != nil
        else {
            log.error("image_decode_failed bytes=\(data.count, privacy: .public)")
            throw Failure.unsupportedMedia
        }
        return CGFloat(metadata.width) / CGFloat(metadata.height)
    }
}
