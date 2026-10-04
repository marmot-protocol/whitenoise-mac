//
//  RemoteMediaTransportTests.swift
//  whitenoise-macTests
//
//  `RemoteMediaTransport` driven entirely by fakes: virtual time, a holdable resolver, and
//  scripted connections. Every race is sequenced explicitly — no test sleeps, polls a real
//  clock, resolves a name, or opens a socket.
//

import Foundation
import Network
import Testing

@testable import whitenoise_mac

@Suite struct RemoteMediaCompletionGateTests {
    private static func waitOnGate(
        _ gate: RemoteMediaCompletionGate<Int>,
        start: () -> Void
    ) async -> Result<Int, RemoteMediaTransportError> {
        do {
            let value = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int, any Error>) in
                if gate.install(continuation) {
                    start()
                }
            }
            return .success(value)
        } catch let error as RemoteMediaTransportError {
            return .failure(error)
        } catch {
            Issue.record("unexpected error \(error)")
            return .failure(.malformedResponse)
        }
    }

    /// A timeout or cancellation that lands before the waiter installs is delivered on install,
    /// and the operation is never started.
    @Test func outcomeRecordedBeforeInstallIsDeliveredWithoutStarting() async {
        let gate = RemoteMediaCompletionGate<Int>()
        #expect(gate.complete(.failure(RemoteMediaTransportError.deadlineExceeded)))
        #expect(!gate.complete(.success(1)))

        var started = false
        let result = await Self.waitOnGate(gate) { started = true }

        #expect(result == .failure(.deadlineExceeded))
        #expect(!started)
    }

    @Test func firstCompletionAfterInstallWinsAndLaterOnesAreDropped() async {
        let gate = RemoteMediaCompletionGate<Int>()

        let result = await Self.waitOnGate(gate) {
            #expect(gate.complete(.success(7)))
            #expect(!gate.complete(.failure(RemoteMediaTransportError.cancelled)))
        }

        #expect(result == .success(7))
        #expect(!gate.complete(.success(8)))
    }
}

