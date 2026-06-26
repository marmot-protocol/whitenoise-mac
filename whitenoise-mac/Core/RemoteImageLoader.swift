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
/// fetched at all: it requires `https`, a non-empty host, and a host that is not an
/// internal/private/loopback/link-local address (SSRF protection). The *decision to load
/// remote images at all* is gated separately behind a user preference
/// (`WorkspaceState.loadRemoteImages`, default off); this policy is the defense-in-depth check
/// that runs even once the user has opted in.
///
/// SSRF context: profile/avatar `picture` URLs are attacker-controlled (untrusted peer Nostr
/// metadata). Without the address check below, a peer could put `https://192.168.1.1/x.png`,
/// `https://127.0.0.1:8080/x.png`, or `https://[::1]/x.png` in their metadata and steer the
/// viewer's client into probing its own LAN/loopback — a reachability/timing oracle for
/// internal host and port discovery. The same check is applied to every redirect target
/// (`CappedImageDownloadDelegate.willPerformHTTPRedirection`) so a public `https://` avatar
/// cannot 3xx-redirect to an internal host either.
enum RemoteImageURLPolicy {
    /// Maximum bytes we are willing to download for a single remote image. A malicious URL can
    /// otherwise serve an arbitrarily large response. 8 MiB is generous for an avatar/preview.
    static let maxResponseBytes: Int64 = 8 * 1024 * 1024

    /// Returns true if `url` is safe to fetch: `https` scheme with a non-empty, public host.
    ///
    /// "Public host" means the host is not a literal private/loopback/link-local/unspecified
    /// IP address and not an obvious local hostname (`localhost`, `*.local`). This is the SSRF
    /// guard: attacker-controlled avatar URLs must not be able to reach the viewer's internal
    /// network.
    ///
    /// Limitation (documented, not silently ignored): a *public-looking* DNS hostname can still
    /// resolve to a private IP (DNS rebinding), because `URLSession` performs its own resolution
    /// after this check and we do not pin the resolved address at connection time. Closing that
    /// fully requires a custom resolver / connection-time re-validation, which is a much larger
    /// change; this policy deterministically closes the directly-exploitable literal-IP and
    /// local-hostname vectors (which is what the attacker can set without controlling DNS).
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        guard !isDisallowedHost(host) else { return false }
        return true
    }

    /// Whether `host` must be rejected because it names an internal/non-public destination:
    /// a private/loopback/link-local/unspecified literal IP, or a local hostname.
    static func isDisallowedHost(_ host: String) -> Bool {
        // `URL.host` does not lowercase or strip IPv6 brackets in all cases; normalize defensively.
        let normalized =
            host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if normalized.isEmpty { return true }

        // Obvious local hostnames. mDNS `.local` names resolve on the local link only.
        if normalized == "localhost" || normalized.hasSuffix(".local") {
            return true
        }

        if let v4 = IPAddress.parseIPv4(normalized) {
            return isPrivateIPv4(v4)
        }
        if let v6 = IPAddress.parseIPv6(normalized) {
            return isPrivateIPv6(v6)
        }

        // A non-literal hostname (e.g. cdn.example.com). Allowed here; see DNS-rebinding
        // limitation documented on `isAllowed`.
        return false
    }

    /// Rejects IPv4 literals in non-public ranges: loopback `127.0.0.0/8`, "this host"
    /// `0.0.0.0/8`, private `10.0.0.0/8` / `172.16.0.0/12` / `192.168.0.0/16`, and
    /// link-local `169.254.0.0/16`.
    private static func isPrivateIPv4(_ octets: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (a, b, _, _) = octets
        switch a {
        case 0, 127, 10:
            return true
        case 172 where (16...31).contains(b):
            return true
        case 192 where b == 168:
            return true
        case 169 where b == 254:
            return true
        default:
            return false
        }
    }

    /// Rejects IPv6 literals in non-public ranges: unspecified `::`, loopback `::1`,
    /// ULA `fc00::/7`, link-local `fe80::/10`, and IPv4-mapped `::ffff:0:0/96` /
    /// IPv4-compatible addresses whose embedded IPv4 is itself private.
    private static func isPrivateIPv6(_ groups: [UInt16]) -> Bool {
        guard groups.count == 8 else { return true }  // be conservative on anything unparseable

        // Unspecified `::` and loopback `::1`.
        if groups[0...6].allSatisfy({ $0 == 0 }) {
            return groups[7] <= 1
        }

        let first = groups[0]
        // ULA fc00::/7 — top 7 bits == 1111110.
        if (first & 0xFE00) == 0xFC00 { return true }
        // Link-local fe80::/10 — top 10 bits == 1111111010.
        if (first & 0xFFC0) == 0xFE80 { return true }

        // IPv4-mapped `::ffff:a.b.c.d` (and IPv4-compatible `::a.b.c.d`): re-check the
        // embedded IPv4 against the private ranges so `[::ffff:192.168.0.1]` is rejected too.
        if groups[0...4].allSatisfy({ $0 == 0 }), groups[5] == 0xFFFF {
            return isPrivateIPv4(embeddedIPv4(groups))
        }
        if groups[0...5].allSatisfy({ $0 == 0 }), groups[6] != 0 || groups[7] != 0 {
            return isPrivateIPv4(embeddedIPv4(groups))
        }

        return false
    }

    private static func embeddedIPv4(_ groups: [UInt16]) -> (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(groups[6] >> 8), UInt8(groups[6] & 0xFF), UInt8(groups[7] >> 8), UInt8(groups[7] & 0xFF))
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

