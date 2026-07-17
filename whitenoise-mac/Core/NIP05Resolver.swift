//
//  NIP05Resolver.swift
//  whitenoise-mac
//
//  Resolve NIP-05 identifiers (name@example.com) into public-key references that
//  can then be normalized by MarmotKit's member-ref parser.
//

import Foundation

protocol NIP05Resolving {
    func accountReference(for identifier: String) async throws -> String
}

enum NIP05ResolutionError: Error {
    case invalidIdentifier
    case invalidURL
    case invalidResponse
    case requestFailed(statusCode: Int)
    case responseTooLarge
    case notFound
}

struct NIP05Resolver: NIP05Resolving {
    /// A well-known identity document is a small name map, anything past this is hostile.
    private static let maxResponseBytes = 256 * 1024

    private let session: URLSession

    init(
        session: URLSession = URLSession(
            configuration: Self.makeSessionConfiguration(),
            delegate: NIP05RedirectPolicy(),
            delegateQueue: nil
        )
    ) {
        self.session = session
    }

    func accountReference(for identifier: String) async throws -> String {
        guard let parsed = NIP05Identifier(identifier) else {
            throw NIP05ResolutionError.invalidIdentifier
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = parsed.domain
        components.path = "/.well-known/nostr.json"
        components.queryItems = [URLQueryItem(name: "name", value: parsed.name)]

        guard let url = components.url, RemoteImageURLPolicy.isAllowed(url) else {
            throw NIP05ResolutionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("WhiteNoiseMac/1.0", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NIP05ResolutionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NIP05ResolutionError.requestFailed(statusCode: http.statusCode)
        }
        // Cheap pre-check only — the advertised length can be omitted or spoofed, so the
        // streaming cap below is the enforcement that actually bounds the allocation.
        guard http.expectedContentLength <= Int64(Self.maxResponseBytes) else {
            throw NIP05ResolutionError.responseTooLarge
        }

        // Byte-granular iteration is fine here, the cap bounds it to a trivial step count.
        var data = Data()
        data.reserveCapacity(min(Int(max(http.expectedContentLength, 0)), Self.maxResponseBytes))
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= Self.maxResponseBytes else {
                throw NIP05ResolutionError.responseTooLarge
            }
        }

        let decoded = try JSONDecoder().decode(NIP05WellKnownResponse.self, from: data)
        guard let accountReference = decoded.names[parsed.name]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !accountReference.isEmpty
        else {
            throw NIP05ResolutionError.notFound
        }
        return accountReference
    }

    private static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return configuration
    }
}

/// Re-validates each redirect target against the SSRF host policy — URLSession auto-follows
/// redirects, so without this a public well-known host could 3xx the lookup to a private/
/// loopback/link-local address the up-front guard blocks. Also caps the redirect-hop count so a
/// malicious host cannot loop the lookup between public hosts until the resource timeout fires.
/// Mirrors the avatar path's CappedImageDownloadDelegate.
final class NIP05RedirectPolicy: NSObject, URLSessionTaskDelegate {
    private static let maxRedirectHops = 5

    // One instance serves every lookup on the session, so hop budgets are tracked per task.
    private let lock = NSLock()
    private var redirectHopCountsByTask: [Int: Int] = [:]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let hopCount = lock.withLock {
            let count = (redirectHopCountsByTask[task.taskIdentifier] ?? 0) + 1
            redirectHopCountsByTask[task.taskIdentifier] = count
            return count
        }
        if hopCount > Self.maxRedirectHops {
            completionHandler(nil)
            task.cancel()
            return
        }
        guard let url = request.url, RemoteImageURLPolicy.isAllowed(url) else {
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { redirectHopCountsByTask[task.taskIdentifier] = nil }
    }
}

struct NIP05Identifier: Equatable {
    /// Mailbox-length ceiling, generous for any legitimate identifier.
    private static let maxLength = 254
    /// The spec-legal local part, accepted case-insensitively and stored lowercased. Anything
    /// wider (`:`, `/`, …) lets a full profile ref or URL masquerade as a name.
    private static let localPartAlphabet = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")

    let name: String
    let domain: String

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.count <= Self.maxLength,
            trimmed.firstIndex(of: "@") == trimmed.lastIndex(of: "@"),
            let separator = trimmed.firstIndex(of: "@")
        else {
            return nil
        }

        let name = String(trimmed[..<separator]).lowercased()
        let domain = String(trimmed[trimmed.index(after: separator)...]).lowercased()
        guard !name.isEmpty,
            !domain.isEmpty,
            name.allSatisfy(Self.localPartAlphabet.contains),
            domain.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            domain.rangeOfCharacter(from: CharacterSet(charactersIn: "/:?#[]@\\")) == nil,
            domain.contains("."),
            !RemoteImageURLPolicy.isDisallowedHost(domain)
        else {
            return nil
        }

        self.name = name
        self.domain = domain
    }
}

private struct NIP05WellKnownResponse: Decodable {
    let names: [String: String]
}
