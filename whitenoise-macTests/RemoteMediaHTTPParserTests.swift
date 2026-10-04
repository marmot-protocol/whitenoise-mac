//
//  RemoteMediaHTTPParserTests.swift
//  whitenoise-macTests
//
//  Behavior of the pinned remote-media transport's pure pieces: the incremental HTTP/1.1
//  parser, the request serializer, request-target derivation, and resolver answer admission.
//

import Foundation
import Testing

@testable import whitenoise_mac

/// Feeds `bytes` in `fragment`-sized pieces, continuing past the head like the transport does.
private func parseResponse(
    _ bytes: Data,
    fragment: Int = .max,
    endWithEOF: Bool = true
) throws -> RemoteMediaHTTPResponseParser {
    var parser = RemoteMediaHTTPResponseParser()
    var progress = RemoteMediaHTTPResponseParser.Progress.needsMoreData
    var offset = 0
    while offset < bytes.count {
        let end = offset + min(fragment, bytes.count - offset)
        progress = try parser.consume(Data(bytes[offset..<end]))
        offset = end
        if progress == .headReceived {
            progress = try parser.beginBody()
        }
    }
    if progress != .complete, endWithEOF {
        _ = try parser.finishAtEOF()
    }
    return parser
}

private func expectParseError(
    _ expected: RemoteMediaTransportError,
    _ bytes: Data,
    fragment: Int = .max,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(throws: expected, sourceLocation: sourceLocation) {
        _ = try parseResponse(bytes, fragment: fragment)
    }
}

private func bytes(_ text: String) -> Data { Data(text.utf8) }

@Suite(.timeLimit(.minutes(1)))
struct RemoteMediaHTTPParserTests {
    static let payload = Data((0..<1_000).map { UInt8($0 % 251) })

    @Test(arguments: [1, 2, 3, 7, 64, 100_000])
    func contentLengthBodySurvivesAnyFragmentation(fragment: Int) throws {
        let raw = FakeHTTP.response(headers: [("Content-Type", "image/png")], body: Self.payload)
        let parser = try parseResponse(raw, fragment: fragment, endWithEOF: false)

        #expect(parser.isComplete)
        #expect(parser.head?.statusCode == 200)
        #expect(parser.head?.values(for: "content-type") == ["image/png"])
        #expect(parser.body == Self.payload)
    }

    @Test(arguments: [1, 2, 5, 13, 100_000])
    func chunkedBodyWithExtensionsAndTrailersSurvivesAnyFragmentation(fragment: Int) throws {
        let raw = bytes(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\n\r\n"
                + "5;name=value\r\nhello\r\n"
                + "0006 ; ext\r\n world\r\n"
                + "0\r\nX-Trailer: done\r\n\r\n"
        )
        let parser = try parseResponse(raw, fragment: fragment, endWithEOF: false)

        #expect(parser.isComplete)
        #expect(parser.body == bytes("hello world"))
    }

    @Test func chunkedBodyWithoutTrailersCompletes() throws {
        let parser = try parseResponse(
            bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n"),
            endWithEOF: false
        )
        #expect(parser.isComplete)
        #expect(parser.body == bytes("ok"))
    }

    @Test func closeDelimitedBodyCompletesOnlyAtEOF() throws {
        var parser = RemoteMediaHTTPResponseParser()
        #expect(try parser.consume(bytes("HTTP/1.0 200 OK\r\n\r\nab")) == .headReceived)
        #expect(try parser.beginBody() == .needsMoreData)
        #expect(try parser.consume(bytes("c")) == .needsMoreData)
        #expect(!parser.isComplete)
        #expect(try parser.finishAtEOF() == .complete)
        #expect(parser.body == bytes("abc"))
    }

    @Test func emptyStatusesCompleteWithoutABody() throws {
        var parser = RemoteMediaHTTPResponseParser()
        #expect(try parser.consume(bytes("HTTP/1.1 204 No Content\r\n\r\n")) == .headReceived)
        #expect(try parser.beginBody() == .complete)
        #expect(parser.body.isEmpty)
    }