/// The Network.framework adapter's pure configuration. Nothing here starts a connection.
@Suite struct NetworkRemoteMediaConnectionFactoryTests {
    @Test func endpointHostsAreBuiltFromTypedAddressBytes() throws {
        let v4 = try #require(RemoteMediaAddress(ipv4: [8, 8, 8, 8]))
        let mapped = try #require(RemoteMediaAddress(canonical: "::ffff:8.8.8.8"))
        let v6 = try #require(RemoteMediaAddress(canonical: "2606:4700:4700::1111"))

        let expectedV4 = NWEndpoint.Host.ipv4(try #require(IPv4Address("8.8.8.8")))
        #expect(NetworkRemoteMediaConnectionFactory.host(for: v4) == expectedV4)
        #expect(NetworkRemoteMediaConnectionFactory.host(for: mapped) == expectedV4)
        #expect(
            NetworkRemoteMediaConnectionFactory.host(for: v6)
                == .ipv6(try #require(IPv6Address("2606:4700:4700::1111"))))
    }

    @Test func parametersAskToBypassSystemProxies() {
        #expect(NetworkRemoteMediaConnectionFactory.parameters(tlsServerName: "cdn.example.com").preferNoProxies)
        #expect(NetworkRemoteMediaConnectionFactory.parameters(tlsServerName: nil).preferNoProxies)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RemoteMediaTransportTests {
    private static let publicV4 = "93.184.216.34"
    private static let publicV4Bytes: [UInt8] = [93, 184, 216, 34]

    private static func url(_ raw: String) throws -> URL {
        try #require(URL(string: raw))
    }

    // MARK: Pinning

    @Test func hostnameOriginDialsTheAdmittedAddressWithTheOriginalTLSNameHostAndPort() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.setDNS("cdn.example.com", .answer(.addresses([Self.publicV4])))
        harness.network.respond { _, _ in .serving(FakeHTTP.response(body: Data("pixel".utf8))) }

        let result = try await harness.transport.fetch(try Self.url("https://cdn.example.com:8443/a.png?s=1"))

        #expect(result.body == Data("pixel".utf8))
        #expect(result.head?.statusCode == 200)
        #expect(harness.network.resolveCalls == ["cdn.example.com"])
        let connection = try #require(harness.network.connections.first)
        #expect(harness.network.connections.count == 1)
        #expect(
            connection.endpoint
                == RemoteMediaEndpoint(
                    address: try #require(RemoteMediaAddress(ipv4: Self.publicV4Bytes)),
                    port: 8443,
                    tlsServerName: "cdn.example.com"
                )
        )
        #expect(connection.sentText.hasPrefix("GET /a.png?s=1 HTTP/1.1\r\nHost: cdn.example.com:8443\r\n"))
        #expect(!connection.sentText.lowercased().contains("cookie"))
        #expect(!connection.sentText.lowercased().contains("authorization"))
        #expect(!connection.sentText.lowercased().contains("referer"))
        #expect(connection.cancelCount >= 1)
        #expect(harness.slots.inUseCount == 0)
    }

    @Test func literalOriginBypassesDNSAndKeepsTheLiteralForTLS() async throws {
        let harness = RemoteMediaFakeHarness()

        _ = try await harness.transport.fetch(try Self.url("https://[2606:4700:4700::1111]/x.png"))

        #expect(harness.network.resolveCalls.isEmpty)
        let connection = try #require(harness.network.connections.first)
        #expect(connection.endpoint.address.family == .ipv6)
        #expect(connection.endpoint.port == 443)
        #expect(connection.endpoint.tlsServerName == nil)
        #expect(connection.sentText.contains("\r\nHost: [2606:4700:4700::1111]\r\n"))
    }

    @Test func disallowedOriginIsRefusedBeforeAnyResolutionOrConnection() async throws {
        let harness = RemoteMediaFakeHarness()

        let refused = [
            "https://10.0.0.1/x", "https://localhost/x", "http://cdn.example.com/x", "https://a@cdn.example.com/x",
        ]
        for raw in refused {
            let outcome = await RemoteMediaFakeHarness.outcome { try await harness.transport.fetch(try Self.url(raw)) }
            #expect(outcome.transportError == .disallowedURL, "\(raw)")
        }
        #expect(harness.network.resolveCalls.isEmpty)
        #expect(harness.network.connections.isEmpty)
    }

    @Test(arguments: [["10.0.0.7", "93.184.216.34"], ["93.184.216.34", "10.0.0.7"]])
    func mixedAnswerSetNeverConnects(answers: [String]) async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.setDNS("rebind.example", .answer(.addresses(answers)))

        let outcome = await RemoteMediaFakeHarness.outcome {
            try await harness.transport.fetch(try Self.url("https://rebind.example/x.png"))
        }

        #expect(outcome.transportError == .unsafeResolution)
        #expect(harness.network.connections.isEmpty)
        #expect(harness.slots.inUseCount == 0)
    }

    // MARK: DNS bounds

    @Test func deadlineDuringDNSReturnsPromptlyAndTheLateAnswerNeverConnects() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.setDNS("slow.example", .hold)

        let fetch = harness.startFetch(try Self.url("https://slow.example/x.png"))
        await harness.wait { harness.network.heldResolutionCount == 1 }
        #expect(harness.slots.inUseCount == 1)

        harness.clock.advance(by: .seconds(59))
        #expect(harness.network.heldResolutionCount == 1)
        harness.clock.advance(by: .seconds(1))

        // Returns while getaddrinfo is still "blocked" — nobody waits for the worker.
        #expect(await fetch.value.transportError == .deadlineExceeded)
        #expect(harness.slots.inUseCount == 1)

