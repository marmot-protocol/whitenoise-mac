//
//  TimelineSignposts.swift
//  whitenoise-mac
//
//  os_signpost instrumentation for the chat-timeline hot paths. These exist so an
//  Instruments "os_signpost" track lines up named, measured intervals against the
//  Hangs / Time Profiler / SwiftUI tracks while scrolling a conversation — turning
//  "the main thread froze somewhere in here" into "this exact stage took N ms".
//
//  All work here is cheap when no Instruments/`log` consumer is attached: an
//  `OSSignposter` with no listener short-circuits, so these brackets are safe to
//  leave in shipping builds. Categories become separate lanes in Instruments.
//
//  Coverage (see the call sites):
//    • Pagination  — `subscription.paginateBackwards/Forwards` FFI (scroll-back/-forward)
//    • Mapping     — sender resolution + `MessageItem.timeline` (Markdown AST build)
//    • Store       — `replaceMessages` / `applyProjection` transcript mutation
//    • ImageDecode — `RemoteImageLoader.downsample` (CGImageSource thumbnailing)
//

import OSLog

/// Namespaced `OSSignposter`s, one per timeline subsystem stage. A single subsystem
/// with distinct categories keeps everything under one filter in Instruments while
/// still rendering each stage as its own lane.
enum TimelineSignpost {
    static let subsystem = "com.whitenoise.timeline"

    /// Backwards/forwards history paging FFI calls.
    static let pagination = OSSignposter(subsystem: subsystem, category: "Pagination")
    /// Sender-profile resolution and `MessageItem` mapping (incl. Markdown AST build).
    static let mapping = OSSignposter(subsystem: subsystem, category: "Mapping")
    /// `MessageTimelineStore` mutations that feed the rendered window.
    static let store = OSSignposter(subsystem: subsystem, category: "Store")
    /// Off-main image downsampling/decoding for media tiles and avatars.
    static let decode = OSSignposter(subsystem: subsystem, category: "ImageDecode")
    /// Scroll-anchor capture and `ScrollViewProxy.scrollTo` restoration. The expensive
    /// part (SwiftUI's offset re-resolution: `adjustOffsetIfNeeded` / `motionVectors`)
    /// happens in the layout pass *after* `scrollTo` returns, so these markers exist to
    /// timestamp *when* a restore was requested — line them up against the Time Profiler /
    /// SwiftUI tracks to see the layout cost the request triggered. See whitenoise-mac#205.
    static let scroll = OSSignposter(subsystem: subsystem, category: "Scroll")
}

extension OSSignposter {
    /// Brackets a straight-line synchronous operation as a signpost interval.
    ///
    /// NB: pass only code with no early `return`/`break`/`continue` — those would exit
    /// the closure, not the enclosing function. These helpers are intentionally for
    /// single expressions / linear blocks, never whole guard-laden function bodies.
    @discardableResult
    func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = beginInterval(name, id: makeSignpostID())
        defer { endInterval(name, state) }
        return try work()
    }

    /// Synchronous variant that stamps a `count:` onto the interval for correlation
    /// (e.g. how many rows were mapped / how many bytes were decoded).
    @discardableResult
    func interval<T>(_ name: StaticString, count: Int, _ work: () throws -> T) rethrows -> T {
        let state = beginInterval(name, id: makeSignpostID(), "count: \(count)")
        defer { endInterval(name, state) }
        return try work()
    }

    /// Brackets a straight-line `async` operation as a signpost interval. The interval
    /// closes on `defer`, so it is still reported if `work` throws.
    @discardableResult
    func asyncInterval<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let state = beginInterval(name, id: makeSignpostID())
        defer { endInterval(name, state) }
        return try await work()
    }

    /// `async` variant that stamps a `count:` onto the interval.
    @discardableResult
    func asyncInterval<T>(_ name: StaticString, count: Int, _ work: () async throws -> T) async rethrows -> T {
        let state = beginInterval(name, id: makeSignpostID(), "count: \(count)")
        defer { endInterval(name, state) }
        return try await work()
    }
}
