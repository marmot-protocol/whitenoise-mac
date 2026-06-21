import AppKit
import ImageIO
import SwiftUI

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
        // A fresh per-download delegate keeps per-download collector state isolated (multiple
        // avatars can download concurrently). The delegate is attached to the *task*, not a new
        // session (see `CappedImageDownloadDelegate.download`), so every download runs on the
        // shared `session` and reuses its connection pool + `URLCache` instead of paying a fresh
        // DNS/TCP/TLS handshake and churning a throwaway `URLSession` per image.
        let delegate = CappedImageDownloadDelegate(cap: cap)
        return await delegate.download(url, using: session)
    }

    private static func downsample(data: Data, maxPixelSize: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(1, maxPixelSize)),
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
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var finished = false

    init(cap: Int64) {
        self.cap = cap
        self.collector = CappedDataCollector(cap: cap)
    }

    func download(_ url: URL, using session: URLSession) async -> Data? {
        // Propagate Swift task cancellation to the underlying network request. The
        // `DownsampledAsyncImage` call site runs this inside a `.task(id:)`, which cancels the
        // awaiting task whenever the row's URL/size identity changes (scrolling, navigation);
        // without this the request would keep running and buffering until it completed or timed
        // out. (The native `URLSession.bytes(from:)` API we replaced did this automatically.)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                let task = session.dataTask(with: url)
                // Attach *this* delegate per task (macOS 12+) rather than backing a throwaway
                // per-download `URLSession`. This keeps per-download collector state isolated
                // while letting the shared `session` reuse its connection pool across avatars.
                task.delegate = self
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    /// Cancels the in-flight data task (if any) and resolves the awaiting continuation with
    /// `nil`. Safe to call before the task is created (the `cancelled` flag short-circuits
    /// `download`) and idempotent (later calls are no-ops once `finished`).
    private func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(with: nil)
    }

    /// Resumes the awaiting continuation exactly once; later calls are ignored. (A cap abort
    /// resumes with `nil`, then the resulting cancellation error's `didComplete` is a no-op.)
    private func finish(with result: Data?) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: result)
    }

    /// Re-validate redirect targets against the privacy policy. `URLSession` follows redirects
    /// automatically by default, so without this an allowed `https://` avatar could 3xx-redirect
    /// to `http://` (or another disallowed scheme/host), defeating the HTTPS-only,
    /// IP-leak-limiting `RemoteImageURLPolicy` check applied to the original URL.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, RemoteImageURLPolicy.isAllowed(url) else {
            completionHandler(nil)
            task.cancel()
            finish(with: nil)
            return
        }
        completionHandler(request)
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