    @Test func informationalResponsesAreSkippedAndBounded() throws {
        let raw = bytes(
            "HTTP/1.1 100 Continue\r\n\r\n"
                + "HTTP/1.1 103 Early Hints\r\nLink: </a.css>\r\n\r\n"
                + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        )
        let parser = try parseResponse(raw, fragment: 4, endWithEOF: false)
        #expect(parser.head?.statusCode == 200)
        #expect(parser.body == bytes("ok"))

        let flood = String(
            repeating: "HTTP/1.1 100 Continue\r\n\r\n",
            count: RemoteMediaHTTPResponseParser.maximumInformationalResponses + 1
        )
        expectParseError(.malformedResponse, bytes(flood + "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
    }

    @Test func switchingProtocolsIsRejected() {
        expectParseError(.unsupportedUpgrade, bytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\n\r\n"))
    }

    /// A header block that never terminates is rejected as soon as it crosses the bound — not
    /// after buffering whatever the peer chooses to send.
    @Test func headerBombIsRejectedBeforeItsTerminatorArrives() throws {
        var parser = RemoteMediaHTTPResponseParser()
        _ = try parser.consume(bytes("HTTP/1.1 200 OK\r\nX-Bomb: "))
        let filler = Data(repeating: 0x61, count: 4_096)
        var fed = 0
        var thrown: RemoteMediaTransportError?
        while thrown == nil, fed < 1_000_000 {
            do {
                _ = try parser.consume(filler)
                fed += filler.count
            } catch let error as RemoteMediaTransportError {
                thrown = error
            }
        }
        #expect(thrown == .headersTooLarge)
        #expect(fed <= RemoteMediaHTTPResponseParser.maximumHeaderBytes)
        // Latched: nothing more is accepted afterwards.
        #expect(throws: RemoteMediaTransportError.malformedResponse) { _ = try parser.consume(bytes("\r\n\r\n")) }
    }

    @Test func headersAndTrailersShareOneAggregateBudget() {
        let bigValue = String(repeating: "h", count: 40 * 1_024)
        let bigTrailer = String(repeating: "t", count: 30 * 1_024)
        let raw = bytes(
            "HTTP/1.1 200 OK\r\nX-Big: \(bigValue)\r\nTransfer-Encoding: chunked\r\n\r\n"
                + "1\r\na\r\n0\r\nX-Trailer: \(bigTrailer)\r\n\r\n"
        )
        expectParseError(.headersTooLarge, raw, fragment: 1_000)
    }

    @Test func oversizedContentLengthIsRejectedAtTheHead() {
        let cap = RemoteMediaHTTPResponseParser.maximumBodyBytes
        expectParseError(.bodyTooLarge, bytes("HTTP/1.1 200 OK\r\nContent-Length: \(cap + 1)\r\n\r\n"))
        // Far past Int.max: rejected without overflowing.
        expectParseError(
            .bodyTooLarge,
            bytes("HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999999999999\r\n\r\n")
        )
    }

    @Test func bodyOfExactlyTheCapIsAccepted() throws {
        let cap = RemoteMediaHTTPResponseParser.maximumBodyBytes
        let parser = try parseResponse(
            FakeHTTP.response(body: Data(count: cap)),
            fragment: RemoteMediaTransport.receiveChunkBytes,
            endWithEOF: false
        )
        #expect(parser.isComplete)
        #expect(parser.body.count == cap)
    }

    @Test func closeDelimitedBodyIsCappedIncrementally() throws {
        let cap = RemoteMediaHTTPResponseParser.maximumBodyBytes
        var parser = RemoteMediaHTTPResponseParser()
        _ = try parser.consume(bytes("HTTP/1.1 200 OK\r\n\r\n"))
        _ = try parser.beginBody()
        let chunk = Data(count: RemoteMediaTransport.receiveChunkBytes)
        for _ in 0..<(cap / chunk.count) {
            _ = try parser.consume(chunk)
        }
        #expect(parser.body.count == cap)
        #expect(throws: RemoteMediaTransportError.bodyTooLarge) { _ = try parser.consume(Data([0])) }
        #expect(parser.body.count == cap)
    }

    @Test func chunkLargerThanTheRemainingBudgetIsRejectedBeforeItsData() throws {
        let cap = RemoteMediaHTTPResponseParser.maximumBodyBytes
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        expectParseError(.bodyTooLarge, bytes(head + String(cap + 1, radix: 16) + "\r\n"))
        expectParseError(.bodyTooLarge, bytes(head + "FFFFFFFFFFFFFFFFFFFFFFFF\r\n"))

        var parser = RemoteMediaHTTPResponseParser()
        _ = try parser.consume(bytes(head))
        _ = try parser.beginBody()
        _ = try parser.consume(bytes(String(cap / 2, radix: 16) + "\r\n"))
        for piece in FakeHTTP.split(Data(count: cap / 2)) {
            _ = try parser.consume(piece)
        }
        _ = try parser.consume(bytes("\r\n"))
        #expect(throws: RemoteMediaTransportError.bodyTooLarge) {
            _ = try parser.consume(bytes(String(cap / 2 + 1, radix: 16) + "\r\n"))
        }
        #expect(parser.body.count == cap / 2)
    }

    @Test func chunkFramingMetadataIsBounded() {
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        let longExtension = String(repeating: "e", count: 1_000)
        let manyChunks = String(repeating: "1;x=\(longExtension)\r\na\r\n", count: 70)
        expectParseError(.framingTooLarge, bytes(head + manyChunks), fragment: 4_096)

        let endlessSizeLine = "1;" + String(repeating: "x", count: RemoteMediaHTTPResponseParser.maximumFramingBytes)
        expectParseError(.framingTooLarge, bytes(head + endlessSizeLine), fragment: 4_096)
    }

    @Test(arguments: [
        "HTTP/2 200 OK",
        "HTTP/1.1 20 OK",
        "HTTP/1.1 200OK",
        "ICY 200 OK",
        "http/1.1 200 OK",
        "HTTP/1.2 200 OK",
        "HTTP/1.1  200 OK",
        "HTTP/1.1 099 Low",
        "HTTP/1.1 600 High",
        "HTTP/1.1 2x0 OK",
        "HTTP/1.1 200 O\u{01}K",
        "",
    ])
    func malformedStatusLinesAreRejected(statusLine: String) {
        expectParseError(.malformedResponse, bytes(statusLine + "\r\nContent-Length: 0\r\n\r\n"))
    }

    @Test func statusLineWithoutReasonPhraseIsAccepted() throws {
        let parser = try parseResponse(bytes("HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n"), endWithEOF: false)
        #expect(parser.head?.statusCode == 200)
    }

    @Test(arguments: [
        "X-A: 1\r\n folded",
        "X-A: 1\r\n\tfolded",
        "X-A : 1",
        " X-A: 1",
        "X-A: a\u{0}b",
        "X-A: a\rb",
        "X-A: a\nb",
        "X-A: a\u{7F}b",
        ": empty-name",
        "X A: 1",
        "NoColon",
    ])
    func malformedHeaderFieldsAreRejected(field: String) {
        expectParseError(.malformedResponse, bytes("HTTP/1.1 200 OK\r\n\(field)\r\nContent-Length: 0\r\n\r\n"))
    }

    @Test func ambiguousOrUnsupportedFramingIsRejected() {
        let ok = "HTTP/1.1 200 OK\r\n"
        expectParseError(.ambiguousFraming, bytes(ok + "Content-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\nok"))
        expectParseError(.ambiguousFraming, bytes(ok + "Content-Length: 2\r\nContent-Length: 2\r\n\r\nok"))
        expectParseError(.ambiguousFraming, bytes(ok + "Content-Length: 2, 2\r\n\r\nok"))
        expectParseError(.unsupportedFraming, bytes(ok + "Transfer-Encoding: gzip, chunked\r\n\r\n"))
        expectParseError(
            .unsupportedFraming, bytes(ok + "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n"))
        expectParseError(.unsupportedFraming, bytes("HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"))
        expectParseError(.unsupportedContentEncoding, bytes(ok + "Content-Encoding: gzip\r\nContent-Length: 0\r\n\r\n"))
        expectParseError(
            .unsupportedContentEncoding, bytes(ok + "Content-Encoding: identity, br\r\nContent-Length: 0\r\n\r\n"))
        expectParseError(.malformedResponse, bytes(ok + "Content-Length: -1\r\n\r\n"))
        expectParseError(.malformedResponse, bytes(ok + "Content-Length: +2\r\n\r\nok"))
        expectParseError(.malformedResponse, bytes(ok + "Content-Length: 0x2\r\n\r\nok"))
    }

    @Test func identityContentEncodingIsAccepted() throws {
        let parser = try parseResponse(
            bytes("HTTP/1.1 200 OK\r\nContent-Encoding: Identity\r\nContent-Length: 2\r\n\r\nok"),
            endWithEOF: false
        )
        #expect(parser.body == bytes("ok"))
    }

    @Test func truncatedMessagesAreRejectedAtEOF() {
        expectParseError(.prematureEOF, bytes("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhalf"))
        expectParseError(.prematureEOF, bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel"))
        expectParseError(.prematureEOF, bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n"))
        expectParseError(.prematureEOF, bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-T: 1\r\n"))
        expectParseError(.prematureEOF, bytes("HTTP/1.1 200 OK\r\nContent-Le"))
    }

    @Test func chunkDelimitersMustBeExact() {
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        expectParseError(.malformedResponse, bytes(head + "3\r\nabcX\r\n0\r\n\r\n"))
        expectParseError(.malformedResponse, bytes(head + "3\r\nabc\n0\r\n\r\n"))
        expectParseError(.malformedResponse, bytes(head + "\r\n"))
        expectParseError(.malformedResponse, bytes(head + "3 \r\nabc\r\n0\r\n\r\n"))
        expectParseError(.malformedResponse, bytes(head + "3;\u{01}\r\nabc\r\n0\r\n\r\n"))
        expectParseError(.malformedResponse, bytes(head + "0\r\n\rX"))
    }

    @Test func bytesBeyondTheMessageAreRejected() {
        expectParseError(.malformedResponse, bytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokEXTRA"))
        expectParseError(
            .malformedResponse, bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nEXTRA"))
    }

    @Test func fieldLookupIsCaseInsensitiveAndKeepsRepeatsApart() throws {
        let parser = try parseResponse(
            bytes("HTTP/1.1 200 OK\r\nCONTENT-length: 2\r\nX-Rep: a\r\nx-rep:  b \r\n\r\nok"),
            endWithEOF: false
        )
        #expect(parser.head?.values(for: "Content-Length") == ["2"])
        #expect(parser.head?.values(for: "X-REP") == ["a", "b"])
    }

    /// Redirect and error heads stop before framing is interpreted, so the transport can close
    /// them without draining — even when their framing would be rejected.
    @Test func finalHeadIsReportedBeforeBodyFramingIsInterpreted() throws {
        var parser = RemoteMediaHTTPResponseParser()
        let progress = try parser.consume(
            bytes(
                "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 5\r\n"
                    + "Transfer-Encoding: gzip\r\n\r\n<not drained>"
            )
        )
        #expect(progress == .headReceived)
        #expect(parser.head?.statusCode == 302)
        #expect(parser.head?.values(for: "location") == ["/next"])
        #expect(parser.body.isEmpty)
    }

    @Test func requestIsAMinimalOriginFormGetWithoutCredentials() throws {
        let target = try RemoteMediaRequestTarget(
            url: try #require(URL(string: "https://[2606:4700:4700::1111]:8443/a%20b/p.png?q=1&r=%2F#fragment"))
        )
        let request = String(decoding: RemoteMediaHTTPRequest.bytes(for: target), as: UTF8.self)

        #expect(
            request
                == "GET /a%20b/p.png?q=1&r=%2F HTTP/1.1\r\n"
                + "Host: [2606:4700:4700::1111]:8443\r\n"
                + "User-Agent: WhiteNoise\r\n"
                + "Accept: */*\r\n"
                + "Accept-Encoding: identity\r\n"
                + "Connection: close\r\n"
                + "\r\n"
        )
    }
}

@Suite struct RemoteMediaRequestTargetTests {
    @Test func hostnameOriginKeepsTheOriginalNameForTLSAndHost() throws {
        let target = try RemoteMediaRequestTarget(url: try #require(URL(string: "https://CDN.Example.com/avatar.png")))
        #expect(target.origin == .name("cdn.example.com"))
        #expect(target.tlsServerName == "cdn.example.com")
        #expect(target.port == 443)
        #expect(target.hostHeader == "cdn.example.com")
        #expect(target.path == "/avatar.png")
    }

    @Test func emptyPathBecomesRoot() throws {
        let target = try RemoteMediaRequestTarget(url: try #require(URL(string: "https://cdn.example.com?x=1")))
        #expect(target.path == "/?x=1")
    }

    @Test(arguments: [
        ("https://cdn.example.com:8443/a", UInt16(8443), "cdn.example.com:8443"),
        ("https://cdn.example.com:443/a", UInt16(443), "cdn.example.com"),
        ("https://cdn.example.com:1/a", UInt16(1), "cdn.example.com:1"),
        ("https://cdn.example.com:65535/a", UInt16(65_535), "cdn.example.com:65535"),
    ])
    func arbitraryHTTPSPortsAreKept(raw: String, port: UInt16, hostHeader: String) throws {
        let target = try RemoteMediaRequestTarget(url: try #require(URL(string: raw)))
        #expect(target.port == port)
        #expect(target.hostHeader == hostHeader)
    }

    @Test func literalOriginsDialTheLiteralWithoutATLSName() throws {
        let v4 = try RemoteMediaRequestTarget(url: try #require(URL(string: "https://8.8.8.8/x.png")))
        #expect(v4.origin == .address(try #require(RemoteMediaAddress(ipv4: [8, 8, 8, 8]))))
        #expect(v4.tlsServerName == nil)
        #expect(v4.hostHeader == "8.8.8.8")

        let v6 = try RemoteMediaRequestTarget(
            url: try #require(URL(string: "https://[2606:4700:4700::1111]:8443/x.png")))
        let expected: [UInt8] = [0x26, 0x06, 0x47, 0x00, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11]
        #expect(v6.origin == .address(try #require(RemoteMediaAddress(ipv6: expected))))
        #expect(v6.tlsServerName == nil)
        #expect(v6.hostHeader == "[2606:4700:4700::1111]:8443")
    }

    /// Hosts that the URL policy may admit but that the transport cannot dial *exactly* —
    /// non-canonical numeric spellings would otherwise reach `getaddrinfo`'s `inet_aton`.
    @Test(arguments: [
        "https://cdn.example.com:0/x",
        "http://cdn.example.com/x",
        "https://user@cdn.example.com/x",
        "https://134744072/x",
        "https://0x08080808/x",
        "https://8.8.8.010/x",
        "https://8.8.010.8/x",
        "https://cdn.example.123/x",
        "https://cdn.example.0x1/x",
        "https://bad_host!.example/x",
    ])
    func unrepresentableTargetsFailClosed(raw: String) throws {
        guard let url = URL(string: raw) else { return }
        #expect(throws: RemoteMediaTransportError.invalidRequest) {
            _ = try RemoteMediaRequestTarget(url: url)
        }
    }
}

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
        #expect(slots.claim())
        #expect(slots.claim())
        #expect(!slots.claim())
        slots.release()
        #expect(slots.inUseCount == 1)
        #expect(slots.claim())
        #expect(RemoteMediaDNSSlots.processWide.limit == 6)
    }
}
