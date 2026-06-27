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
    @Test func disappearingMessageCustomLabelClampsOversizedCoreValue() async throws {
        // Regression for whitenoise-mac#212: values can originate from the core as
        // UInt64, and Int(value) traps above Int.max while rendering the picker.
        let oversizedSeconds = UInt64(Int.max) + 1
        let clampedLabel = String(format: L10n.string("%d seconds"), Int(clamping: oversizedSeconds))

        #expect(DisappearingMessageOption.custom(oversizedSeconds).label == clampedLabel)
    }

    @Test func remoteImageSanitizedURLRejectsPrivateHosts() async throws {
        // The string entry point used by the UI must also reject internal destinations.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://192.168.1.1/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://127.0.0.1:8080/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://[::1]/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://localhost/x.png") == nil)
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
}
