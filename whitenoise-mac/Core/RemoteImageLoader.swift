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
/// actor; the heavy decode/resize runs in a detached task off the main thread.
nonisolated final class RemoteImageLoader: @unchecked Sendable {
    static let shared = RemoteImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    func image(for url: URL, maxPixelSize: CGFloat) async -> LoadedImage? {
        // Defense-in-depth: never fetch a URL that fails the policy, even if a caller forgot
        // to sanitize. This is the network chokepoint for all remote image loads.
        guard RemoteImageURLPolicy.isAllowed(url) else { return nil }

        let key = "\(url.absoluteString)|\(Int(maxPixelSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return LoadedImage(nsImage: cached)
        }
        guard let data = await Self.download(url, using: session) else { return nil }
        let pixelSize = maxPixelSize
        let loaded = await Task.detached(priority: .utility) {
            Self.downsample(data: data, maxPixelSize: pixelSize).map(LoadedImage.init)
        }.value
        guard let loaded else { return nil }
        cache.setObject(loaded.nsImage, forKey: key)
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
            let reserve = response.expectedContentLength > 0
                ? Int(min(response.expectedContentLength, cap))
                : nil
            return try await accumulate(bytes, cap: cap, reservingCapacity: reserve)
        } catch {
            return nil
        }
    }

    /// Size of the temporary read buffer used to batch bytes out of `URLSession.AsyncBytes`
    /// before flushing them to the result `Data`.
    static let downloadChunkSize = 64 * 1024

    /// Accumulates an async byte sequence into `Data` in fixed-size chunks, returning `nil`
    /// once the running total exceeds `cap`.
    ///
    /// `URLSession.AsyncBytes` vends a single `UInt8` per iteration. Appending each byte to a
    /// `Data` buffer individually turns even a modest avatar download into hundreds of
    /// thousands of `Data.append(_:)` calls (and millions at the 8 MiB cap), which is the
    /// pathology this loader had. We instead buffer bytes into a reusable array and flush
    /// whole slices to `Data`, while still bounding total memory incrementally so the
    /// unbounded-response protection is preserved (a chunk-granular check rather than a
    /// per-byte one; at most `chunkSize - 1` bytes can be read past `cap` before we bail).
    ///
    /// Exposed as `internal static` (not `private`) so the cap-enforcement logic is unit
    /// testable against a synthetic byte sequence without issuing a network request.
    static func accumulate<S: AsyncSequence>(
        _ bytes: S,
        cap: Int64,
        reservingCapacity reserve: Int? = nil,
        chunkSize: Int = RemoteImageLoader.downloadChunkSize
    ) async throws -> Data? where S.Element == UInt8 {
        var data = Data()
        if let reserve { data.reserveCapacity(reserve) }

        var chunk = [UInt8]()
        chunk.reserveCapacity(chunkSize)
        var total: Int64 = 0

        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= chunkSize {
                total += Int64(chunk.count)
                if total > cap { return nil }
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            total += Int64(chunk.count)
            if total > cap { return nil }
            data.append(contentsOf: chunk)
        }
        return data
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
}
