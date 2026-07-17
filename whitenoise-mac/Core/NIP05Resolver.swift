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
    case notFound
}

struct NIP05Resolver: NIP05Resolving {
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

        guard let url = parsed.wellKnownRequestURL() else {
            throw NIP05ResolutionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("WhiteNoiseMac/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NIP05ResolutionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NIP05ResolutionError.requestFailed(statusCode: http.statusCode)
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
/// loopback/link-local address the up-front guard blocks. Mirrors the avatar path's
/// CappedImageDownloadDelegate.
final class NIP05RedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, RemoteImageURLPolicy.isAllowed(url) else {
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }
}

struct NIP05Identifier: Equatable {
    private static let maxNameUTF8Bytes = 64
    private static let maxDomainLength = 253
    private static let maxDomainInputUTF8Bytes = maxDomainLength * 4
    private static let maxLabelLength = 63

    let name: String
    let domain: String

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.firstIndex(of: "@") == trimmed.lastIndex(of: "@"),
            let separator = trimmed.firstIndex(of: "@")
        else {
            return nil
        }

        let rawName = String(trimmed[..<separator])
        let rawDomain = String(trimmed[trimmed.index(after: separator)...])
        guard let name = Self.validatedName(rawName),
            let domain = Self.canonicalDomain(from: rawDomain),
            !RemoteImageURLPolicy.isDisallowedHost(domain)
        else {
            return nil
        }

        self.name = name
        self.domain = domain
    }

    func wellKnownRequestURL() -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/.well-known/nostr.json"
        guard
            let encodedName = name.addingPercentEncoding(
                withAllowedCharacters: Self.wellKnownNameQueryAllowedCharacters
            )
        else {
            return nil
        }
        components.percentEncodedQuery = "name=\(encodedName)"
        guard let url = components.url, RemoteImageURLPolicy.isAllowed(url) else {
            return nil
        }
        return url
    }

    private static let nameForbiddenCharacters = CharacterSet(charactersIn: "&=+%#?/")
    private static let domainDelimiterCharacters = CharacterSet(charactersIn: "/:?#[]@\\")
    private static let uts46LabelSeparators = CharacterSet(charactersIn: ".\u{3002}\u{FF0E}\u{FF61}")
    private static let wellKnownNameQueryAllowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func validatedName(_ name: String) -> String? {
        guard !name.isEmpty,
            name.utf8.count <= maxNameUTF8Bytes,
            name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            name.rangeOfCharacter(from: nameForbiddenCharacters) == nil
        else {
            return nil
        }
        return name
    }

    private static func canonicalDomain(from rawDomain: String) -> String? {
        let domain = rawDomain.lowercased()
        guard !domain.isEmpty,
            domain.utf8.count <= maxDomainInputUTF8Bytes,
            trailingLabelSeparatorCount(in: domain) <= 1,
            domain.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            domain.rangeOfCharacter(from: domainDelimiterCharacters) == nil
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        guard components.url != nil,
            let encodedHost = components.encodedHost?.lowercased(),
            !encodedHost.isEmpty,
            let decodedHost = components.host
        else {
            return nil
        }
        components.host = decodedHost
        guard let roundTrippedHost = components.encodedHost?.lowercased(),
            roundTrippedHost == encodedHost,
            !hasUndecodedALabel(encodedHost: encodedHost, decodedHost: decodedHost)
        else {
            return nil
        }

        var canonical = encodedHost
        if canonical.hasSuffix(".") {
            canonical.removeLast()
        }
        guard !canonical.isEmpty,
            !canonical.hasSuffix("."),
            canonical.contains("."),
            canonical.count <= maxDomainLength,
            isValidLDHHost(canonical)
        else {
            return nil
        }
        return canonical
    }

    private static func trailingLabelSeparatorCount(in domain: String) -> Int {
        var count = 0
        for scalar in domain.unicodeScalars.reversed() {
            guard uts46LabelSeparators.contains(scalar) else { break }
            count += 1
        }
        return count
    }

    private static func hasUndecodedALabel(encodedHost: String, decodedHost: String) -> Bool {
        guard encodedHost != decodedHost else {
            return encodedHost.split(separator: ".").contains { $0.hasPrefix("xn--") }
        }
        return false
    }

    private static func isValidLDHHost(_ host: String) -> Bool {
        guard host.unicodeScalars.allSatisfy(\.isASCII) else { return false }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= maxLabelLength else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            for scalar in label.unicodeScalars {
                let value = scalar.value
                let isLetter = (97...122).contains(value)
                let isDigit = (48...57).contains(value)
                guard isLetter || isDigit || value == 45 else { return false }
            }
        }
        return true
    }
}

private struct NIP05WellKnownResponse: Decodable {
    let names: [String: String]
}
