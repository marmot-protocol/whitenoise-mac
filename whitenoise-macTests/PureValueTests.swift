//
//  PureValueTests.swift
//  whitenoise-macTests
//
//  Pure, self-contained value-type tests moved out of the serialized
//  suite so they run in parallel (no shared global state).
//

import AppKit
import Combine
import Darwin
import Foundation
import ImageIO
import MarmotKit
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications

@testable import whitenoise_mac

struct PureValueTests {
    @Test func disappearingMessageCustomLabelFormatsCoreUInt64Value() async throws {
        // Regression for whitenoise-mac#212: values can originate from the core as
        // UInt64, and Int(value) traps above Int.max while `%d` truncates large
        // 64-bit values to misleading labels such as "-1 seconds".
        let above32BitSeconds = UInt64(Int32.max) + 1
        let oversizedSeconds = UInt64(Int.max) + 1

        #expect(DisappearingMessageOption.custom(above32BitSeconds).label == "2147483648 seconds")
        #expect(DisappearingMessageOption.custom(oversizedSeconds).label == "9223372036854775808 seconds")
    }

    @Test func mediaDurationLabelClampsNonFiniteAndOversizedDurations() async throws {
        // Regression for whitenoise-mac#253: the audio duration is peer-derived
        // (MediaWaveformAnalyzer -> AVAudioFile.length / sampleRate), so it may be
        // NaN, ±Infinity, or larger than Int.max. Int(_:) traps on any of those, so
        // the label must clamp instead of crashing while rendering an audio row.
        #expect(MediaDurationLabel.string(for: .nan) == "0:00")
        #expect(MediaDurationLabel.string(for: .infinity) == "0:00")
        #expect(MediaDurationLabel.string(for: -.infinity) == "0:00")
        #expect(MediaDurationLabel.string(for: -1) == "0:00")

        // A crafted header can drive the duration above Int.max; clamping to Int.max
        // must not trap and must still format as an hours label. Double(Int.max)
        // rounds up to 2^63, which is > Int.max, so it exercises the clamp path.
        let expected = "2562047788015215:30:07"
        #expect(MediaDurationLabel.string(for: 1e19) == expected)
        #expect(MediaDurationLabel.string(for: Double(Int.max)) == expected)
        #expect(MediaDurationLabel.string(for: .greatestFiniteMagnitude) == expected)

        // Ordinary values keep formatting exactly as before.
        #expect(MediaDurationLabel.string(for: 3_599) == "59:59")
        #expect(MediaDurationLabel.string(for: 3_600) == "1:00:00")
    }

    @Test func messageItemTimelineFallbackClampsPreEpochAndNonFiniteDates() async throws {
        // Regression for whitenoise-mac#247: the timelineAt fallback derives from
        // sentAt via UInt64(_:), which traps on negative (pre-1970) or non-finite
        // dates. The fallback must clamp instead of crashing the initializer.
        func timelineAt(for sentAt: Date) -> UInt64 {
            MessageItem(id: "t", senderName: "s", body: "b", sentAt: sentAt, isOutgoing: false).timelineAt
        }

        // Pre-epoch dates have a negative timeIntervalSince1970 and clamp to 0.
        #expect(timelineAt(for: Date(timeIntervalSince1970: -1)) == 0)
        #expect(timelineAt(for: Date(timeIntervalSince1970: -1_000)) == 0)

        // Non-finite dates also clamp to 0 rather than trapping.
        #expect(timelineAt(for: Date(timeIntervalSince1970: .nan)) == 0)
        #expect(timelineAt(for: Date(timeIntervalSince1970: .infinity)) == 0)
        #expect(timelineAt(for: Date(timeIntervalSince1970: -.infinity)) == 0)

        // Ordinary positive dates floor to their epoch seconds.
        #expect(timelineAt(for: Date(timeIntervalSince1970: 1_700_000_000.75)) == 1_700_000_000)

        // Oversized finite dates clamp to UInt64.max instead of trapping.
        #expect(timelineAt(for: Date(timeIntervalSince1970: 1e30)) == UInt64.max)

        // An explicit timelineAt still overrides the fallback entirely.
        let explicit = MessageItem(
            id: "t",
            senderName: "s",
            body: "b",
            sentAt: Date(timeIntervalSince1970: -5),
            timelineAt: 42,
            isOutgoing: false
        )
        #expect(explicit.timelineAt == 42)
    }

