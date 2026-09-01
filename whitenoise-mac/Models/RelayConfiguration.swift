//
//  RelayConfiguration.swift
//  whitenoise-mac
//
//  What the Relays page is a view of: the account's relay endpoints, the roles each one
//  serves, and whether the lists they belong to have actually reached the network.
//
//  Ported from `wn-ios-prototype`'s `PrototypeRelayConfiguration` / `PrototypeRelay`, with
//  three deliberate differences, because the prototype models a relay set no core has to
//  agree with and this one does:
//
//  * **Two roles, not three.** The core publishes exactly two account relay lists —
//    NIP-65 (kind 10002) and inbox (kind 10050) — so `Profile` and `Inbox` are the whole
//    of `Use for`. The prototype's third role, *Chat Messages*, has no list behind it:
//    `MarmotClient` exposes `setAccountNip65Relays` and `setAccountInboxRelays` and nothing
//    else, and the relays a new chat is created on come from the NIP-65 set.
//  * **Publish state, not connection state.** The prototype's rows report Connected /
//    Reconnecting / Disconnected from a fixture. Nothing here can: `AccountRelayListsFfi`
//    carries no per-relay socket state, and the reachability probe behind the offline banner
//    answers one question for the whole list (`RelayHostReachabilityProbing`). What the core
//    *does* report per list is whether it has been published — `missing` / `complete` — so
//    that is what a row reports.
//  * **No read-only relays.** NIP-65 has read/write directions in the protocol and the mdk
//    preserves them (`nip65_relay_set_preserving_roles`), but `RelayListFfi` hands over one
//    flat `relays` array — the *write* set — so a read-only relay is not visible here and
//    the prototype's `(Read Only)` qualifier has nothing to render from. The qualifier a row
//    does carry is cleartext `ws://`, which `RelayURLValidator` can see.
//

import Foundation

/// What an account uses a relay for: one role per relay list the core publishes.
///
/// The prototype's `Use For` set. Sentence-cased labels rather than its title case, following
/// the rest of this app's settings copy.
enum RelayRole: String, CaseIterable, Identifiable, Sendable {
    /// The NIP-65 relay list (kind 10002): where this account's profile and relay list live.
    case profile
    /// The inbox relay list (kind 10050): where invitations to new chats arrive.
    case inbox

    var id: String { rawValue }

    var label: String {
        switch self {
        case .profile: L10n.string("Profile")
        case .inbox: L10n.string("Inbox")
        }
    }

    /// The glyph beside the toggle, matching the prototype's role symbols.
    var symbol: String {
        switch self {
        case .profile: "person.crop.circle"
        case .inbox: "tray"
        }
    }

    /// What the role does, said under its own toggle. The prototype's `explanation`, with
    /// "your profile" resolved to this app's noun for the thing being published.
    var explanation: String {
        switch self {
        case .profile:
            L10n.string("Publishes this account's profile and relay list.")
        case .inbox:
            L10n.string("Receives invitations to new chats and groups.")
        }
    }
}

/// Whether the lists a relay belongs to have reached the network.
///
/// Per *relay* rather than per list, because that is the row the reader is looking at: a
/// relay is `published` once every role it serves lists it in the published set the core
/// reports back.
enum RelayPublishState: Equatable, Sendable {
    case published
    case notPublished

    var label: String {
        switch self {
        case .published: L10n.string("Published")
        case .notPublished: L10n.string("Not published")
        }
    }

    var symbol: String {
        switch self {
        case .published: "checkmark.circle.fill"
        case .notPublished: "exclamationmark.circle.fill"
        }
    }
}

/// How a role is doing, which is what the recovery callout is a summary of.
enum RelayRoleCoverage: Equatable, Sendable {
    /// At least one relay serves the role and the list has been published.
    case published
    /// Relays are assigned but the list has not reached the network yet.
    case notPublished
    /// No relay serves the role at all.
    ///
    /// Unreachable while the core is answering — it refuses to publish an empty list
    /// (`AppError::MissingDefaultRelays`) and substitutes the default relays for a list it has
    /// never seen, which is why the UI never offers to empty a role. Modelled anyway so the
    /// callout has something true to say if a snapshot ever arrives in that shape.
    case unassigned