        harness.network.completeHeldResolution(with: .addresses([Self.publicV4]))
        #expect(harness.slots.inUseCount == 0)
        #expect(harness.network.connections.isEmpty)
    }

    @Test func cancellationDuringDNSReturnsPromptlyAndTheSlotIsHeldUntilTheWorkerReturns() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.setDNS("slow.example", .hold)

        let fetch = harness.startFetch(try Self.url("https://slow.example/x.png"))
        await harness.wait { harness.network.heldResolutionCount == 1 }
        fetch.cancel()

        #expect(await fetch.value.transportError == .cancelled)
        #expect(harness.slots.inUseCount == 1)
        #expect(harness.clock.pendingTimerCount == 0)

        harness.network.completeHeldResolution(with: .addresses([Self.publicV4]))
        #expect(harness.slots.inUseCount == 0)
        #expect(harness.network.connections.isEmpty)
    }

    @Test func preCancelledFetchNeverResolvesOrClaimsASlot() async throws {
        let harness = RemoteMediaFakeHarness()
        let url = try Self.url("https://cdn.example.com/x.png")
        let transport = harness.transport

        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RemoteMediaFakeHarness.outcome { try await transport.fetch(url) }
        }.value

        #expect(outcome.transportError == .cancelled)
        #expect(harness.network.resolveCalls.isEmpty)
        #expect(harness.network.connections.isEmpty)
        #expect(harness.slots.inUseCount == 0)
    }

    @Test func exhaustedDNSSlotsFailFastInsteadOfQueueing() async throws {
        let harness = RemoteMediaFakeHarness()
        let limit = RemoteMediaDNSSlots.maximumConcurrentResolutions
        var fetches: [Task<Result<RemoteMediaFetchResult, RemoteMediaTransportError>, Never>] = []
        for index in 0..<limit {
            harness.network.setDNS("slow\(index).example", .hold)
            fetches.append(harness.startFetch(try Self.url("https://slow\(index).example/x.png")))
        }
        await harness.wait { harness.network.heldResolutionCount == limit }

        let overflow = await RemoteMediaFakeHarness.outcome {
            try await harness.transport.fetch(try Self.url("https://another.example/x.png"))
        }
        #expect(overflow.transportError == .dnsUnavailable)
        #expect(harness.network.resolveCalls.count == limit)

        // Abandoned callers do not give their slots back; only returning workers do.
        fetches.forEach { $0.cancel() }
        for fetch in fetches {
            #expect(await fetch.value.transportError == .cancelled)
        }
        #expect(harness.slots.inUseCount == limit)
        for _ in 0..<limit {
            harness.network.completeHeldResolution(with: .addresses([Self.publicV4]))
        }
        #expect(harness.slots.inUseCount == 0)
        #expect(harness.network.connections.isEmpty)
    }

    // MARK: Network bounds

    @Test func stalledReceiveTimesOutAfterTheIdleWindowAndClosesTheSocket() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.respond { _, _ in .held }

        let fetch = harness.startFetch(try Self.url("https://cdn.example.com/x.png"))
        await harness.wait { harness.network.connections.first?.hasPendingReceive == true }
        let connection = try #require(harness.network.connections.first)

        harness.clock.advance(by: .seconds(14))
        #expect(connection.cancelCount == 0)
        harness.clock.advance(by: .seconds(1))

        #expect(await fetch.value.transportError == .idleTimeout)
        #expect(connection.cancelCount >= 1)
    }

    @Test func stalledConnectTimesOutAndClosesTheSocket() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.respond { _, _ in RemoteMediaConnectionScript(start: .hold) }

        let fetch = harness.startFetch(try Self.url("https://cdn.example.com/x.png"))
        await harness.wait { harness.network.connections.first?.hasPendingStart == true }
        harness.clock.advance(by: RemoteMediaTransport.idleTimeout)

        #expect(await fetch.value.transportError == .idleTimeout)
        #expect(try #require(harness.network.connections.first).cancelCount >= 1)
    }

    /// Each byte is real progress and resets the idle window, but the drip cannot outlive the
    /// one deadline established before DNS.
    @Test func slowDripIsBoundedByTheTotalDeadline() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.respond { _, _ in .held }

        let fetch = harness.startFetch(try Self.url("https://cdn.example.com/x.png"))
        let head = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".utf8)
        await harness.wait { harness.network.connections.first?.hasPendingReceive == true }
        let connection = try #require(harness.network.connections.first)

        connection.deliver(head)
        for step in 1...5 {
            await harness.wait { connection.hasPendingReceive && connection.receiveCount == step + 1 }
            harness.clock.advance(by: .seconds(10))
            connection.deliver(Data("x".utf8))
        }
        await harness.wait { connection.hasPendingReceive && connection.receiveCount == 7 }
        #expect(connection.cancelCount == 0)
        harness.clock.advance(by: .seconds(10))

        #expect(await fetch.value.transportError == .deadlineExceeded)
        #expect(connection.cancelCount >= 1)
    }

    @Test func cancellationDuringReceiveClosesTheSocketWithoutWaitingForIt() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.respond { _, _ in .held }

        let fetch = harness.startFetch(try Self.url("https://cdn.example.com/x.png"))
        await harness.wait { harness.network.connections.first?.hasPendingReceive == true }
        fetch.cancel()

        #expect(await fetch.value.transportError == .cancelled)
        #expect(try #require(harness.network.connections.first).cancelCount >= 1)
        #expect(harness.clock.pendingTimerCount == 0)
    }

    // MARK: Address retry

    @Test func connectFailureMovesToTheNextAdmittedAddress() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.setDNS("cdn.example.com", .answer(.addresses(["93.184.216.34", "93.184.216.35"])))
        harness.network.respond { _, index in
            index == 0 ? RemoteMediaConnectionScript(start: .fail) : .serving(FakeHTTP.response(body: Data("ok".utf8)))
        }

        let result = try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))

        #expect(result.body == Data("ok".utf8))
        #expect(harness.network.connections.map(\.endpoint.address.bytes) == [[93, 184, 216, 34], [93, 184, 216, 35]])
    }

    @Test func failureAfterHTTPProcessingBeganIsNotRetried() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.setDNS("cdn.example.com", .answer(.addresses(["93.184.216.34", "93.184.216.35"])))
        harness.network.respond { _, _ in .serving(Data("HTTP/9 200 OK\r\n\r\n".utf8)) }

        let outcome = await RemoteMediaFakeHarness.outcome {
            try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))
        }

        #expect(outcome.transportError == .malformedResponse)
        #expect(harness.network.connections.count == 1)
    }

    @Test func oversizedBodyFailsClosedOverTheWire() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.setDNS("cdn.example.com", .answer(.addresses(["93.184.216.34", "93.184.216.35"])))
        let oversized = Data(count: RemoteMediaHTTPResponseParser.maximumBodyBytes + 1)
        harness.network.respond { _, _ in
            .serving(FakeHTTP.response(body: oversized, contentLength: false))
        }

        let outcome = await RemoteMediaFakeHarness.outcome {
            try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))
        }

        #expect(outcome.transportError == .bodyTooLarge)
        #expect(harness.network.connections.count == 1)
    }

    @Test func nonSuccessStatusesFailWithoutReadingTheBody() async throws {
        for status in [404, 500, 206, 304] {
            let harness = RemoteMediaFakeHarness()
            harness.network.respond { _, _ in
                RemoteMediaConnectionScript(
                    chunks: [Data("HTTP/1.1 \(status) X\r\nContent-Length: 999999\r\n\r\n".utf8)],
                    end: .hold
                )
            }
            let outcome = await RemoteMediaFakeHarness.outcome {
                try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))
            }
            #expect(outcome.transportError == .httpStatus(status))
            #expect(harness.network.connections.first?.receiveCount == 1)
        }
    }

    // MARK: Redirects

    @Test func redirectToAPrivateLiteralIsRefusedBeforeConnecting() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.respond { _, _ in .serving(FakeHTTP.redirect(to: "https://10.0.0.1/x.png")) }

        let outcome = await RemoteMediaFakeHarness.outcome {
            try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))
        }

        #expect(outcome.transportError == .disallowedURL)
        #expect(harness.network.connections.count == 1)
    }

    @Test func redirectToCleartextIsRefused() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.respond { _, _ in .serving(FakeHTTP.redirect(status: 301, to: "http://cdn.example.com/x.png")) }

        let outcome = await RemoteMediaFakeHarness.outcome {
            try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))
        }

        #expect(outcome.transportError == .disallowedURL)
        #expect(harness.network.connections.count == 1)
    }

    @Test func redirectToAHostnameResolvingPrivateIsRefusedBeforeConnecting() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.setDNS("internal.example", .answer(.addresses(["10.0.0.5"])))
        harness.network.respond { _, _ in .serving(FakeHTTP.redirect(status: 307, to: "https://internal.example/x")) }

        let outcome = await RemoteMediaFakeHarness.outcome {
            try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))
        }

        #expect(outcome.transportError == .unsafeResolution)
        #expect(harness.network.resolveCalls == ["cdn.example.com", "internal.example"])
        #expect(harness.network.connections.count == 1)
    }

    @Test func sameHostRedirectIsResolvedAndAdmittedAgain() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.respond { _, index in
            index == 0
                ? .serving(FakeHTTP.redirect(status: 308, to: "/moved.png?v=2"))
                : .serving(FakeHTTP.response(body: Data("moved".utf8)))
        }

        let result = try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))

        #expect(result.body == Data("moved".utf8))
        #expect(result.url.absoluteString == "https://cdn.example.com/moved.png?v=2")
        #expect(harness.network.resolveCalls == ["cdn.example.com", "cdn.example.com"])
        #expect(harness.network.connections.count == 2)
        #expect(harness.network.connections[1].sentText.hasPrefix("GET /moved.png?v=2 HTTP/1.1\r\n"))
    }

    @Test func redirectChainIsCappedAtFive() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.respond { _, _ in .serving(FakeHTTP.redirect(to: "/again")) }

        let outcome = await RemoteMediaFakeHarness.outcome {
            try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))
        }

        #expect(outcome.transportError == .tooManyRedirects)
        #expect(harness.network.connections.count == RemoteMediaTransport.maximumRedirects + 1)
    }

    @Test func redirectWithoutAUsableLocationFails() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.respond { _, _ in
            .serving(FakeHTTP.response(status: 302, reason: "Found", headers: [("Location", "/a"), ("Location", "/b")]))
        }

        let outcome = await RemoteMediaFakeHarness.outcome {
            try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))
        }

        #expect(outcome.transportError == .invalidRedirect)
    }

    /// The redirect head is acted on as soon as it arrives; its (here endless) body is never read.
    @Test func redirectClosesAfterTheHeadWithoutDrainingTheBody() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.respond { _, index in
            index == 0
                ? RemoteMediaConnectionScript(
                    chunks: [Data("HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 100000000\r\n\r\n".utf8)],
                    end: .hold
                )
                : .serving(FakeHTTP.response(body: Data("next".utf8)))
        }

        let result = try await harness.transport.fetch(try Self.url("https://cdn.example.com/x.png"))

        #expect(result.body == Data("next".utf8))
        let first = harness.network.connections[0]
        #expect(first.receiveCount == 1)
        #expect(first.cancelCount >= 1)
    }

    @Test func redirectHopsShareTheDeadlineEstablishedBeforeTheFirstResolution() async throws {
        let harness = RemoteMediaFakeHarness()
        harness.network.setDNS("first.example", .hold)
        harness.network.respond { _, index in
            index == 0 ? .serving(FakeHTTP.redirect(to: "https://second.example/x.png")) : .held
        }

        let fetch = harness.startFetch(try Self.url("https://first.example/x.png"))
        await harness.wait { harness.network.heldResolutionCount == 1 }
        harness.clock.advance(by: .seconds(50))
        harness.network.completeHeldResolution(with: .addresses([Self.publicV4]))

        await harness.wait {
            harness.network.connections.count == 2 && harness.network.connections[1].hasPendingReceive
        }
        // The second hop has used nothing of its own idle window, but only 10s of the total.
        harness.clock.advance(by: .seconds(10))

        #expect(await fetch.value.transportError == .deadlineExceeded)
        #expect(harness.network.connections[1].cancelCount >= 1)
    }

    // MARK: Cache hook

    @Test func cachedHopIsServedAfterAdmissionWithoutResolvingOrConnecting() async throws {
        let harness = RemoteMediaFakeHarness()
        let url = try Self.url("https://cdn.example.com/x.png")

        let result = try await harness.transport.fetch(url) { hop in
            hop == url ? Data("cached".utf8) : nil
        }

        #expect(result.body == Data("cached".utf8))
        #expect(result.head == nil)
        #expect(harness.network.resolveCalls.isEmpty)
        #expect(harness.network.connections.isEmpty)
    }
}

