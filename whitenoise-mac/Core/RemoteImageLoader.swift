import AppKit
import ImageIO
import SwiftUI

/// An NSImage wrapper that is safe to hand back from the background loader.
nonisolated struct LoadedImage: @unchecked Sendable {
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
nonisolated enum RemoteImageURLPolicy {
    /// Maximum bytes we are willing to download for a single remote image. A malicious URL can
    /// otherwise serve an arbitrarily large response. 8 MiB is generous for an avatar/preview.
    static let maxResponseBytes: Int64 = 8 * 1024 * 1024

    /// Maximum idle gap between received response chunks. `URLSession` resets this timer on
    /// progress, so it bounds a stalled peer but is not a total download-duration ceiling.
    static let downloadStallTimeout: TimeInterval = 15

    /// Hard wall-clock ceiling for one remote image fetch, even if a peer keeps slow-dripping
    /// bytes under the response-size cap and never trips the per-request stall timeout.
    static let downloadResourceTimeout: TimeInterval = 60

    /// Returns true if `url` is safe to fetch: `https`, no embedded userinfo, and a non-empty,
    /// public host.
    ///
    /// "Public host" means the host is not a literal private/loopback/link-local/unspecified
    /// IP address and not an obvious local hostname (`localhost`, `*.localhost`, `*.local`). This
    /// is the SSRF guard: attacker-controlled avatar URLs must not be able to reach the viewer's
    /// internal network.
    ///
    /// Limitation (documented, not silently ignored): a *public-looking* DNS hostname can still
    /// resolve to a private IP (DNS rebinding), because `URLSession` performs its own resolution
    /// after this check and we do not pin the resolved address at connection time. Closing that
    /// fully requires a custom resolver / connection-time re-validation, which is a much larger
    /// change; this policy deterministically closes the directly-exploitable literal-IP and
    /// local-hostname vectors (which is what the attacker can set without controlling DNS).
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        // Reject embedded userinfo before host-based checks. A peer-controlled
        // avatar URL like `https://trusted.example@evil.example` connects to
        // `evil.example` but reads as the trusted host to a human.
        guard url.user == nil, url.password == nil else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        guard !isDisallowedHost(host) else { return false }
        return true
    }

    /// Whether `host` must be rejected because it names an internal/non-public destination:
    /// a private/loopback/link-local/unspecified literal IP, or a local hostname.
    static func isDisallowedHost(_ host: String) -> Bool {
        // `URL.host` does not lowercase or strip IPv6 brackets in all cases; normalize defensively.
        // Strip absolute-FQDN trailing dots so localhost./*.local./127.0.0.1. are checked
        // against the same local-hostname and literal-IP rules as their unrooted forms.
        var normalized = host.lowercased()
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }

        if normalized.isEmpty { return true }

        // RFC 6761 reserves the entire `.localhost` namespace for loopback; mDNS `.local` names
        // resolve on the local link only.
        if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized.hasSuffix(".local") {
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
    /// `0.0.0.0/8`, private `10.0.0.0/8` / `172.16.0.0/12` / `192.168.0.0/16`,
    /// link-local `169.254.0.0/16`, CGNAT `100.64.0.0/10`, and the non-routable top of the
    /// space: multicast `224.0.0.0/4`, reserved `240.0.0.0/4`, and limited broadcast
    /// `255.255.255.255` (all covered by first octet `224...255`).
    private static func isPrivateIPv4(_ octets: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (a, b, _, _) = octets
        switch a {
        case 0, 127, 10:
            return true
        case 100 where (64...127).contains(b):
            return true
        case 172 where (16...31).contains(b):
            return true
        case 192 where b == 168:
            return true
        case 169 where b == 254:
            return true
        case 224...:
            return true
        default:
            return false
        }
    }

    /// Rejects IPv6 literals in non-public ranges: unspecified `::`, loopback `::1`,
    /// ULA `fc00::/7`, link-local `fe80::/10`, multicast `ff00::/8`, documentation
    /// `2001:db8::/32`, RFC 8215 local-use translation `64:ff9b:1::/48`, and the IPv4-embedding
    /// forms (mapped `::ffff:a.b.c.d`, translated `::ffff:0:a.b.c.d`, NAT64 `64:ff9b::a.b.c.d`,
    /// and IPv4-compatible `::a.b.c.d`, 6to4 `2002::/16`, and Teredo `2001:0000::/32`) whose embedded
    /// IPv4 is itself private.
    private static func isPrivateIPv6(_ groups: [UInt16]) -> Bool {
        guard groups.count == 8 else { return true }  // be conservative on anything unparseable

        // Unspecified `::` and loopback `::1` only — `::2`–`::ffff` are IPv4-compatible forms
        // of `0.0.0.0/8` and must fall through to the embedded-IPv4 re-check below.
        if groups[0...6].allSatisfy({ $0 == 0 }), groups[7] <= 1 {
            return true
        }

        let first = groups[0]
        // ULA fc00::/7 — top 7 bits == 1111110.
        if (first & 0xFE00) == 0xFC00 { return true }
        // Link-local fe80::/10 — top 10 bits == 1111111010.
        if (first & 0xFFC0) == 0xFE80 { return true }
        // Multicast ff00::/8, mirroring the IPv4 `224.0.0.0/4` rejection.
        if (first & 0xFF00) == 0xFF00 { return true }
        // Documentation range 2001:db8::/32 — reserved, never a real destination.
        if first == 0x2001, groups[1] == 0x0DB8 { return true }

        // IPv4-mapped `::ffff:a.b.c.d` (and IPv4-compatible `::a.b.c.d`): re-check the
        // embedded IPv4 against the private ranges so `[::ffff:192.168.0.1]` is rejected too.
        if groups[0...4].allSatisfy({ $0 == 0 }), groups[5] == 0xFFFF {
            return isPrivateIPv4(embeddedIPv4(groups))
        }
        // IPv4-translated `::ffff:0:a.b.c.d`.
        if groups[0...3].allSatisfy({ $0 == 0 }), groups[4] == 0xFFFF, groups[5] == 0 {
            return isPrivateIPv4(embeddedIPv4(groups))
        }
        // NAT64 well-known prefix `64:ff9b::a.b.c.d`.
        if groups[0] == 0x64, groups[1] == 0xFF9B, groups[2...5].allSatisfy({ $0 == 0 }) {
            return isPrivateIPv4(embeddedIPv4(groups))
        }
        // RFC 8215 local-use translation prefix `64:ff9b:1::/48` (distinct from the /96 above).
        if groups[0] == 0x64, groups[1] == 0xFF9B, groups[2] == 0x0001 {
            return true
        }
        if groups[0...5].allSatisfy({ $0 == 0 }), groups[6] != 0 || groups[7] != 0 {
            return isPrivateIPv4(embeddedIPv4(groups))
        }
        // 6to4 `2002:WWXX:YYZZ::/16` — the next two groups are the gateway IPv4 literal.
        if first == 0x2002 {
            return isPrivateIPv4(ipv4FromGroups(groups[1], groups[2]))
        }
        // Teredo `2001:0000::/32` — server IPv4 in groups 2–3 (literal), client IPv4 in
        // groups 6–7 XOR'd with `0xFFFF` per 16-bit group (RFC 4380).
        if first == 0x2001, groups[1] == 0x0000 {
            if isPrivateIPv4(ipv4FromGroups(groups[2], groups[3])) { return true }
            if isPrivateIPv4(ipv4FromGroups(groups[6] ^ 0xFFFF, groups[7] ^ 0xFFFF)) { return true }
            return false
        }

        return false
    }

    private static func ipv4FromGroups(_ high: UInt16, _ low: UInt16) -> (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(high >> 8), UInt8(high & 0xFF), UInt8(low >> 8), UInt8(low & 0xFF))
    }

    private static func embeddedIPv4(_ groups: [UInt16]) -> (UInt8, UInt8, UInt8, UInt8) {
        ipv4FromGroups(groups[6], groups[7])
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
nonisolated enum IPAddress {
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

/// Pixel sizing helpers shared by downsampled image views and tests.
nonisolated enum DownsampledImageSizing {
    static func requestedPixelSize(_ maxPixelSize: CGFloat) -> CGFloat {
        max(1, ceil(maxPixelSize))
    }

    /// Ceiling on the zoom-driven half of the gallery budget. A 4x pinch on a large window
    /// would otherwise ask ImageIO to materialize a bitmap several times the size of anything
    /// a chat photo actually contains, for detail the source does not have.
    static let maximumGalleryPixelSize: CGFloat = 8192

    /// Buckets continuously-changing gallery sizes so drag-resizing a window does not create a
    /// fresh decoded cache entry for every pixel delta. Rounds up to avoid under-resolving.
    ///
    /// `zoomScale` raises the budget while the viewer is magnified. Without it a zoom would
    /// simply enlarge the fit-sized decode and go soft exactly when the user is looking closest.
    static func galleryPixelSize(
        for pointSize: CGSize,
        displayScale: CGFloat,
        zoomScale: CGFloat = 1
    ) -> CGFloat {
        let rawPixels = max(pointSize.width, pointSize.height) * max(1, displayScale)
        let bucketSize: CGFloat = 128
        let fitted = max(bucketSize, ceil(rawPixels / bucketSize) * bucketSize)
        guard zoomScale > 1 else { return fitted }
        // `max(fitted, …)` keeps the cap from ever *lowering* resolution on a display whose
        // fitted decode is already past it: the ceiling bounds growth, it is not a target.
        return max(fitted, min(fitted * zoomPixelMultiplier(for: zoomScale), maximumGalleryPixelSize))
    }

    /// Rounds a live zoom scale to the handful of resolutions worth decoding at.
    ///
    /// Feeding the raw scale in would cross a new 128px bucket several dozen times over a
    /// single pinch, re-decoding at each one. Powers of two mean at most two refinements
    /// between fit and 4x, and every step stays a multiple of the bucket size.
    static func zoomPixelMultiplier(for zoomScale: CGFloat) -> CGFloat {
        guard zoomScale.isFinite else { return 1 }
        switch zoomScale {
        case ..<1.5: return 1
        case ..<3: return 2
        default: return 4
        }
    }

    /// Wraps a downsampled `CGImage` in an `NSImage` that reports the CGImage's *true* pixel
    /// dimensions.
    ///
    /// `NSImage(cgImage:size:)` would instead attach an `NSCGImageSnapshotRep` whose
    /// `pixelsWide`/`pixelsHigh` are derived from the point size times the main display's
    /// backing scale — 2× on Retina. That makes a 148px thumbnail report 296px, which both
    /// inflates decoded-cost accounting (over-counting decoded bytes 4×, so the bounded cache
    /// evicts far too aggressively) and silently overshoots the documented max-pixel budget.
    /// Building from an `NSBitmapImageRep` preserves the real pixel count regardless of which
    /// display the decode happens to run on.
    static func image(fromDownsampled cgImage: CGImage) -> NSImage {
        let representation = NSBitmapImageRep(cgImage: cgImage)
        let image = NSImage(size: NSSize(width: cgImage.width, height: cgImage.height))
        image.addRepresentation(representation)
        return image
    }
}

/// Identifies what a `DownsampledAsyncImage` is being asked to show. The decoded-image cache is
/// keyed by URL *and* pixel budget, so both belong here: two views of the same picture at
/// different sizes hold different decodes.
nonisolated struct DownsampledImageTaskKey: Equatable {
    let url: URL?
    let size: CGFloat
}

/// The `DownsampledDataImage` equivalent, for bytes that are already local.
nonisolated struct DownsampledDataImageTaskKey: Equatable {
    let payloadID: String
    let size: CGFloat
}

/// Gates a loaded image on the key it was loaded for.
///
/// `.task(id:)` restarts when its id changes — but it changes the *task*, not the view's identity.
/// SwiftUI carries `@State` across the change and evaluates `body` for the new id first, so a view
/// that is rebound to a new subject (the conversation header avatar when the selected chat
/// changes, a picker tile rebound to a new search hit) would draw the *previous* subject's image
/// for a pass, before `loadImage(for:)` ran and cleared it. Reading the loaded image through this
/// gate makes that pass fall back instead — to whatever the shared cache already holds for the new
/// key, or to the placeholder.
nonisolated enum DownsampledImageGate {
    /// - Returns: `value`, but only when it was loaded for the key the view is currently showing.
    static func value<Value, Key: Equatable>(
        _ value: Value?,
        loadedFor loadedKey: Key?,
        showing currentKey: Key
    ) -> Value? {
        loadedKey == currentKey ? value : nil
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
    @State private var loadedKey: DownsampledImageTaskKey?

    var body: some View {
        ZStack {
            if let image = loadedImage ?? alreadyDecodedImage {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: taskKey) {
            await loadImage(for: taskKey)
        }
    }

    private var taskKey: DownsampledImageTaskKey {
        DownsampledImageTaskKey(url: url, size: DownsampledImageSizing.requestedPixelSize(maxPixelSize))
    }

    /// The image this view loaded, but only while it still describes what the view is showing.
    ///
    /// See `DownsampledImageGate` for why reading `image` directly draws the previous subject.
    private var loadedImage: Image? {
        DownsampledImageGate.value(image, loadedFor: loadedKey, showing: taskKey)
    }

    /// The decoded image for this URL and size when the shared cache is already holding one.
    ///
    /// `.task` cannot run before the first frame, so a view that appears with a warm cache entry
    /// draws its placeholder once anyway — for an avatar that is a visible flash of initials over
    /// an image the process has in memory. Reading the cache synchronously closes that gap. `??`
    /// short-circuits, so this is reached only on the frames that have nothing else to draw: the
    /// first one, and the rebind pass where `loadedImage` is gated off. A miss costs one lookup.
    private var alreadyDecodedImage: Image? {
        guard let url = taskKey.url,
            let loaded = RemoteImageLoader.shared.decodedImage(for: url, maxPixelSize: taskKey.size)
        else { return nil }
        return Image(nsImage: loaded.nsImage)
    }

    /// Loads the image for `taskKey`, keeping `image` and `loadedKey` in step.
    ///
    /// The two always move together, so `loadedKey` describes exactly what `image` holds: a key
    /// change drops both up front, and only a completed load sets both. A reload for the key
    /// already on screen keeps the existing image if it fails, rather than flashing a placeholder.
    @MainActor
    private func loadImage(for taskKey: DownsampledImageTaskKey) async {
        if loadedKey != taskKey {
            loadedKey = nil
            image = nil
        }

        guard let url = taskKey.url else { return }

        if let loaded = await RemoteImageLoader.shared.image(for: url, maxPixelSize: taskKey.size) {
            guard !Task.isCancelled else { return }
            loadedKey = taskKey
            image = Image(nsImage: loaded.nsImage)
        }
    }
}

/// Downsamples already-local image bytes off the main actor and reuses the shared decoded-image
/// cache. This is for decrypted/local attachments where the bytes are already available; decoding
/// with `NSImage(data:)` in a SwiftUI `body` would synchronously inflate the full-resolution bitmap
/// every time Observation re-evaluates the view.
struct DownsampledDataImage<Content: View, Placeholder: View>: View {
    let payload: DownloadedMediaPayload
    let maxPixelSize: CGFloat
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: Image?
    @State private var loadedKey: DownsampledDataImageTaskKey?

    var body: some View {
        ZStack {
            if let image = loadedImage {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: taskKey) {
            await loadImage(for: taskKey)
        }
    }

    private var taskKey: DownsampledDataImageTaskKey {
        DownsampledDataImageTaskKey(
            payloadID: payload.id,
            size: DownsampledImageSizing.requestedPixelSize(maxPixelSize)
        )
    }

    /// The image this view loaded, but only while it still describes what the view is showing.
    ///
    /// See `DownsampledImageGate`. This one has no shared-cache fallback to soften a stale pass,
    /// so without the gate a rebound view draws the previous payload's image outright.
    private var loadedImage: Image? {
        DownsampledImageGate.value(image, loadedFor: loadedKey, showing: taskKey)
    }

    @MainActor
    private func loadImage(for taskKey: DownsampledDataImageTaskKey) async {
        if loadedKey != taskKey {
            loadedKey = nil
            image = nil
        }

        if let loaded = await RemoteImageLoader.shared.image(
            for: payload,
            maxPixelSize: taskKey.size
        ) {
            guard !Task.isCancelled else { return }
            loadedKey = taskKey
            image = Image(nsImage: loaded.nsImage)
        }
    }
}

/// Shared decoded-image cache + downsampling pipeline. `NSCache` owns the decoded-image
/// storage; in-flight work is coordinated by `RemoteImageLoadRegistry` so concurrent views
/// that need the same URL/size await one download and decode.
private nonisolated final class RemoteImageLoadRegistry: @unchecked Sendable {
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

    func cancelAll() {
        let tasksToCancel: [Task<LoadedImage?, Never>]

        lock.lock()
        tasksToCancel = tasks.values.map(\.task)
        tasks.removeAll()
        lock.unlock()

        tasksToCancel.forEach { $0.cancel() }
    }

    func cancelAll(forKeyPrefix prefix: String) {
        let tasksToCancel: [Task<LoadedImage?, Never>]

        lock.lock()
        let matchingKeys = tasks.keys.filter { $0.hasPrefix(prefix) }
        tasksToCancel = matchingKeys.compactMap { tasks.removeValue(forKey: $0)?.task }
        lock.unlock()

        tasksToCancel.forEach { $0.cancel() }
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
private nonisolated final class RemoteImageLoadWaiter: @unchecked Sendable {
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
    private enum CacheScope: String, CaseIterable {
        case remote
        case local
    }

    /// Source bytes the app itself established at a remote URL, held so the first display of
    /// that URL does not have to fetch what the process already has. See `primeRemoteImage`.
    private struct PrimedSource {
        let url: String
        let data: Data
    }

    static let shared = RemoteImageLoader()
    static let defaultDecodedCacheCountLimit = 512
    static let defaultDecodedCacheTotalCostLimit = 64 * 1024 * 1024

    /// How many primed images to keep source bytes for, oldest evicted first. A handful covers
    /// setting a picture on more than one account in a sitting; the point of the bound is that a
    /// long session cannot accumulate them.
    static let primedSourceLimit = 4

    private let cache = NSCache<NSString, NSImage>()
    private let inFlight = RemoteImageLoadRegistry()
    private let cacheStateLock = NSLock()
    private var cacheGenerations: [CacheScope: Int] = [.remote: 0, .local: 0]
    private var localCacheKeys = Set<String>()
    private var primedSources: [PrimedSource] = []
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
        config.timeoutIntervalForRequest = RemoteImageURLPolicy.downloadStallTimeout
        config.timeoutIntervalForResource = RemoteImageURLPolicy.downloadResourceTimeout
        config.requestCachePolicy = .useProtocolCachePolicy
        return config
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> LoadedImage? {
        // Defense-in-depth: never fetch a URL that fails the policy, even if a caller forgot
        // to sanitize. This is the network chokepoint for all remote image loads.
        guard RemoteImageURLPolicy.isAllowed(url) else { return nil }

        return await coalescedLoad(
            scope: .remote,
            cacheKey: Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        ) {
            [self] cacheKey, generation in
            await loadRemoteImage(
                for: url,
                cacheKey: cacheKey,
                maxPixelSize: maxPixelSize,
                cacheGeneration: generation
            )
        }
    }

    /// Returns bounded source bytes for a user-selected web image. This deliberately reuses the
    /// avatar loader's pinned-address, redirect, timeout, and response-size protections before the
    /// caller hands plaintext to MarmotKit for encrypted Blossom upload.
    func data(for url: URL) async -> Data? {
        guard RemoteImageURLPolicy.isAllowed(url) else { return nil }
        return await Self.download(url, using: session)
    }

    /// Registers source bytes the app already holds for `url`, so the first load of that URL
    /// decodes from memory instead of fetching it.
    ///
    /// This exists for one narrow case: the profile picture the user just chose. The app uploaded
    /// those exact bytes to a Blossom server, took the URL the upload returned, and put it on the
    /// account — at which point every avatar on screen asked the network for an image the process
    /// was still holding, and drew initials for the length of a round trip (longer while the
    /// server is still making a freshly uploaded blob available). This is not a general
    /// cache-warming hook: prime only bytes whose identity at `url` the app itself established,
    /// because a wrong pairing here shows one image under another's URL for the whole session.
    ///
    /// Priming widens neither what may be fetched nor what may be drawn. `image(for:)` still
    /// applies `RemoteImageURLPolicy` before it looks here, so a disallowed URL stays unloadable,
    /// and the consent half of the decision stays with `RemoteImageDisplayPolicy` at the call
    /// site. Oversized bodies are rejected so `primedSourceLimit` bounds memory and not just a
    /// count, and `clearCache()` drops these bytes along with the decoded images.
    func primeRemoteImage(url: URL, data: Data) {
        guard RemoteImageURLPolicy.isAllowed(url), !data.isEmpty,
            Int64(data.count) <= RemoteImageURLPolicy.maxResponseBytes
        else { return }

        cacheStateLock.lock()
        defer { cacheStateLock.unlock() }
        primedSources.removeAll { $0.url == url.absoluteString }
        primedSources.append(PrimedSource(url: url.absoluteString, data: data))
        if primedSources.count > Self.primedSourceLimit {
            primedSources.removeFirst(primedSources.count - Self.primedSourceLimit)
        }
    }

    /// The decoded image for `url` at `maxPixelSize` if the cache is already holding one.
    ///
    /// Synchronous, so a view can draw a warm entry on its first frame rather than flashing its
    /// placeholder for one pass of the async load. A miss returns nil and starts nothing.
    func decodedImage(for url: URL, maxPixelSize: CGFloat) -> LoadedImage? {
        guard RemoteImageURLPolicy.isAllowed(url),
            let cached = cachedImage(for: Self.cacheKey(for: url, maxPixelSize: maxPixelSize))
        else { return nil }
        return LoadedImage(nsImage: cached)
    }

    /// Downsamples and caches local/decrypted image bytes.
    ///
    /// The cache key is part of the decoded-image identity and is checked before looking at
    /// `data`, so callers must provide a stable key that uniquely identifies the bytes (for
    /// example an immutable attachment id, or a content fingerprint when ids can be reused).
    func image(for data: Data, cacheKey rawCacheKey: String, maxPixelSize: CGFloat) async -> LoadedImage? {
        return await coalescedLoad(
            scope: .local,
            cacheKey: Self.cacheKey(forLocalImageID: rawCacheKey, maxPixelSize: maxPixelSize)
        ) {
            [self] cacheKey, generation in
            await loadLocalImage(
                data: data,
                cacheKey: cacheKey,
                maxPixelSize: maxPixelSize,
                cacheGeneration: generation,
                scope: .local
            )
        }
    }

    /// Downsamples and caches a decrypted/local media payload without storing the raw bytes in
    /// SwiftUI view values. The payload id is generated when the download completes, so a retry or
    /// replacement under the same attachment id cannot reuse a stale decoded image.
    func image(for payload: DownloadedMediaPayload, maxPixelSize: CGFloat) async -> LoadedImage? {
        return await coalescedLoad(
            scope: .local,
            cacheKey: Self.cacheKey(forLocalImageID: payload.id, maxPixelSize: maxPixelSize)
        ) {
            [self] cacheKey, generation in
            await loadLocalImage(
                data: payload.data,
                cacheKey: cacheKey,
                maxPixelSize: maxPixelSize,
                cacheGeneration: generation,
                scope: .local
            )
        }
    }

    /// Shared decode-coalescing front end for every `image(for:)` entry point: serve a cached
    /// decode if present, otherwise join (or start) the single in-flight decode for `cacheKey`
    /// and tear its waiter down on completion or cancellation. `load` performs the actual
    /// decode for a cache miss, receiving the resolved cache key and the cache generation it
    /// must still belong to.
    private func coalescedLoad(
        scope: CacheScope,
        cacheKey key: String,
        load: @escaping @Sendable (_ cacheKey: String, _ cacheGeneration: Int) async -> LoadedImage?
    ) async -> LoadedImage? {
        if let cached = cachedImage(for: key) {
            return LoadedImage(nsImage: cached)
        }

        let generation = currentCacheGeneration(for: scope)
        let taskKey = Self.inFlightKey(scope: scope, forCacheKey: key, generation: generation)
        let task = inFlight.task(for: taskKey) {
            Task {
                await load(key, generation)
            }
        }
        let waiter = RemoteImageLoadWaiter { [inFlight] in
            inFlight.releaseWaiter(for: taskKey)
        }

        return await withTaskCancellationHandler {
            let loaded = await task.value
            waiter.release()
            return Task.isCancelled ? nil : loaded
        } onCancel: {
            waiter.release()
        }
    }

    /// Drops every decoded image held in memory and invalidates in-flight decodes/downloads.
    /// Decoded avatars derive from attacker-controlled peer Nostr `picture` URLs, so the privacy
    /// wipe paths (account removal reset and full local-data reset) must evict them rather than
    /// letting them linger in the process for its lifetime. See whitenoise-mac#177.
    func clearCache() {
        inFlight.cancelAll()

        cacheStateLock.lock()
        for scope in CacheScope.allCases {
            cacheGenerations[scope, default: 0] += 1
        }
        cache.removeAllObjects()
        localCacheKeys.removeAll(keepingCapacity: true)
        // The privacy wipes this serves must not leave the user's own uploaded picture behind
        // in the process either, and a primed URL that outlived its account would go on serving
        // bytes no fetch could have produced.
        primedSources.removeAll()
        cacheStateLock.unlock()
    }

    /// Drops only decoded local/decrypted attachment images and their in-flight decodes. Remote
    /// profile images remain warm; clearing the media cache should not create unrelated network
    /// traffic for avatars that are still valid for the active account.
    func clearLocalCache() {
        inFlight.cancelAll(forKeyPrefix: "\(CacheScope.local.rawValue)|")

        cacheStateLock.lock()
        cacheGenerations[.local, default: 0] += 1
        for key in localCacheKeys {
            cache.removeObject(forKey: key as NSString)
        }
        localCacheKeys.removeAll(keepingCapacity: true)
        cacheStateLock.unlock()
    }

    #if DEBUG
        func primedSourceByteCount(for url: URL) -> Int? {
            primedSource(for: url)?.count
        }

        func inFlightWaiterCount(for url: URL, maxPixelSize: CGFloat) -> Int {
            inFlight.waiterCount(
                for: Self.inFlightKey(
                    scope: .remote,
                    forCacheKey: Self.cacheKey(for: url, maxPixelSize: maxPixelSize),
                    generation: currentCacheGeneration(for: .remote)
                )
            )
        }
    #endif

    private static func cacheKey(for url: URL, maxPixelSize: CGFloat) -> String {
        "remote|\(url.absoluteString)|\(Int(maxPixelSize))"
    }

    private static func cacheKey(forLocalImageID cacheID: String, maxPixelSize: CGFloat) -> String {
        "local|\(cacheID)|\(Int(maxPixelSize))"
    }

    private static func inFlightKey(scope: CacheScope, forCacheKey cacheKey: String, generation: Int) -> String {
        "\(scope.rawValue)|\(generation)|\(cacheKey)"
    }

    private func loadRemoteImage(
        for url: URL,
        cacheKey: String,
        maxPixelSize: CGFloat,
        cacheGeneration generation: Int
    ) async -> LoadedImage? {
        let source: Data
        if let primed = primedSource(for: url) {
            source = primed
        } else {
            guard let downloaded = await Self.download(url, using: session) else { return nil }
            source = downloaded
        }
        guard !Task.isCancelled, isCurrentCacheGeneration(generation, for: .remote) else { return nil }
        return await loadLocalImage(
            data: source,
            cacheKey: cacheKey,
            maxPixelSize: maxPixelSize,
            cacheGeneration: generation,
            scope: .remote
        )
    }

    private func loadLocalImage(
        data: Data,
        cacheKey: String,
        maxPixelSize: CGFloat,
        cacheGeneration generation: Int,
        scope: CacheScope
    ) async -> LoadedImage? {
        let pixelSize = maxPixelSize
        let loaded = await Task.detached(priority: .utility) {
            Self.downsample(data: data, maxPixelSize: pixelSize).map(LoadedImage.init)
        }.value
        guard let loaded else { return nil }
        guard !Task.isCancelled else { return nil }
        guard
            storeDecodedImage(
                loaded.nsImage,
                forKey: cacheKey,
                cacheGeneration: generation,
                scope: scope
            )
        else {
            return nil
        }
        return loaded
    }

    private func primedSource(for url: URL) -> Data? {
        cacheStateLock.lock()
        defer { cacheStateLock.unlock() }
        return primedSources.last { $0.url == url.absoluteString }?.data
    }

    private func cachedImage(for key: String) -> NSImage? {
        cacheStateLock.lock()
        defer { cacheStateLock.unlock() }
        return cache.object(forKey: key as NSString)
    }

    private func currentCacheGeneration(for scope: CacheScope) -> Int {
        cacheStateLock.lock()
        defer { cacheStateLock.unlock() }
        return cacheGenerations[scope, default: 0]
    }

    private func isCurrentCacheGeneration(_ generation: Int, for scope: CacheScope) -> Bool {
        cacheStateLock.lock()
        defer { cacheStateLock.unlock() }
        return cacheGenerations[scope, default: 0] == generation
    }

    private func storeDecodedImage(
        _ image: NSImage,
        forKey key: String,
        cacheGeneration generation: Int,
        scope: CacheScope
    ) -> Bool {
        cacheStateLock.lock()
        defer { cacheStateLock.unlock() }
        guard cacheGenerations[scope, default: 0] == generation else { return false }
        cache.setObject(image, forKey: key as NSString, cost: Self.decodedCost(for: image))
        if scope == .local {
            localCacheKeys.insert(key)
            // NSCache does not expose evicted keys. Periodically discard stale bookkeeping so a
            // long session that views many attachments cannot grow this index without bound.
            if cache.countLimit > 0, localCacheKeys.count / 2 > cache.countLimit {
                localCacheKeys = localCacheKeys.filter {
                    cache.object(forKey: $0 as NSString) != nil
                }
            }
        }
        return true
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

    /// Decoded-pixel ceiling for one source image — a small compressed body can declare
    /// enormous dimensions, and the thumbnail pass materializes the full-size bitmap first.
    private static let maxSourceImagePixels = 64_000_000

    private static func downsample(data: Data, maxPixelSize: CGFloat) -> NSImage? {
        // Stamped with the encoded byte count so a slow decode is correlatable with the
        // source image's weight. Runs off-main (`Task.detached(.utility)`), but if it
        // backs up it starves media tiles from displaying mid-scroll.
        TimelineSignpost.decode.interval("downsample", count: data.count) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
            // Header-only dimension read, rejecting decompression bombs before any decode.
            guard
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
                    as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0,
                // Division form, a hostile header can carry dimensions whose product overflows.
                height <= maxSourceImagePixels / width
            else { return nil }
            let options =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(max(1, maxPixelSize)),
                ] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return DownsampledImageSizing.image(fromDownsampled: cgImage)
        }
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
nonisolated struct CappedDataCollector {
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
    private var redirectHopCount = 0

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
        let hopCount = lock.withLock {
            redirectHopCount += 1
            return redirectHopCount
        }
        if hopCount > 5 {
            completionHandler(nil)
            task.cancel()
            finish(with: nil)
            return
        }
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