    var needsAttention: Bool { self != .published }
}

/// One relay row: the endpoint, what it is used for, and how it is doing.
struct RelayEndpointItem: Identifiable, Equatable, Sendable {
    /// The comparison key, not the display URL — see `RelayURLValidator.identity`.
    let id: String
    /// The host, which is what a reader scans a relay list by. Named rather than derived for
    /// the two relays this app ships with; see `RelayDisplayName`.
    let displayName: String
    let url: String
    let roles: Set<RelayRole>
    /// Cleartext `ws://` transport. Kept from the previous page: it is the one qualifier on a
    /// relay this app can actually see, and it is a security statement rather than a style.
    let isInsecure: Bool
    let publishState: RelayPublishState

    /// The roles in `RelayRole.allCases` order, so two rows never disagree about the order
    /// they name the same pair in.
    var orderedRoles: [RelayRole] {
        RelayRole.allCases.filter { roles.contains($0) }
    }
}

/// The name a relay is listed under.
///
/// The host for anything the reader added, the way the prototype names a custom relay. The two
/// relays this app seeds an account with get a name of their own — they are ours, they are what
/// a fresh account is entirely made of, and `relay.eu.whitenoise.chat` above
/// `wss://relay.eu.whitenoise.chat` is one line of information printed twice.
enum RelayDisplayName {
    /// Unlocalized on purpose: these are names, not sentences.
    private static let named: [String: String] = [
        "relay.eu.whitenoise.chat": "White Noise EU",
        "relay.us.whitenoise.chat": "White Noise US",
    ]

    static func forRelay(_ url: String) -> String {
        guard let host = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
            !host.isEmpty
        else {
            return url
        }
        return named[host.lowercased()] ?? host
    }
}

// `nonisolated` on both members, not just on the extension's enclosing type: this module
// defaults to main-actor isolation, so an extension on a `nonisolated enum` still produces
// main-actor-isolated methods — and passing one as a function value (`map(identity)`) is then a
// call from a nonisolated context. It shows up only as a Release-build warning.
extension RelayURLValidator {
    /// The storage form of a relay URL: trimmed, with any trailing slashes dropped.
    ///
    /// The prototype's `normalizedRelayURL`. A trailing slash makes no difference to a relay
    /// and every difference to `contains`, so it is removed once, on the way in.
    nonisolated static func normalized(_ value: String) -> String {
        var url = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") {
            url.removeLast()
        }
        return url
    }

    /// The comparison key for "is this the same relay". Case-insensitive, since a host is.
    nonisolated static func identity(_ value: String) -> String {
        normalized(value).lowercased()
    }
}

extension RelaySettingsSnapshot {
    /// The published set for a role — what the core says actually reached the network, rather
    /// than what the account has declared.
    func publishedRelays(for role: RelayRole) -> [String] {
        switch role {
        case .profile: publishedNip65
        case .inbox: publishedInbox
        }
    }

    /// The roles this relay serves.
    func roles(forRelay url: String) -> Set<RelayRole> {
        let key = RelayURLValidator.identity(url)
        return Set(
            RelayRole.allCases.filter { role in
                relays(for: role).contains { RelayURLValidator.identity($0) == key }
            }
        )
    }

    /// One union list of every configured endpoint, in the order the lists give them.
    ///
    /// The prototype's rule — "a native `Form` presents one union list of configured relay
    /// endpoints. The main list is the complete overview" — replacing the list-switching
    /// picker this page used to open on, which showed one list at a time and made the other
    /// one invisible.
    var endpoints: [RelayEndpointItem] {
        var seen = Set<String>()
        var items: [RelayEndpointItem] = []
        for role in RelayRole.allCases {
            for url in relays(for: role) {
                let key = RelayURLValidator.identity(url)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                let roles = roles(forRelay: url)
                items.append(
                    RelayEndpointItem(
                        id: key,
                        displayName: RelayDisplayName.forRelay(url),
                        url: RelayURLValidator.normalized(url),
                        roles: roles,
                        isInsecure: RelayURLValidator.isCleartext(url),
                        publishState: publishState(forRelay: url, roles: roles)
                    )
                )
            }
        }
        return items
    }