@Suite struct RemoteMediaResponseCacheTests {
    private static let responseTime = Date(timeIntervalSince1970: 1_700_000_000)

    private static func head(status: Int = 200, _ fields: [(String, String)]) -> RemoteMediaHTTPResponseHead {
        RemoteMediaHTTPResponseHead(
            statusCode: status,
            minorVersion: 1,
            fields: fields.map { RemoteMediaHTTPField(name: $0.0.lowercased(), value: $0.1) }
        )
    }

    private static func freshness(
        status: Int = 200,
        _ fields: [(String, String)],
        responseDelay: Duration = .zero
    ) -> RemoteMediaCacheFreshness? {
        RemoteMediaCachePolicy.freshness(
            for: head(status: status, fields),
            wallClockAtResponse: responseTime,
            responseDelay: responseDelay
        )
    }

    @Test func explicitMaxAgeIsCacheableAndAgeIsCorrected() {
        let fresh = Self.freshness(
            [("Cache-Control", "public, max-age=600"), ("Age", "100")],
            responseDelay: .seconds(2)
        )
        #expect(fresh == RemoteMediaCacheFreshness(lifetime: .seconds(600), initialAge: .seconds(102)))
    }

    @Test func dateInThePastRaisesTheInitialAge() {
        let fresh = Self.freshness([
            ("Cache-Control", "max-age=600"),
            ("Date", "Tue, 14 Nov 2023 22:08:20 GMT"),  // responseTime - 300s
        ])
        #expect(fresh == RemoteMediaCacheFreshness(lifetime: .seconds(600), initialAge: .seconds(300)))
    }