/// Minimal, dependency-free parser for IPv4/IPv6 *literals* used by the SSRF host check.
///
/// We parse literals ourselves (rather than calling `inet_pton`) so the accepted grammar is
/// explicit and covers the obfuscated IPv4 forms an attacker can use to hide a private address
/// from a naive dotted-quad check — decimal (`2130706433` == `127.0.0.1`), hex (`0x7f000001`),
/// octal (`0177.0.0.1`), and shorthand (`127.1`, `10.0x10`). Anything we cannot interpret as a
/// literal is treated as a hostname by the caller (and allowed, subject to the documented
/// DNS-rebinding limitation), so the parser only needs to recognise literals, not reject names.
enum IPAddress {
    /// Parses an IPv4 literal in any of the BSD `inet_aton` forms into its four octets, or nil
    /// if `value` is not an IPv4 literal at all. Each dotted part may be decimal, hex (`0x..`),
    /// or octal (leading `0`); 1–4 parts are accepted, with the final part filling the remaining
    /// low-order bytes (`a`, `a.b`, `a.b.c`, `a.b.c.d`).
    static func parseIPv4(_ value: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }

        var nums: [UInt64] = []
        nums.reserveCapacity(parts.count)
        for part in parts {
            guard let n = parseUInt(part) else { return nil }
            nums.append(n)
        }

        // Each leading part must fit in one byte; the final part absorbs the remaining bytes.
        for n in nums.dropLast() where n > 0xFF { return nil }
        let maxLast: UInt64
        switch nums.count {
        case 1: maxLast = 0xFFFF_FFFF
        case 2: maxLast = 0xFF_FFFF
        case 3: maxLast = 0xFFFF
        default: maxLast = 0xFF
        }
        guard let last = nums.last, last <= maxLast else { return nil }

        var addr: UInt32 = 0
        for n in nums.dropLast() {
            addr = (addr << 8) | UInt32(n)
        }
        // Shift the leading octets up to make room for the final (multi-byte) part.
        addr <<= UInt32((5 - nums.count) * 8)
        addr |= UInt32(last)