    /// Whether every role this relay serves lists it in its published set.
    ///
    /// A relay assigned to no role is reported as published rather than as a problem: it is
    /// not carrying anything, so there is nothing about it that has failed to publish.
    private func publishState(forRelay url: String, roles: Set<RelayRole>) -> RelayPublishState {
        let key = RelayURLValidator.identity(url)
        let isPublishedForEveryRole = roles.allSatisfy { role in
            publishedRelays(for: role).contains { RelayURLValidator.identity($0) == key }
        }
        return isPublishedForEveryRole ? .published : .notPublished
    }

    func coverage(for role: RelayRole) -> RelayRoleCoverage {
        if relays(for: role).isEmpty { return .unassigned }
        return publishedRelays(for: role).isEmpty ? .notPublished : .published
    }

    /// Whether this relay is the only one serving `role`, which is what makes the role's
    /// toggle and the relay's removal refuse.
    ///
    /// The prototype confirms and then permits the degraded state. Nothing here can: the core
    /// rejects an empty relay list outright (`AppError::MissingDefaultRelays`), so an
    /// "understood, turn it off anyway" would be a promise the next call breaks. The
    /// affordance is disabled and the reason is said instead — add another relay first.
    /// Counted by *identity*, not by entry. A role holding two spellings of one relay
    /// — `wss://a.example` and `wss://A.example/` — is still down to its last one, and a raw
    /// `count == 1` said otherwise while the match below answered to the same key. The two
    /// callers both act on identity, so the disagreement was reachable: `setRelayRole` removed
    /// every matching entry and published an empty list, which the core rejects outright
    /// (`MissingDefaultRelays`), and `removeRelay` skipped the role instead, leaving the relay
    /// gone from its other role and silently still here.
    func isOnlyRelay(_ url: String, for role: RelayRole) -> Bool {
        let key = RelayURLValidator.identity(url)
        let identities = Set(relays(for: role).map { RelayURLValidator.identity($0) })
        return identities == [key]
    }

    /// The roles this relay is the last one for. Empty means the relay can be removed.
    func rolesDependingOnly(on url: String) -> [RelayRole] {
        RelayRole.allCases.filter { isOnlyRelay(url, for: $0) }
    }

    /// Whether the page shows its recovery callout.
    var relaysNeedAttention: Bool {
        RelayRole.allCases.contains { coverage(for: $0).needsAttention }
    }

    /// The callout's detail line: what is wrong, and what it costs.
    ///
    /// The prototype's `recoverySummary` shape — the problem, then the consequence — cut down
    /// to the states this app can actually be in. One sentence per case rather than a
    /// composed one, so every language gets a sentence its own grammar chose.
    var relayAttentionSummary: String {
        let unassigned = RelayRole.allCases.filter { coverage(for: $0) == .unassigned }
        if !unassigned.isEmpty {
            return String(
                format: L10n.string("Choose a relay for %@."),
                ListFormatter.localizedString(byJoining: unassigned.map(\.label))
            )
        }

        let unpublished = RelayRole.allCases.filter { coverage(for: $0) == .notPublished }
        switch Set(unpublished) {
        case [.profile]:
            return L10n.string(
                "Your profile relay list hasn't been published yet, so other people may not find you."
            )
        case [.inbox]:
            return L10n.string(
                "Your inbox relay list hasn't been published yet, so invitations to new chats may not arrive."
            )
        case [.profile, .inbox]:
            return L10n.string(
                "Your relay lists haven't been published yet, so other people may not find you and "
                    + "invitations to new chats may not arrive."
            )
        default:
            return ""
        }
    }

    /// Whether both lists are exactly the relays a fresh account starts with, which is what
    /// makes `Restore default relays` pointless and therefore disabled.
    var isDefaultRelayConfiguration: Bool {
        let seed = MarmotClient.seedRelays.map(RelayURLValidator.identity)
        return RelayRole.allCases.allSatisfy { role in
            relays(for: role).map(RelayURLValidator.identity) == seed
        }
    }
}
