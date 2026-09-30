import Foundation

nonisolated struct GiphySearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let media: RemoteGiphyMedia
}

nonisolated enum GiphySearchError: LocalizedError, Equatable {
    case missingAPIKey
    case queryTooLong
    case invalidRequest
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            L10n.string("GIF search isn't configured in this build.")
        case .queryTooLong:
            L10n.string("That GIF search is too long.")
        case .invalidRequest, .badResponse:
            L10n.string("GIF search is temporarily unavailable.")
        }
    }
}

/// GIPHY's search and single-GIF lookup APIs, ported from whitenoise-ios.
///
/// Every request goes through `fetch`, which defaults to `RemoteImageLoader`'s bounded download: the
/// ephemeral, memory-only session with the same HTTPS/SSRF redirect checks, stall timeout, and
/// response cap every other remote fetch in the app uses. A non-2xx response comes back as nil.
nonisolated struct GiphySearchClient: Sendable {
    static let maximumResultCount = 24
    static let maximumQueryLength = 50
    static let maximumTitleLength = 160
    static let preferredMaximumMediaBytes = 2 * 1_024 * 1_024
    static let maximumMediaBytes = 5 * 1_024 * 1_024

    typealias Fetch = @Sendable (URL) async -> Data?

    let apiKey: String
    var fetch: Fetch = { url in await RemoteImageLoader.shared.data(for: url) }

    func search(_ rawQuery: String, locale: Locale = AppLanguage.currentLocale) async throws -> [GiphySearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        guard query.count <= Self.maximumQueryLength else { throw GiphySearchError.queryTooLong }
        guard let url = Self.searchURL(query: query, apiKey: apiKey, locale: locale) else {
            throw GiphySearchError.invalidRequest
        }
        let data = await fetch(url)
        try Task.checkCancellation()
        guard let data else { throw GiphySearchError.badResponse }
        return try Self.decodeResults(from: data)
    }

    /// Resolves a legacy MP4 envelope to the GIF rendition of the same GIPHY item, which is what
    /// the bubble can actually animate.
    func resolveAnimatedMedia(for legacyURL: URL) async throws -> RemoteGiphyMedia {
        guard let id = Self.giphyID(from: legacyURL),
            let url = Self.lookupURL(id: id, apiKey: apiKey)
        else { throw GiphySearchError.invalidRequest }
        let data = await fetch(url)
        try Task.checkCancellation()
        guard let data else { throw GiphySearchError.badResponse }
        return try Self.decodeLookupResult(from: data)
    }

    static func searchURL(query: String, apiKey: String, locale: Locale) -> URL? {
        guard !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/search")
        let language = locale.language.languageCode?.identifier ?? "en"
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(maximumResultCount)),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "rating", value: "pg-13"),
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "bundle", value: "messaging_non_clips"),
        ]
        return components?.url
    }

    static func lookupURL(id: String, apiKey: String) -> URL? {
        guard isValidGiphyID(id), !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.giphy.com/v1/gifs/\(id)")
        components?.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        return components?.url
    }

    static func giphyID(from mediaURL: URL) -> String? {
        guard RemoteGiphyMedia.validatedMediaURL(mediaURL.absoluteString) != nil else { return nil }
        let components = mediaURL.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        let id = components[components.count - 2]
        return isValidGiphyID(id) ? id : nil
    }

    static func decodeResults(from data: Data) throws -> [GiphySearchResult] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GiphySearchError.badResponse
        }
        return response.data.prefix(maximumResultCount).compactMap(result(from:))
    }

    static func decodeLookupResult(from data: Data) throws -> RemoteGiphyMedia {
        let response: LookupResponse
        do {
            response = try JSONDecoder().decode(LookupResponse.self, from: data)
        } catch {
            throw GiphySearchError.badResponse
        }
        guard let result = result(from: response.data),
            result.media.url.pathExtension.lowercased() == "gif"
        else { throw GiphySearchError.badResponse }
        return result.media
    }

    private static func result(from item: Item) -> GiphySearchResult? {
        guard let media = mediaRendition(from: item.images) else { return nil }

        let rawAttribution =
            item.user?.displayName?.nilIfBlank
            ?? item.user?.username?.nilIfBlank
            ?? item.username?.nilIfBlank
            ?? item.sourceTLD?.nilIfBlank
        let attribution = rawAttribution.flatMap(RemoteGiphyMedia.sanitizedAttribution)
        let title =
            PeerDisplayText.sanitize(item.title).map { String($0.prefix(maximumTitleLength)) }
            ?? L10n.string("GIF")
        return GiphySearchResult(
            id: String(item.id.prefix(128)),
            title: title,
            media: RemoteGiphyMedia(
                url: media.url,
                width: media.width,
                height: media.height,
                attribution: attribution
            )
        )
    }

    private static func isValidGiphyID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            }
    }

    /// The largest GIF rendition under the preferred byte budget, or the smallest one when every
    /// rendition is over it. Only `.gif` URLs are considered: `NSImageView` animates GIF data
    /// natively, and the MP4 renditions would need a video player per bubble.
    private static func mediaRendition(from images: Images) -> (url: URL, width: Int, height: Int)? {
        let renditions = [
            images.original,
            images.downsizedMedium,
            images.downsized,
            images.fixedHeightDownsampled,
            images.fixedWidthDownsampled,
            images.fixedHeight,
            images.fixedWidth,
        ].compactMap { $0 }
        let candidates = renditions.compactMap(candidate(from:))
        let preferred = candidates.filter { $0.byteCount <= preferredMaximumMediaBytes }
        let selected =
            preferred.max { ($0.width * $0.height) < ($1.width * $1.height) }
            ?? candidates.min { $0.byteCount < $1.byteCount }
        return selected.map { ($0.url, $0.width, $0.height) }
    }

    private static func candidate(from rendition: Rendition) -> (url: URL, width: Int, height: Int, byteCount: Int)? {
        guard let url = RemoteGiphyMedia.validatedMediaURL(rendition.url ?? ""),
            url.pathExtension.lowercased() == "gif",
            let width = boundedDimension(rendition.width),
            let height = boundedDimension(rendition.height),
            let byteCount = boundedByteCount(rendition.size)
        else { return nil }
        return (url, width, height, byteCount)
    }

    private static func boundedDimension(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), (1...4_096).contains(value) else { return nil }
        return value
    }

    private static func boundedByteCount(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), (1...maximumMediaBytes).contains(value) else { return nil }
        return value
    }

    private struct Response: Decodable {
        let data: [Item]
    }

    private struct LookupResponse: Decodable {
        let data: Item
    }

    private struct Item: Decodable {
        let id: String
        let title: String
        let username: String?
        let sourceTLD: String?
        let user: User?
        let images: Images

        enum CodingKeys: String, CodingKey {
            case id, title, username, user, images
            case sourceTLD = "source_tld"
        }
    }

    private struct User: Decodable {
        let username: String?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case username
            case displayName = "display_name"
        }
    }

    private struct Images: Decodable {
        let fixedWidth: Rendition?
        let fixedHeight: Rendition?
        let fixedWidthDownsampled: Rendition?
        let fixedHeightDownsampled: Rendition?
        let downsized: Rendition?
        let downsizedMedium: Rendition?
        let original: Rendition?

        enum CodingKeys: String, CodingKey {
            case fixedWidth = "fixed_width"
            case fixedHeight = "fixed_height"
            case fixedWidthDownsampled = "fixed_width_downsampled"
            case fixedHeightDownsampled = "fixed_height_downsampled"
            case downsized
            case downsizedMedium = "downsized_medium"
            case original
        }
    }

    private struct Rendition: Decodable {
        let width: String?
        let height: String?
        let url: String?
        let size: String?
    }
}
