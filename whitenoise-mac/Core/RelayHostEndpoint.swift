//
//  RelayHostEndpoint.swift
//  whitenoise-mac
//
//  The host:port pair a relay URL points at, used by the reachability probe
//  behind the "Waiting for internet connection" notice.
//
//  Ported from the Flutter client's `_relayUrls()` / `_relayPort()` in
//  `lib/providers/offline_provider.dart`, including the default-port rule: a
//  relay URL rarely carries a port, so `ws://` falls back to 80 and everything
//  else (in practice `wss://`) to 443.
//

import Foundation

/// A relay host to open a TCP connection against.
///
/// Deliberately not a `URL`: the probe only needs somewhere to point a socket, and reducing
/// the relay list to host/port up front means a malformed entry is dropped once, at parse
/// time, instead of failing inside every probe pass.
nonisolated struct RelayHostEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let port: Int
}

extension RelayHostEndpoint {
    /// The endpoints worth probing from a relay-URL list, in the order given.
    ///
    /// Entries that carry no host are dropped rather than substituted — an unparseable relay
    /// URL is not a network failure, and pretending it resolves somewhere would let one bad
    /// entry answer for the whole list.
    static func endpoints(from relayURLs: [String]) -> [RelayHostEndpoint] {
        relayURLs.compactMap(Self.init(relayURL:))
    }

    init?(relayURL: String) {
        let trimmed = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }
        self.host = host
        self.port = components.port ?? Self.defaultPort(forScheme: components.scheme)
    }

    private static func defaultPort(forScheme scheme: String?) -> Int {
        scheme?.lowercased() == "ws" ? 80 : 443
    }
}