    @Test func expiresIsMeasuredFromTheDateHeader() {
        let fresh = Self.freshness([
            ("Date", "Tue, 14 Nov 2023 22:13:10 GMT"),  // responseTime - 10s
            ("Expires", "Tue, 14 Nov 2023 22:18:10 GMT"),  // Date + 300s
        ])
        #expect(fresh == RemoteMediaCacheFreshness(lifetime: .seconds(300), initialAge: .seconds(10)))
    }

    @Test(arguments: [
        [("Cache-Control", "no-store, max-age=600")],
        [("Cache-Control", "max-age=600, no-cache")],
        [("Cache-Control", "max-age=600"), ("Vary", "Accept")],
        [("Cache-Control", "max-age=600"), ("Set-Cookie", "id=1")],
        [("Cache-Control", "max-age=600, x-unknown")],
        [("Cache-Control", "max-age=600"), ("Pragma", "no-cache")],
        [("Cache-Control", "max-age=abc")],
        [("Cache-Control", "max-age=60, max-age=600")],
        [("Cache-Control", "max-age=600"), ("Age", "600")],
        [("Cache-Control", "max-age=600"), ("Age", "-1")],
        [("Cache-Control", "max-age=0")],
        [("Last-Modified", "Tue, 14 Nov 2023 22:13:20 GMT")],
        [("Expires", "0")],
        [("Expires", "Tue, 14 Nov 2023 22:13:19 GMT")],
        [("Expires", "Tuesday, 14-Nov-23 22:18:20 GMT")],
    ])
    func responsesThatMustNotBeStoredAreBypassed(fields: [(String, String)]) {
        #expect(Self.freshness(fields) == nil)
    }

