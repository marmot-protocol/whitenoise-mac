//
//  RemoteMediaResolutionTests.swift
//  whitenoise-macTests
//
//  Answer-set admission and the process-wide DNS slot bound.
//

import Foundation
import Testing
import os

@testable import whitenoise_mac

@Suite struct RemoteMediaResolutionTests {
    @Test func publicAnswerSetIsAdmittedInResolverOrder() throws {
        let admitted = try RemoteMediaResolution.admittedAddresses(
            .addresses(["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946", "93.184.216.34"])
        )
        #expect(admitted.map(\.description) == ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"])
    }

    @Test func sixtyFourAnswersAreAdmittedWithoutTruncation() throws {
        let answers = (1...64).map { "93.184.216.\($0)" }
        let admitted = try RemoteMediaResolution.admittedAddresses(.addresses(answers))
        #expect(admitted.count == 64)
    }

    @Test func emptyFailedAndOversizedAnswerSetsAreRejected() {
        #expect(throws: RemoteMediaTransportError.resolutionFailed) {
            _ = try RemoteMediaResolution.admittedAddresses(.addresses([]))
        }
        #expect(throws: RemoteMediaTransportError.resolutionFailed) {
            _ = try RemoteMediaResolution.admittedAddresses(.failed)
        }
        #expect(throws: RemoteMediaTransportError.tooManyAnswers) {
            _ = try RemoteMediaResolution.admittedAddresses(.overflow)
        }
        #expect(throws: RemoteMediaTransportError.tooManyAnswers) {
            _ = try RemoteMediaResolution.admittedAddresses(.addresses((1...65).map { "93.184.216.\($0)" }))
        }
    }

    @Test(arguments: [
        ["10.0.0.1", "93.184.216.34"],
        ["93.184.216.34", "10.0.0.1"],
        ["127.0.0.1"],
        ["169.254.169.254", "8.8.8.8"],
        ["8.8.8.8", "100.64.0.1"],
        ["224.0.0.1", "8.8.8.8"],
        ["8.8.8.8", "240.0.0.1"],
        ["2606:4700::1111", "fd00::1"],
        ["fe80::1", "2606:4700::1111"],
        ["::1"],
        ["::ffff:127.0.0.1", "8.8.8.8"],
        ["8.8.8.8", "64:ff9b::c0a8:1"],
        ["2002:c0a8:101::1"],
        ["2001:db8::5", "8.8.8.8"],
        ["2001:0:808:808:0:0:3f57:fefe"],
    ])
    func anyNonPublicAnswerRejectsTheWholeSet(answers: [String]) {
        #expect(throws: RemoteMediaTransportError.unsafeResolution) {
            _ = try RemoteMediaResolution.admittedAddresses(.addresses(answers))
        }
    }

    @Test(arguments: [
        "cdn.example.com",
        "127.1",
        "0x7f000001",
        "2130706433",
        "010.0.0.1",
        "8.8.8.8.8",
        "256.1.1.1",
        "fe80::1%en0",
        "::ffff:0x7f.0.0.1",
        "1::2::3",
        "1:2:3:4:5:6:7:8:9",
        "::1:2:3:4:5:6:7:8",
        "",
        " 8.8.8.8",
        "8.8.8.8 ",
    ])
    func malformedAnswersRejectTheWholeSet(malformed: String) {
        for answers in [[malformed, "93.184.216.34"], ["93.184.216.34", malformed]] {
            #expect(throws: RemoteMediaTransportError.malformedResolution) {
                _ = try RemoteMediaResolution.admittedAddresses(.addresses(answers))
            }
        }
    }

    /// The real `getaddrinfo` path, on the one name that never leaves the machine: it reports
    /// numeric text, and admission refuses the set (loopback, or a zone-scoped link-local on
    /// hosts files that still list one).
    @Test func systemResolverAnswersForLocalhostAreNeverAdmitted() {
        let answer = SystemRemoteMediaResolver.blockingResolve("localhost")
        guard case .addresses(let texts) = answer else {
            Issue.record("expected localhost to resolve, got \(answer)")
            return
        }
        #expect(texts.contains("127.0.0.1") || texts.contains("::1"))
        #expect(throws: RemoteMediaTransportError.self) {
            _ = try RemoteMediaResolution.admittedAddresses(answer)
        }
    }

    @Test func mappedIPv6DialsAsIPv4() throws {
        let mapped = try #require(RemoteMediaAddress(canonical: "::ffff:8.8.8.8"))
        #expect(mapped.family == .ipv6)
        #expect(mapped.dialAddress == RemoteMediaAddress(ipv4: [8, 8, 8, 8]))
    }

    @Test func dnsSlotsAreBoundedAndReleasedExactly() {
        let slots = RemoteMediaDNSSlots(limit: 2)
        let admitted = OSAllocatedUnfairLock(initialState: 0)
        for _ in 0..<3 {
            _ = slots.request { granted in admitted.withLock { $0 += granted ? 1 : 0 } }
        }
        #expect(admitted.withLock { $0 } == 2)
        #expect(slots.queuedCount == 1)
        slots.release()
        #expect(admitted.withLock { $0 } == 3)
        #expect(slots.inUseCount == 2)
        #expect(slots.queuedCount == 0)
        #expect(RemoteMediaDNSSlots.processWide.limit == 6)
    }
}
