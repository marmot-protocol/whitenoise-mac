//
//  LinkPreviewLoader.swift
//  whitenoise-mac
//
//  Fetches and caches the metadata behind link previews. The preview image itself goes through
//  `RemoteImageLoader` like any other remote image, so its fetch, decode cache, and wipe are shared.
//

import Foundation

@MainActor
final class LinkPreviewLoader {
    /// A page fetch: the body and final response, or nil when the fetch itself failed.
    typealias PageFetch = @Sendable (URLRequest) async -> (Data, URLResponse)?

    /// A `LinkPreviewMetadata?` that `NSCache` can hold — a cached nil means "this page has
    /// nothing to preview", which is worth remembering so it is not fetched again.
    private final class CachedMetadata: NSObject {
        let metadata: LinkPreviewMetadata?

        init(_ metadata: LinkPreviewMetadata?) {
            self.metadata = metadata
        }
    }

    private struct InFlight {
        let owner: UUID
        let task: Task<FetchOutcome, Never>
    }

    /// `failed` is not cached, so a page that timed out is tried again the next time it is shown;
    /// `loaded(nil)` is, because asking again would get the same answer.
    nonisolated enum FetchOutcome: Equatable, Sendable {
        case loaded(LinkPreviewMetadata?)
        case failed
    }

    static let shared = LinkPreviewLoader()

    nonisolated static let htmlMIMETypes: Set<String> = ["text/html", "application/xhtml+xml"]
    nonisolated private static let acceptHeader = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1"

    private let cache: NSCache<NSString, CachedMetadata> = {
        let cache = NSCache<NSString, CachedMetadata>()
        cache.countLimit = 300
        return cache
    }()
    private var inFlight: [String: InFlight] = [:]
    private let fetch: PageFetch

    init(fetch: @escaping PageFetch = { await RemoteImageLoader.shared.page(for: $0) }) {
        self.fetch = fetch
    }

    /// The cached answer for `url`, if there is one: `.some(nil)` means the page has no preview.
    func cachedMetadata(for url: URL) -> LinkPreviewMetadata?? {
        cache.object(forKey: url.absoluteString as NSString).map(\.metadata)
    }

    /// The preview for `url`, fetched at most once at a time no matter how many bubbles link it.
    func metadata(for url: URL) async -> LinkPreviewMetadata? {
        let key = url.absoluteString
        if let cached = cache.object(forKey: key as NSString) { return cached.metadata }
        if let existing = inFlight[key] {
            guard case .loaded(let metadata) = await existing.task.value else { return nil }
            return metadata
        }

        let owner = UUID()
        let task = Task { [fetch] in await Self.fetchMetadata(for: url, fetch: fetch) }
        inFlight[key] = InFlight(owner: owner, task: task)
        let outcome = await task.value
        // `clearCache()` drops every in-flight entry, so a fetch that finishes after an erase no
        // longer owns its key and must not put the page back.
        guard inFlight[key]?.owner == owner else { return nil }
        inFlight[key] = nil
        guard case .loaded(let metadata) = outcome else { return nil }
        cache.setObject(CachedMetadata(metadata), forKey: key as NSString)
        return metadata
    }

    /// For Erase App Data: forget every page, and let no fetch still running bring one back.
    func clearCache() {
        cache.removeAllObjects()
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
    }

    /// Fetches `url` and parses its `<head>`, off the main actor. Only HTML is parsed, against the
    /// URL the redirects ended at so relative image paths resolve the way a browser would.
    nonisolated static func fetchMetadata(for url: URL, fetch: PageFetch) async -> FetchOutcome {
        guard let validated = LinkPreviewMetadata.fetchableURL(url.absoluteString) else { return .loaded(nil) }
        guard let (data, response) = await fetch(request(for: validated)) else { return .failed }
        guard let mimeType = response.mimeType?.lowercased(), htmlMIMETypes.contains(mimeType) else {
            return .loaded(nil)
        }
        let baseURL = response.url ?? validated
        let metadata = await Task.detached(priority: .utility) {
            LinkPreviewMetadata.parse(html: data, baseURL: baseURL)
        }.value
        return .loaded(metadata)
    }

    nonisolated static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
        return request
    }
}
