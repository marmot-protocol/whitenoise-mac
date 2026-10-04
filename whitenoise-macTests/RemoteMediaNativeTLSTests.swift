// Real Network.framework/default-trust qualification. The CI wrapper owns all loopback
// listeners and an ephemeral trust root. This tests the socket adapter, not URL admission:
// production URL admission continues to reject loopback, including these fixture addresses.

import Foundation
import Network
import Testing

@testable import whitenoise_mac

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["WN_REMOTE_MEDIA_NATIVE_FIXTURE"]?.hasPrefix("{") == true),
    .timeLimit(.minutes(1))
)
struct RemoteMediaNativeTLSTests {
    private struct Fixture: Decodable {
        let dns: UInt16
        let ip: UInt16
        let untrusted: UInt16
    }

    private static let name = "remote-media-fixture.invalid"

    private static func fixture() throws -> Fixture {
        let value = try #require(ProcessInfo.processInfo.environment["WN_REMOTE_MEDIA_NATIVE_FIXTURE"])
        return try JSONDecoder().decode(Fixture.self, from: Data(value.utf8))
    }

    private static func connection(port: UInt16, name: String?) throws -> any RemoteMediaConnection {
        let address = try #require(RemoteMediaAddress(ipv4: [127, 0, 0, 1]))
        return NetworkRemoteMediaConnectionFactory().makeConnection(
            to: RemoteMediaEndpoint(address: address, port: port, tlsServerName: name))
    }

    // A timer is independent of the socket so a platform regression cannot hang the CI job.
    private static func callback<Value: Sendable>(
        connection: any RemoteMediaConnection,
        start: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        let gate = RemoteMediaCompletionGate<Value>()
        let timer = SystemRemoteMediaClock().schedule(at: ContinuousClock.now + .seconds(10)) {
            if gate.complete(.failure(RemoteMediaTransportError.idleTimeout)) {
                connection.cancel()
            }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if gate.install(continuation) {
                    start { _ = gate.complete($0) }
                }
            }
        } onCancel: {
            if gate.complete(.failure(RemoteMediaTransportError.cancelled)) {
                connection.cancel()
            }
        }
    }

    private static func start(_ connection: any RemoteMediaConnection) async throws {
        let _: Bool = try await callback(connection: connection) { completion in
            connection.start { error in
                if let error { completion(.failure(error)) } else { completion(.success(true)) }
            }
        }
    }

    private static func rejectsTLS(port: UInt16, name: String?) async throws {
        let socket = try connection(port: port, name: name)
        defer { socket.cancel() }
        do {
            try await start(socket)
            Issue.record("a certificate that does not authenticate the requested origin was accepted")
        } catch {
            // A timeout, unavailable fixture or TCP failure must not masquerade as a TLS PASS.
            guard let networkError = error as? NWError, case .tls = networkError else {
                Issue.record("expected a TLS authentication error, received \(error)")
                return
            }
        }
    }

    private static func response(port: UInt16, name: String?, path: String = "/fixed") async throws -> Data {
        let socket = try connection(port: port, name: name)
        defer { socket.cancel() }
        try await start(socket)
        let request = Data("GET \(path) HTTP/1.1\r\nHost: \(name ?? "127.0.0.1")\r\nConnection: close\r\n\r\n".utf8)
        let _: Bool = try await callback(connection: socket) { completion in
            socket.send(request) { error in
                if let error { completion(.failure(error)) } else { completion(.success(true)) }
            }
        }
        var parser = RemoteMediaHTTPResponseParser()
        for _ in 0..<16 {
            let chunk: RemoteMediaReceivedChunk = try await callback(connection: socket) { completion in
                socket.receive(maximumLength: 4096) { completion(.success($0)) }
            }
            // Match production: an error accompanying bytes is never treated as a clean EOF.
            if let error = chunk.error { throw error }
            let progress = try parser.consume(chunk.data)
            if progress == .headReceived { _ = try parser.beginBody() }
            if chunk.isComplete { _ = try parser.finishAtEOF() }
            if parser.isComplete { return parser.body }
        }
        throw RemoteMediaTransportError.malformedResponse
    }

    @Test func nativeTLSOriginalNameWorks() async throws {
        let ports = try Self.fixture()
        let body = try await Self.response(port: ports.dns, name: Self.name)
        // The server returns the SNI it actually received, rather than inspecting parameters.
        #expect(String(decoding: body, as: UTF8.self) == Self.name)
    }

    @Test func nativeTLSWrongNameRejected() async throws {
        try await Self.rejectsTLS(port: Self.fixture().dns, name: "wrong-origin.invalid")
    }

    @Test func nativeTLSLiteralIPNeedsSAN() async throws {
        try await Self.rejectsTLS(port: Self.fixture().dns, name: nil)
    }

    @Test func nativeTLSLiteralIPWithSANWorks() async throws {
        let body = try await Self.response(port: Self.fixture().ip, name: nil)
        #expect(String(decoding: body, as: UTF8.self) == "no-sni")
    }

    @Test func nativeTLSUntrustedCertificateRejected() async throws {
        try await Self.rejectsTLS(port: Self.fixture().untrusted, name: Self.name)
    }

    @Test func nativeTLSCleanCloseCompletesBody() async throws {
        let body = try await Self.response(port: Self.fixture().dns, name: Self.name, path: "/clean-close")
        #expect(String(decoding: body, as: UTF8.self) == Self.name)
    }

    @Test func nativeTLSAbruptCloseDoesNotCompleteBody() async throws {
        do {
            _ = try await Self.response(port: Self.fixture().dns, name: Self.name, path: "/abrupt-close")
            Issue.record("a TLS stream truncated without close_notify was accepted as a complete body")
        } catch {
            guard let networkError = error as? NWError, case .tls = networkError else {
                Issue.record("expected TLS truncation, received \(error)")
                return
            }
        }
    }
}