    @Test func remoteImageSanitizedURLRejectsPrivateHosts() async throws {
        // The string entry point used by the UI must also reject internal destinations.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://192.168.1.1/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://127.0.0.1:8080/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://[::1]/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://localhost/x.png") == nil)
        // whitenoise-mac#243: broadcast / multicast / reserved / CGNAT are non-public too,
        // including an obfuscated (decimal) broadcast literal to exercise the parser path.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://255.255.255.255/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://224.0.0.1/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://240.0.0.1/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://100.64.0.1/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://4294967295/x.png") == nil)
        // A public host still round-trips.
        #expect(
            RemoteImageURLPolicy.sanitizedURL(from: "https://cdn.example/p.png")?.absoluteString
                == "https://cdn.example/p.png")
    }

    @Test func remoteImageCollectorReturnsAllBytesUnderCap() async throws {
        // Several chunks spanning typical OS delivery sizes should round-trip byte-for-byte.
        let chunkSize = 64 * 1024
        let payload = (0..<(chunkSize * 2 + 123)).map { UInt8($0 & 0xFF) }
        var collector = CappedDataCollector(cap: Int64(payload.count) + 1)
        // Feed the payload in chunks the way URLSession would deliver it.
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let didAppend = collector.append(Data(payload[offset..<end]))
            #expect(didAppend)
            offset = end
        }
        #expect(!collector.exceededCap)
        #expect(Array(collector.data) == payload)
    }

    @Test func remoteImageCollectorAcceptsExactlyCapBytes() async throws {
        // Exactly `cap` bytes is allowed (the check rejects only when total exceeds cap).
        let payload = [UInt8](repeating: 0xAB, count: 64 * 1024 + 7)
        var collector = CappedDataCollector(cap: Int64(payload.count))
        let didAppend = collector.append(Data(payload))
        #expect(didAppend)
        #expect(!collector.exceededCap)
        #expect(collector.data.count == payload.count)
    }

    @Test func remoteImageCollectorRejectsOverCap() async throws {
        // One byte past the cap aborts the download (unbounded-response protection): the
        // over-cap chunk is rejected, the flag is set, and subsequent chunks are ignored.
        let cap = 64 * 1024
        var collector = CappedDataCollector(cap: Int64(cap))
        let didAppendInitialChunk = collector.append(Data([UInt8](repeating: 0x01, count: cap)))
        #expect(didAppendInitialChunk)
        let didAppendOverCapByte = collector.append(Data([0x02]))
        #expect(!didAppendOverCapByte)
        #expect(collector.exceededCap)
        // Further appends stay rejected and do not grow the buffer.
        let didAppendAfterCapExceeded = collector.append(Data([0x03, 0x04]))
        #expect(!didAppendAfterCapExceeded)
        #expect(collector.data.count == cap)
    }

    @Test func remoteImageCollectorHandlesEmptyResponse() async throws {
        let collector = CappedDataCollector(cap: 1024)
        #expect(collector.data.isEmpty)
        #expect(!collector.exceededCap)
    }

    @Test func remoteImageSanitizedURLRejectsUntrustedInput() async throws {
        // nil / empty / whitespace-only -> nil (no request issued).
        #expect(RemoteImageURLPolicy.sanitizedURL(from: nil) == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "   \n ") == nil)

        // Disallowed schemes -> nil.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "http://tracker.example/pixel.gif") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "javascript:alert(1)") == nil)

        // Allowed https with surrounding whitespace -> trimmed, valid URL.
        let sanitized = RemoteImageURLPolicy.sanitizedURL(from: "  https://cdn.example/p.png  ")
        #expect(sanitized?.absoluteString == "https://cdn.example/p.png")
    }

    @Test func downsampledImageSizingCeilsAndBucketsRequestedPixels() async throws {
        #expect(DownsampledImageSizing.requestedPixelSize(0) == 1)
        #expect(DownsampledImageSizing.requestedPixelSize(63.1) == 64)
        #expect(
            DownsampledImageSizing.galleryPixelSize(
                for: CGSize(width: 100, height: 100),
                displayScale: 2
            ) == 256
        )
        #expect(
            DownsampledImageSizing.galleryPixelSize(
                for: CGSize(width: 321, height: 200),
                displayScale: 2
            ) == 768
        )
    }

    @Test func relayValidatorAcceptsSecureWssRelays() async throws {
        #expect(RelayURLValidator.classify("wss://relay.example.com") == .secure)
        #expect(RelayURLValidator.classify("wss://relay.us.whitenoise.chat") == .secure)
        #expect(RelayURLValidator.classify("WSS://Relay.Example.com") == .secure)
        #expect(RelayURLValidator.isAcceptable("wss://relay.example.com"))
        #expect(!RelayURLValidator.isInsecure("wss://relay.example.com"))
    }

    @Test func relayValidatorRejectsCleartextWsOnPublicHosts() async throws {
        #expect(RelayURLValidator.classify("ws://relay.example.com") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://192.168.1.10:7777") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://10.0.0.1") == .insecureRejected)
        #expect(!RelayURLValidator.isAcceptable("ws://relay.example.com"))
        // Rejected relays are not "insecure-but-allowed" — they simply cannot be saved.
        #expect(!RelayURLValidator.isInsecure("ws://relay.example.com"))
    }

    @Test func relayValidatorAllowsCleartextWsOnLoopbackForDev() async throws {
        for url in [
            "ws://localhost",
            "ws://localhost:7000",
            "ws://127.0.0.1",
            "ws://127.0.0.1:8080/relay",
            "ws://127.1.2.3",
            "ws://[::1]:7000",
        ] {
            #expect(RelayURLValidator.classify(url) == .insecureLoopback, "expected loopback for \(url)")
            #expect(RelayURLValidator.isAcceptable(url), "expected acceptable for \(url)")
            #expect(RelayURLValidator.isInsecure(url), "expected insecure flag for \(url)")
        }
    }

    @Test func relayValidatorAllowsNonCanonicalLoopbackSpellings() async throws {
        // Issue #112: loopback membership is decided by parsing the host as an
        // IP, so every equivalent spelling of the loopback address is accepted,
        // not just the two canonical literals previously hard-coded.
        for url in [
            // Expanded / non-compressed IPv6 loopback.
            "ws://[0:0:0:0:0:0:0:1]",
            "ws://[0:0:0:0:0:0:0:1]:7000",
            // Mixed-case hex with a partial zero-run — still ::1.
            "ws://[0:0:0:0:0:0:0:0001]",
            // IPv4-mapped IPv6 loopback.
            "ws://[::ffff:127.0.0.1]",
            "ws://[::ffff:127.0.0.1]:7000",
            "ws://[::ffff:127.1.2.3]",
            // Non-127.0.0.1 addresses inside 127.0.0.0/8 are still loopback.
            "ws://127.255.255.254",
        ] {
            #expect(RelayURLValidator.classify(url) == .insecureLoopback, "expected loopback for \(url)")
            #expect(RelayURLValidator.isAcceptable(url), "expected acceptable for \(url)")
            #expect(RelayURLValidator.isInsecure(url), "expected insecure flag for \(url)")
        }
    }

    @Test func relayValidatorRejectsNonLoopbackIPLiterals() async throws {
        // Issue #112: parsing must not over-accept. Non-loopback IP literals —
        // including IPv6 and IPv4-mapped IPv6 that point outside 127.0.0.0/8 —
        // remain rejected cleartext relays.
        for url in [
            "ws://[2001:db8::1]",  // public IPv6
            "ws://[::ffff:192.168.1.10]",  // IPv4-mapped, non-loopback
            "ws://[fe80::1]",  // link-local IPv6
            "ws://126.0.0.1",  // just outside 127.0.0.0/8
            "ws://128.0.0.1",  // just outside 127.0.0.0/8
        ] {
            #expect(RelayURLValidator.classify(url) == .insecureRejected, "expected rejection for \(url)")
            #expect(!RelayURLValidator.isAcceptable(url), "expected not acceptable for \(url)")
        }
    }

    @Test func relayValidatorRejectsNonRelaySchemesAndJunk() async throws {
        for url in ["", "   ", "https://relay.example.com", "relay.example.com", "wssx://foo", "ws://"] {
            #expect(!RelayURLValidator.isAcceptable(url), "expected rejection for \(String(reflecting: url))")
        }
        // Leading/trailing whitespace is trimmed before classification, so a
        // surrounded wss:// relay is still accepted as secure.
        #expect(RelayURLValidator.classify("  wss://relay.example.com  ") == .secure)
        #expect(RelayURLValidator.isAcceptable(" wss://relay.example.com "))
    }

    @Test func relayValidatorFlagsAllCleartextWsAsInsecureForUI() async throws {
        // Loopback dev relays are cleartext.
        #expect(RelayURLValidator.isCleartext("ws://127.0.0.1:7000"))
        #expect(RelayURLValidator.isCleartext("ws://localhost"))
        // Pre-existing public ws:// relays loaded from a saved list are also
        // cleartext and must be flagged, even though they cannot be saved again.
        #expect(RelayURLValidator.isCleartext("ws://relay.example.com"))
        #expect(RelayURLValidator.isCleartext("ws://192.168.1.10:7777"))
        // wss:// and junk are not cleartext.
        #expect(!RelayURLValidator.isCleartext("wss://relay.example.com"))
        #expect(!RelayURLValidator.isCleartext("https://relay.example.com"))
        #expect(!RelayURLValidator.isCleartext(""))
    }

    @Test func relayValidatorRejectsSchemeOnlyAndHostlessURLs() async throws {
        // Regression: a scheme prefix with no host must be malformed, not secure.
        // Previously `wss://` was accepted as `.secure` purely on its prefix.
        #expect(RelayURLValidator.classify("wss://") == .invalid)
        #expect(RelayURLValidator.classify("ws://") == .invalid)
        #expect(RelayURLValidator.classify("wss://  ") == .invalid)
        #expect(!RelayURLValidator.isAcceptable("wss://"))
        #expect(!RelayURLValidator.isInsecure("wss://"))
        #expect(!RelayURLValidator.isCleartext("wss://"))
    }

    @Test func relayValidatorRejectsSpoofedLoopbackHosts() async throws {
        // Hostnames that merely *contain* a loopback token must not be treated as loopback.
        #expect(RelayURLValidator.classify("ws://127.0.0.1.evil.com") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://localhost.evil.com") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://notlocalhost") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://127.0.0.256") == .insecureRejected)
    }

    @Test func markdownLinkPolicyAllowsOnlyWebAndNostrSchemes() async throws {
        let httpsURL = MarkdownLinkPolicy.sanitizedURL(from: "https://example.com/path")
        #expect(httpsURL?.absoluteString == "https://example.com/path")

        let httpURL = MarkdownLinkPolicy.sanitizedURL(from: " HTTP://example.com/path ")
        #expect(httpURL?.scheme?.lowercased() == "http")

        let nostrURL = MarkdownLinkPolicy.sanitizedURL(
            from: "nostr:npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        )
        #expect(nostrURL?.scheme == "nostr")

        let nprofileURL = MarkdownLinkPolicy.sanitizedURL(from: "nostr:nprofile1alice")
        #expect(nprofileURL?.absoluteString == "nostr:nprofile1alice")
        #expect(MarkdownLinkPolicy.isResolvableProfileReference("npub1alice"))
        #expect(MarkdownLinkPolicy.isResolvableProfileReference("nprofile1alice"))
        #expect(MarkdownLinkPolicy.isProfileReferenceInput("nostr:nprofile1alice"))
        #expect(!MarkdownLinkPolicy.isResolvableProfileReference("note1alice"))

        for raw in [
            "",
            "   ",
            "https:example.com",
            "file:///Applications/Calculator.app",
            "smb://attacker/share",
            "mailto:peer@example.com",
            "javascript:alert(1)",
            "x-whatever://payload",
            "nostr:unknown1payload",
        ] {
            #expect(
                MarkdownLinkPolicy.sanitizedURL(from: raw) == nil,
                "expected rejection for \(String(reflecting: raw))"
            )
        }
    }

    @Test func markdownLinkPolicyRejectsPrivateAndLoopbackHosts() async throws {
        // whitenoise-mac#249: peer-controlled Markdown links to literal private/loopback/
        // link-local destinations must be suppressed symmetrically with avatar image URLs,
        // even though the scheme is an otherwise-allowed http/https.
        for raw in [
            "http://192.168.0.1/admin/reboot",
            "https://[::1]:9000/",
            "http://127.0.0.1:8080/",
            "https://10.0.0.5/x",
            "http://169.254.169.254/latest/meta-data",
            "https://[fe80::1]/",
            "http://localhost/admin",
            "https://printer.local/status",
            // Obfuscated loopback literal (decimal form of 127.0.0.1).
            "http://2130706433/",
        ] {
            #expect(
                MarkdownLinkPolicy.sanitizedURL(from: raw) == nil,
                "expected rejection for \(String(reflecting: raw))"
            )
        }

        // Public http/https hosts and internal nostr links still pass.
        #expect(MarkdownLinkPolicy.sanitizedURL(from: "https://example.com/path") != nil)
        #expect(MarkdownLinkPolicy.sanitizedURL(from: "http://cdn.example.com/a") != nil)
        #expect(MarkdownLinkPolicy.sanitizedURL(from: "nostr:nprofile1alice") != nil)
    }

    @Test func markdownInlineBuilderDropsUnsafeMarkdownLinks() async throws {
        let safe = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "https://example.com/profile",
                    title: nil,
                    children: [.text(content: "safe")]
                )
            ], remainingDepth: 32)
        #expect(String(safe.characters) == "safe")
        #expect(links(in: safe).map(\.absoluteString) == ["https://example.com/profile"])

        let unsafe = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "file:///Applications/Calculator.app",
                    title: nil,
                    children: [.text(content: "unsafe")]
                )
            ], remainingDepth: 32)
        #expect(String(unsafe.characters) == "unsafe")
        #expect(links(in: unsafe).isEmpty)

        let unsafeAutolink = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .autolink(url: "smb://attacker/share", kind: .uri)
            ], remainingDepth: 32)
        #expect(String(unsafeAutolink.characters) == "smb://attacker/share")
        #expect(links(in: unsafeAutolink).isEmpty)
    }

    @Test func markdownInlineBuilderKeepsNostrEntitiesInternal() async throws {
        let bech32 = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        let attributed = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))
            ], remainingDepth: 32)
        #expect(links(in: attributed).map(\.absoluteString) == ["nostr:\(bech32)"])
    }

    private func links(in attributed: AttributedString) -> [URL] {
        var result: [URL] = []
        for run in attributed.runs {
            if let link = run.link {
                result.append(link)
            }
        }
        return result
    }
}
