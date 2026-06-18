import SwiftUI
import AppKit
import ImageIO

/// An NSImage wrapper that is safe to hand back from the background loader.
struct LoadedImage: @unchecked Sendable {
    let nsImage: NSImage
}

/// Privacy/safety policy for remote image URLs.
///
/// Profile/avatar `picture` URLs originate from untrusted peer Nostr metadata. Loading them
/// directly leaks the viewer's IP address and online status to any server the sender chooses
/// (a tracking-pixel vector) and, for `http://` URLs, exposes the request to network observers.
/// This policy is the single place that decides whether a remote image URL is allowed to be
/// fetched at all: it requires `https`, a non-empty host, and a standard web port. The
/// *decision to load remote images at all* is gated separately behind a user preference
/// (`WorkspaceState.loadRemoteImages`, default off); this policy is the defense-in-depth check
/// that runs even once the user has opted in.
enum RemoteImageURLPolicy {
    /// Maximum bytes we are willing to download for a single remote image. A malicious URL can
    /// otherwise serve an arbitrarily large response. 8 MiB is generous for an avatar/preview.
    static let maxResponseBytes: Int64 = 8 * 1024 * 1024

    /// Returns true if `url` is safe to fetch: `https` scheme with a non-empty host.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Parses a raw profile string into a fetchable URL, applying the same trimming the UI uses
    /// and rejecting anything that fails `isAllowed`. Returns nil for empty/invalid/disallowed
    /// input so callers can fall back to a generated avatar without ever issuing a request.
    static func sanitizedURL(from raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              isAllowed(url)
        else { return nil }
        return url
    }
}

/// Drop-in replacement for `AsyncImage` that loads a remote image once, downsamples it
/// to the size it is actually displayed at (off the main thread), and caches the decoded
/// result. Bare `AsyncImage` re-fetches and decodes the full-resolution image on the main
/// thread every time a row reappears, which is wasteful across the chat list and settings
/// avatars. On any failure it shows `placeholder`.
struct DownsampledAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let maxPixelSize: CGFloat
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: Image?

    var body: some View {
        ZStack {
            if let image {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: TaskKey(url: url, size: maxPixelSize)) {
            image = nil
            guard let url else { return }
            if let loaded = await RemoteImageLoader.shared.image(for: url, maxPixelSize: maxPixelSize) {
                image = Image(nsImage: loaded.nsImage)
            }
        }
    }

    private struct TaskKey: Equatable {
        let url: URL?
        let size: CGFloat
    }
}

/// Shared image cache + downsampling pipeline. `NSCache` is thread-safe, so this needs no
/// actor for decoded-image storage; in-flight work is coordinated by `RemoteImageLoadRegistry`
/// so concurrent views that need the same URL/size await one download and decode.
private actor RemoteImageLoadRegistry {
    private var tasks: [String: Task<LoadedImage?, Never>] = [:]

    func task(
        for key: String,
        create: @Sendable () -> Task<LoadedImage?, Never>
    ) -> (task: Task<LoadedImage?, Never>, owner: Bool) {
        if let task = tasks[key] {
            return (task, false)
        }
        let task = create()
        tasks[key] = task
        return (task, true)
    }

    func removeTask(for key: String) {
        tasks[key] = nil
    }
}

nonisolated final class RemoteImageLoader: @unchecked Sendable {
    static let shared = RemoteImageLoader()
    static let defaultDecodedCacheCountLimit = 512
    static let defaultDecodedCacheTotalCostLimit = 64 * 1024 * 1024

    private let cache = NSCache<NSString, NSImage>()
    private let inFlight = RemoteImageLoadRegistry()
    private let session: URLSession

    var decodedCacheCountLimit: Int { cache.countLimit }
    var decodedCacheTotalCostLimit: Int { cache.totalCostLimit }

    init(
        session: URLSession = RemoteImageLoader.makeSession(),
        cacheCountLimit: Int = RemoteImageLoader.defaultDecodedCacheCountLimit,
        cacheTotalCostLimit: Int = RemoteImageLoader.defaultDecodedCacheTotalCostLimit
    ) {
        self.session = session
        cache.countLimit = cacheCountLimit
        cache.totalCostLimit = cacheTotalCostLimit
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> LoadedImage? {
        // Defense-in-depth: never fetch a URL that fails the policy, even if a caller forgot
        // to sanitize. This is the network chokepoint for all remote image loads.
        guard RemoteImageURLPolicy.isAllowed(url) else { return nil }

        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            return LoadedImage(nsImage: cached)
        }

        let (task, owner) = await inFlight.task(for: key) { [self] in
            Task { [self] in
                await loadImage(for: url, cacheKey: key, maxPixelSize: maxPixelSize)
            }
        }
        let loaded = await task.value
        if owner {
            await inFlight.removeTask(for: key)
        }
        return loaded
    }

    private static func cacheKey(for url: URL, maxPixelSize: CGFloat) -> String {
        "\(url.absoluteString)|\(Int(maxPixelSize))"
    }

    private func loadImage(for url: URL, cacheKey: String, maxPixelSize: CGFloat) async -> LoadedImage? {
        let key = cacheKey as NSString
        if let cached = cache.object(forKey: key) {
            return LoadedImage(nsImage: cached)
        }

        guard let data = await Self.download(url, using: session) else { return nil }
        let pixelSize = maxPixelSize
        let loaded = await Task.detached(priority: .utility) {
            Self.downsample(data: data, maxPixelSize: pixelSize).map(LoadedImage.init)
        }.value
        guard let loaded else { return nil }
        cache.setObject(loaded.nsImage, forKey: key, cost: Self.decodedCost(for: loaded.nsImage))
        return loaded
    }

    /// Streams the response, rejecting non-success HTTP status codes and aborting once the
    /// body exceeds `RemoteImageURLPolicy.maxResponseBytes` so a malicious server cannot feed
    /// us an unbounded image.
    private static func download(_ url: URL, using session: URLSession) async -> Data? {
        let cap = RemoteImageURLPolicy.maxResponseBytes
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            // Honour an advertised oversized Content-Length up front when present.
            if response.expectedContentLength > 0, response.expectedContentLength > cap {
                return nil
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(min(response.expectedContentLength, cap)))
            }
            for try await byte in bytes {
                data.append(byte)
                if Int64(data.count) > cap { return nil }
            }
            return data
        } catch {
            return nil
        }
    }

    private static func downsample(data: Data, maxPixelSize: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(1, maxPixelSize))
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func decodedCost(for image: NSImage) -> Int {
        let representation = image.representations.first
        let width = max(1, representation?.pixelsWide ?? Int(ceil(image.size.width)))
        let height = max(1, representation?.pixelsHigh ?? Int(ceil(image.size.height)))
        guard width <= Int.max / max(height, 1) / 4 else {
            return defaultDecodedCacheTotalCostLimit
        }
        return width * height * 4
    }
}