        return (
            UInt8((addr >> 24) & 0xFF),
            UInt8((addr >> 16) & 0xFF),
            UInt8((addr >> 8) & 0xFF),
            UInt8(addr & 0xFF)
        )
    }

    /// Parses an IPv6 literal (with optional `::` compression and an optional trailing
    /// dotted-quad IPv4 tail) into eight 16-bit groups, or nil if not an IPv6 literal.
    static func parseIPv6(_ value: String) -> [UInt16]? {
        // Strip an optional zone id (`fe80::1%en0`) — the address part is all we validate.
        let addr =
            value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        guard addr.contains(":") else { return nil }

        let halves = addr.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func groups(_ s: String) -> [UInt16]? {
            if s.isEmpty { return [] }
            var out: [UInt16] = []
            let pieces = s.split(separator: ":", omittingEmptySubsequences: false)
            for (i, piece) in pieces.enumerated() {
                // A trailing IPv4 tail (e.g. `::ffff:192.168.0.1`) only in the last piece.
                if piece.contains("."), i == pieces.count - 1 {
                    guard let v4 = parseIPv4(String(piece)) else { return nil }
                    out.append((UInt16(v4.0) << 8) | UInt16(v4.1))
                    out.append((UInt16(v4.2) << 8) | UInt16(v4.3))
                    continue
                }
                guard !piece.isEmpty, piece.count <= 4,
                    let v = UInt16(piece, radix: 16)
                else { return nil }
                out.append(v)
            }
            return out
        }

        if halves.count == 2 {
            guard let head = groups(halves[0]), let tail = groups(halves[1]) else { return nil }
            let fill = 8 - head.count - tail.count
            guard fill >= 0 else { return nil }
            return head + Array(repeating: 0, count: fill) + tail
        } else {
            guard let all = groups(addr) else { return nil }
            return all.count == 8 ? all : nil
        }
    }

    /// Parses a single IPv4 part as decimal, hex (`0x`/`0X`), or octal (leading `0`).
    private static func parseUInt(_ part: Substring) -> UInt64? {
        if part.isEmpty { return nil }
        if part.hasPrefix("0x") || part.hasPrefix("0X") {
            let hex = part.dropFirst(2)
            guard !hex.isEmpty else { return nil }
            return UInt64(hex, radix: 16)
        }
        if part.first == "0", part.count > 1 {
            return UInt64(part.dropFirst(), radix: 8)
        }
        return UInt64(part, radix: 10)
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

/// Shared decoded-image cache + downsampling pipeline. `NSCache` owns the decoded-image
/// storage; in-flight work is coordinated by `RemoteImageLoadRegistry` so concurrent views
/// that need the same URL/size await one download and decode.
private final class RemoteImageLoadRegistry: @unchecked Sendable {
    private struct Entry {
        let task: Task<LoadedImage?, Never>
        var waiters: Int
    }

    private let lock = NSLock()
    private var tasks: [String: Entry] = [:]

    func task(
        for key: String,
        create: @Sendable () -> Task<LoadedImage?, Never>
    ) -> Task<LoadedImage?, Never> {
        lock.lock()
        defer { lock.unlock() }

        if var entry = tasks[key] {
            entry.waiters += 1
            tasks[key] = entry
            return entry.task
        }

        // Keep this under the lock so a missing key creates exactly one shared task. Callers
        // must keep `create` cheap and non-reentrant; it should only allocate the download task.
        let task = create()
        tasks[key] = Entry(task: task, waiters: 1)
        return task
    }

    func releaseWaiter(for key: String) {
        var taskToCancel: Task<LoadedImage?, Never>?

        lock.lock()
        if var entry = tasks[key] {
            entry.waiters -= 1
            if entry.waiters <= 0 {
                tasks[key] = nil
                taskToCancel = entry.task
            } else {
                tasks[key] = entry
            }
        }
        lock.unlock()

        taskToCancel?.cancel()
    }

    #if DEBUG
        func waiterCount(for key: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return tasks[key]?.waiters ?? 0
        }
    #endif
}

/// One-shot release latch for a coalesced waiter. Both the cancellation handler and the
/// successful await path may try to release the same waiter; only the first release should
/// decrement the registry count and potentially cancel the shared download.
private final class RemoteImageLoadWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()

        onRelease()
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
        URLSession(configuration: makeSessionConfiguration())
    }

    // Internal so @testable configuration assertions can pin the privacy-sensitive defaults.
    static func makeSessionConfiguration() -> URLSessionConfiguration {
        // Remote image URLs are attacker-controlled peer metadata. Use an ephemeral session and
        // an explicit diskCapacity: 0 URLCache as defense-in-depth so fetched avatar URLs/bodies
        // do not become persistent forensic artifacts in the app Caches directory.
        // .useProtocolCachePolicy lets servers revalidate when a download occurs; decoded NSCache
        // entries may still serve same-session avatars until eviction.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 0,
            diskPath: nil
        )
        config.requestCachePolicy = .useProtocolCachePolicy
        return config
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> LoadedImage? {
        // Defense-in-depth: never fetch a URL that fails the policy, even if a caller forgot
        // to sanitize. This is the network chokepoint for all remote image loads.
        guard RemoteImageURLPolicy.isAllowed(url) else { return nil }

        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            return LoadedImage(nsImage: cached)
        }

        let task = inFlight.task(for: key) { [self] in
            Task { [self] in
                await loadImage(for: url, cacheKey: key, maxPixelSize: maxPixelSize)
            }
        }
        let waiter = RemoteImageLoadWaiter { [inFlight] in
            inFlight.releaseWaiter(for: key)
        }

        return await withTaskCancellationHandler {
            let loaded = await task.value
            waiter.release()
            return Task.isCancelled ? nil : loaded
        } onCancel: {
            waiter.release()
        }
    }

    #if DEBUG
        func inFlightWaiterCount(for url: URL, maxPixelSize: CGFloat) -> Int {
            inFlight.waiterCount(for: Self.cacheKey(for: url, maxPixelSize: maxPixelSize))
        }
    #endif

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
        // shared `session` and reuses its connection pool + in-memory `URLCache` instead of paying
        // a fresh DNS/TCP/TLS handshake and churning a throwaway `URLSession` per image.
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
