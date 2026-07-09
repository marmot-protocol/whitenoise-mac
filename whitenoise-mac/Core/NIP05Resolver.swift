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

    init(session: URLSession = URLSession(configuration: Self.makeSessionConfiguration())) {
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

struct NIP05Identifier: Equatable {
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

        let name = String(trimmed[..<separator])
        let domain = String(trimmed[trimmed.index(after: separator)...]).lowercased()
        guard !name.isEmpty,
            !domain.isEmpty,
            name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
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
