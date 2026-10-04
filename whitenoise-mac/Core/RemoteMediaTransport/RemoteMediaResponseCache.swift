//
//  RemoteMediaResponseCache.swift
//  whitenoise-mac
//
//  The memory-only raw-response cache that replaces the old URLSession `URLCache`. It is a
//  plain value type: `RemoteImageLoader` owns one under its existing cache-state lock and
//  gates insertion on its existing remote cache generation, so `clearCache()` both drops the
//  bytes and refuses any insertion still in flight.
//

import Foundation

nonisolated struct RemoteMediaCacheFreshness: Equatable, Sendable {
    /// How long the response is fresh for, from its origin's point of view.
    let lifetime: Duration
    /// The response's age when it was received (RFC 9111 §4.2.3 `corrected_initial_age`).
    let initialAge: Duration
}

/// Which responses may be cached, and for how long. Conservative by construction: only a
/// complete `200` with *explicit* freshness is ever stored. No heuristic freshness, no
/// revalidation, no stale serving; anything this does not fully understand is not cached.
nonisolated enum RemoteMediaCachePolicy {
    /// Directives that do not change the answer for a private, never-stale, never-revalidating
    /// cache. Any directive outside this set (and outside `max-age`) disables caching.
    static let inertDirectives: Set<String> = [
        "public", "private", "must-revalidate", "proxy-revalidate", "immutable", "no-transform",
        "s-maxage", "stale-while-revalidate", "stale-if-error", "must-understand",
    ]

    /// RFC 9111 §1.2.2: delta-seconds beyond 2^31 are treated as 2^31.
    static let maximumDeltaSeconds: Int64 = 2_147_483_648

    /// - Parameters:
    ///   - wallClockAtResponse: local wall-clock time the response was received.
    ///   - responseDelay: monotonic time between sending the request and receiving the head.
    static func freshness(
        for head: RemoteMediaHTTPResponseHead,
        wallClockAtResponse: Date,
        responseDelay: Duration
    ) -> RemoteMediaCacheFreshness? {
        guard head.statusCode == 200,
            head.values(for: "set-cookie").isEmpty,
            head.values(for: "set-cookie2").isEmpty,
            head.values(for: "vary").isEmpty
        else { return nil }
        for pragma in head.values(for: "pragma") where pragma.lowercased().contains("no-cache") {
            return nil
        }

        var maxAge: Int64?
        for value in head.values(for: "cache-control") {
            for rawDirective in value.split(separator: ",") {
                let directive = rawDirective.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                if directive.isEmpty { continue }
                let parts = directive.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \t")).lowercased()
                switch name {
                case "max-age":
                    guard maxAge == nil, parts.count == 2,
                        let seconds = deltaSeconds(String(parts[1]))
                    else { return nil }
                    maxAge = seconds
                case _ where inertDirectives.contains(name):
                    continue
                default:
                    // no-store, no-cache, and anything unknown.
                    return nil
                }
            }
        }

        let dates = head.values(for: "date")
        let ages = head.values(for: "age")
        guard dates.count <= 1, ages.count <= 1 else { return nil }
        let dateValue: Date
        if let date = dates.first {
            guard let parsed = parseHTTPDate(date) else { return nil }
            dateValue = parsed
        } else {
            dateValue = wallClockAtResponse
        }
        var ageValue: Int64 = 0
        if let age = ages.first {
            guard let parsed = deltaSeconds(age) else { return nil }
            ageValue = parsed
        }

        let lifetime: Duration
        if let maxAge {
            lifetime = .seconds(maxAge)
        } else {
            let expires = head.values(for: "expires")
            guard expires.count == 1, let expiry = parseHTTPDate(expires[0]) else { return nil }
            lifetime = .seconds(expiry.timeIntervalSince(dateValue))
        }
        guard lifetime > .zero else { return nil }

        let apparentAge = Duration.seconds(max(0, wallClockAtResponse.timeIntervalSince(dateValue)))
        let correctedAgeValue = Duration.seconds(ageValue) + max(.zero, responseDelay)
        let initialAge = max(apparentAge, correctedAgeValue)
        guard lifetime > initialAge else { return nil }
        return RemoteMediaCacheFreshness(lifetime: lifetime, initialAge: initialAge)
    }

    /// `1*DIGIT`, optionally quoted, clamped to `maximumDeltaSeconds`.
    static func deltaSeconds(_ raw: String) -> Int64? {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        var value: Int64 = 0
        for byte in text.utf8 {
            value = value * 10 + Int64(byte - 0x30)
            if value >= maximumDeltaSeconds { return maximumDeltaSeconds }
        }
        return value
    }

    /// Parses an IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`). The obsolete RFC 850 and
    /// asctime forms are not accepted; an unparseable `Expires` therefore means "not cached",
    /// which is the conservative reading of RFC 9111 §5.3.
    static func parseHTTPDate(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 29 else { return nil }
        let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func number(_ range: Range<Int>) -> Int? {
            guard bytes[range].allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            return bytes[range].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        }

        guard dayNames.contains(string(0..<3)),
            string(3..<5) == ", ",
            let day = number(5..<7), bytes[7] == 0x20,
            let monthIndex = monthNames.firstIndex(of: string(8..<11)), bytes[11] == 0x20,
            let year = number(12..<16), bytes[16] == 0x20,
            let hour = number(17..<19), bytes[19] == 0x3A,
            let minute = number(20..<22), bytes[22] == 0x3A,
            let second = number(23..<25),
            string(25..<29) == " GMT",
            (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }

        let days = daysFromCivil(year: year, month: monthIndex + 1, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + min(second, 59)
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's algorithm), so
    /// parsing does not depend on locale, time zone, or `DateFormatter` state.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

/// Bounded least-recently-used store of fresh response bodies, keyed by absolute URL.
nonisolated struct RemoteMediaResponseCache {
    static let maximumTotalBytes = 16 * 1024 * 1024
    static let maximumEntryCount = 512

    private struct Entry {
        let body: Data
        let freshness: RemoteMediaCacheFreshness
        let storedAt: ContinuousClock.Instant
        var lastUse: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var useCounter: UInt64 = 0
    private(set) var totalBytes = 0

    init() {}

    var count: Int { entries.count }

    func contains(_ url: URL) -> Bool { entries[url.absoluteString] != nil }

    /// The body for `url` while it is still fresh at `now`. An expired entry is dropped, so the
    /// caller refetches through the pinned transport.
    mutating func body(for url: URL, now: ContinuousClock.Instant) -> Data? {
        let key = url.absoluteString
        guard var entry = entries[key] else { return nil }
        let age = entry.freshness.initialAge + entry.storedAt.duration(to: now)
        guard entry.freshness.lifetime > age else {
            remove(key)
            return nil
        }
        useCounter &+= 1
        entry.lastUse = useCounter
        entries[key] = entry
        return entry.body
    }

    /// Replaces whatever was held for `url`. A `nil` freshness still evicts the old entry: a
    /// newer, uncacheable response supersedes an older cacheable one.
    @discardableResult
    mutating func store(
        _ body: Data,
        for url: URL,
        freshness: RemoteMediaCacheFreshness?,
        now: ContinuousClock.Instant
    ) -> Bool {
        let key = url.absoluteString
        remove(key)
        guard let freshness, body.count <= Self.maximumTotalBytes else { return false }
        while entries.count >= Self.maximumEntryCount || body.count > Self.maximumTotalBytes - totalBytes {
            guard let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            remove(victim)
        }
        useCounter &+= 1
        entries[key] = Entry(body: body, freshness: freshness, storedAt: now, lastUse: useCounter)
        totalBytes += body.count
        return true
    }

    mutating func removeAll() {
        entries.removeAll()
        totalBytes = 0
    }

    private mutating func remove(_ key: String) {
        if let removed = entries.removeValue(forKey: key) {
            totalBytes -= removed.body.count
        }
    }
}
