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

    /// Downloads the response in the `Data` chunks `URLSession` delivers natively, rejecting
    /// non-success HTTP status codes and aborting once the body exceeds
    /// `RemoteImageURLPolicy.maxResponseBytes` so a malicious server cannot feed us an
    /// unbounded image.
    ///
    /// We deliberately avoid `URLSession.AsyncBytes` (whose `Element` is a single `UInt8`, so
    /// iterating it costs one async-sequence step per byte — 10^5–10^6 steps for a normal
    /// avatar) and also avoid the fully-buffered `data(from:)` (which would have to hold an
    /// entire malicious response in memory before we could check its length). Instead a
    /// `URLSessionDataDelegate` collects the OS-sized chunks as they arrive, so a download is
    /// O(number-of-chunks) while the incremental cap keeps peak memory bounded to roughly
    /// `cap` plus one chunk before an oversized/length-less response is cancelled.
    private static func download(_ url: URL, using session: URLSession) async -> Data? {
        let cap = RemoteImageURLPolicy.maxResponseBytes
        let delegate = CappedImageDownloadDelegate(cap: cap)
        // A dedicated delegate-backed session keeps per-download collector state isolated
        // (multiple avatars can download concurrently). It reuses the shared session's
        // configuration, so the same `URLCache` instance still services these requests.
        let downloadSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { downloadSession.finishTasksAndInvalidate() }
        return await delegate.download(url, using: downloadSession)
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

/// Pure, synchronously-testable accumulator for a capped chunked download. Collects the
/// `Data` chunks `URLSession` delivers and reports when the running total exceeds `cap`, so
/// the cap-enforcement logic can be unit tested without issuing a network request.
///
/// This is the chunk-granular replacement for the old per-byte loop: appends operate on
/// whole `Data` chunks (one per `URLSession` delivery) rather than individual `UInt8`s.
struct CappedDataCollector {
    let cap: Int64
    private(set) var data = Data()
    private(set) var total: Int64 = 0
    private(set) var exceededCap = false

    init(cap: Int64, reservingCapacity reserve: Int? = nil) {
        self.cap = cap
        if let reserve { data.reserveCapacity(reserve) }
    }

    /// Reserves capacity for the result buffer (e.g. from an advertised `Content-Length`).
    mutating func reserve(_ minimumCapacity: Int) {
        data.reserveCapacity(minimumCapacity)
    }

    /// Appends a chunk, returning `false` once the running total exceeds `cap` (the caller
    /// should then abort the download). The over-cap chunk is not retained, and once the cap
    /// has been exceeded all further appends are rejected.
    @discardableResult
    mutating func append(_ chunk: Data) -> Bool {
        if exceededCap { return false }
        total += Int64(chunk.count)
        if total > cap {
            exceededCap = true
            return false
        }
        data.append(chunk)
        return true
    }
}

/// `URLSessionDataDelegate` that downloads a single image body in the chunks `URLSession`
/// delivers natively, enforcing an HTTP status check, an up-front `Content-Length` check,
/// and an incremental byte cap. Bridges the delegate callbacks to a single `async` result.
///
/// Using the delegate's `didReceive data:` (which hands us OS-sized `Data` chunks) instead
/// of `URLSession.AsyncBytes` is what removes the per-byte iteration: a download now costs
/// O(number-of-chunks), not O(number-of-bytes), while the incremental cap still aborts an
/// oversized or `Content-Length`-less response before it can exhaust memory.
private final class CappedImageDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let cap: Int64
    private let lock = NSLock()
    private var collector: CappedDataCollector
    private var continuation: CheckedContinuation<Data?, Never>?
    private var finished = false

    init(cap: Int64) {
        self.cap = cap
        self.collector = CappedDataCollector(cap: cap)
    }

    func download(_ url: URL, using session: URLSession) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.dataTask(with: url).resume()
        }
    }

    /// Resumes the awaiting continuation exactly once; later calls are ignored. (A cap abort
    /// resumes with `nil`, then the resulting cancellation error's `didComplete` is a no-op.)
    private func finish(with result: Data?) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(with: nil)
            return
        }
        // Honour an advertised oversized Content-Length up front when present.
        if response.expectedContentLength > 0, response.expectedContentLength > cap {
            completionHandler(.cancel)
            finish(with: nil)
            return
        }
        if response.expectedContentLength > 0 {
            lock.lock()
            collector.reserve(Int(min(response.expectedContentLength, cap)))
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let ok = collector.append(data)
        lock.unlock()
        if !ok {
            dataTask.cancel()
            finish(with: nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            finish(with: nil)
            return
        }
        lock.lock()
        let result: Data? = collector.exceededCap ? nil : collector.data
        lock.unlock()
        finish(with: result)
    }
}