    @Test func onlyAComplete200IsCacheable() {
        for status in [203, 204, 206, 301, 404] {
            #expect(Self.freshness(status: status, [("Cache-Control", "max-age=600")]) == nil)
        }
    }

    @Test func httpDatesParseOnlyAsIMFFixdate() {
        #expect(
            RemoteMediaCachePolicy.parseHTTPDate("Tue, 14 Nov 2023 22:13:20 GMT")
                == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(
            RemoteMediaCachePolicy.parseHTTPDate("Sun, 06 Nov 1994 08:49:37 GMT")
                == Date(timeIntervalSince1970: 784_111_777))
        #expect(RemoteMediaCachePolicy.parseHTTPDate("Sunday, 06-Nov-94 08:49:37 GMT") == nil)
        #expect(RemoteMediaCachePolicy.parseHTTPDate("Sun Nov  6 08:49:37 1994") == nil)
        #expect(RemoteMediaCachePolicy.parseHTTPDate("Sun, 06 Nov 1994 25:49:37 GMT") == nil)
        #expect(RemoteMediaCachePolicy.parseHTTPDate("Sun, 06 Foo 1994 08:49:37 GMT") == nil)
    }

    @Test func expiredEntryIsDroppedSoTheNextLoadRefetches() throws {
        var cache = RemoteMediaResponseCache()
        let url = try #require(URL(string: "https://cdn.example.com/x.png"))
        let start = ContinuousClock.now
        let freshness = RemoteMediaCacheFreshness(lifetime: .seconds(60), initialAge: .seconds(10))

        #expect(cache.store(Data("x".utf8), for: url, freshness: freshness, now: start))
        #expect(cache.body(for: url, now: start.advanced(by: .seconds(49))) == Data("x".utf8))
        #expect(cache.body(for: url, now: start.advanced(by: .seconds(50))) == nil)
        #expect(!cache.contains(url))
        #expect(cache.totalBytes == 0)
    }

    @Test func entryCountIsBoundedLeastRecentlyUsedFirst() throws {
        var cache = RemoteMediaResponseCache()
        let now = ContinuousClock.now
        let freshness = RemoteMediaCacheFreshness(lifetime: .seconds(600), initialAge: .zero)
        let urls = try (0...RemoteMediaResponseCache.maximumEntryCount).map { index in
            try #require(URL(string: "https://cdn.example.com/\(index).png"))
        }
        for url in urls.dropLast() {
            cache.store(Data([1]), for: url, freshness: freshness, now: now)
        }
        _ = cache.body(for: urls[0], now: now)

        cache.store(Data([1]), for: urls[urls.count - 1], freshness: freshness, now: now)

        #expect(cache.count == RemoteMediaResponseCache.maximumEntryCount)
        #expect(cache.contains(urls[0]))
        #expect(!cache.contains(urls[1]))
        #expect(cache.contains(urls[urls.count - 1]))
    }

    @Test func totalBytesAreBoundedLeastRecentlyUsedFirst() throws {
        var cache = RemoteMediaResponseCache()
        let now = ContinuousClock.now
        let freshness = RemoteMediaCacheFreshness(lifetime: .seconds(600), initialAge: .zero)
        let body = Data(count: 6 * 1_024 * 1_024)
        let urls = try (0..<3).map { try #require(URL(string: "https://cdn.example.com/big\($0).png")) }

        for url in urls {
            cache.store(body, for: url, freshness: freshness, now: now)
        }

        #expect(cache.totalBytes <= RemoteMediaResponseCache.maximumTotalBytes)
        #expect(!cache.contains(urls[0]))
        #expect(cache.contains(urls[1]))
        #expect(cache.contains(urls[2]))
    }

    @Test func uncacheableReplacementEvictsThePriorEntry() throws {
        var cache = RemoteMediaResponseCache()
        let url = try #require(URL(string: "https://cdn.example.com/x.png"))
        let now = ContinuousClock.now
        cache.store(
            Data("old".utf8), for: url,
            freshness: RemoteMediaCacheFreshness(lifetime: .seconds(600), initialAge: .zero), now: now)

        #expect(!cache.store(Data("new".utf8), for: url, freshness: nil, now: now))
        #expect(!cache.contains(url))
        #expect(cache.totalBytes == 0)
    }
}
