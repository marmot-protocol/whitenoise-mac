//
//  WorkspaceState+UserDiscovery.swift
//  whitenoise-mac
//
//  Streaming web-of-trust people search for the compose flow: the model, the pure
//  ranking/presentation rules, and the state extension that drives the subscription.
//
//  This is the only place in the app where the "MarmotKit calls are local DB reads" rule
//  breaks — `searchUsers` traverses a social graph over relays. Four FFI contracts shape
//  everything below (MarmotKit.swift:2333-2346, :6088-6092, :16066-16070):
//
//  1. `searchUsers` returns as soon as the traversal is *spawned*, not when results exist;
//     the host drives `nextUpdate()` in a loop until it yields `nil`.
//  2. Abandoning a search means *releasing* the subscription, not draining it — dropping it
//     cancels the relay traversal at its next checkpoint. So a superseded search returns
//     immediately and lets the subscription deinit; it never loops on to `searchCompleted`.
//  3. `newResults` is pre-sorted only *within* a batch, so the host re-sorts the aggregate on
//     every update.
//  4. A search result is not a relationship. Discovered people are deliberately absent from
//     the local directory, so nothing here may be written into `peerProfileFFICache` or
//     `composeContacts`, and discovery rows must never be routed through
//     `resolveNewChatRecipient(for:)` (which refreshes the profile over the network and
//     invalidates that cache). Recipients are built locally from the search result's own
//     profile snapshot instead.
//

import Foundation
import MarmotKit

/// One person a web-of-trust search found. Not a contact: this exists only for as long as the
/// query that produced it, and never enters `composeContacts` or the profile cache.
///
/// Every string here came from a stranger, so `init` — not the call site — sanitizes the display
/// name and runs the avatar URL through the SSRF policy. A discovery list is the app's
/// highest-volume untrusted-avatar surface; making sanitization unskippable is the point.
nonisolated struct DiscoveredPerson: Identifiable, Equatable, Sendable {
    let accountIdHex: String
    let npub: String
    /// Social distance from the searcher: 1 is "in your network" (a follow *or* a shared-group
    /// peer), 2 one hop further out. 255 is off-graph and must never read as a connection.
    let radius: UInt8
    /// Rank supplied by an off-graph discovery provider; absent for graph results.
    let providerRank: Double?
    let matchQualityRank: Int
    let matchedFieldRank: Int
    let displayName: String?
    let pictureURL: String?
    /// Pre-sanitized once from the stranger-controlled raw URL so rows only read this.
    let sanitizedPictureURL: URL?

    var id: String { accountIdHex }

    init(
        accountIdHex: String,
        npub: String,
        radius: UInt8,
        providerRank: Double?,
        matchQualityRank: Int,
        matchedFieldRank: Int,
        displayName: String?,
        pictureURL: String?
    ) {
        self.accountIdHex = accountIdHex
        self.npub = npub
        self.radius = radius
        self.providerRank = providerRank
        self.matchQualityRank = matchQualityRank
        self.matchedFieldRank = matchedFieldRank
        self.displayName = PeerDisplayText.sanitize(displayName)
        self.pictureURL = pictureURL
        self.sanitizedPictureURL = RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
    }

    var memberRef: String {
        npub.isEmpty ? accountIdHex : npub
    }

    var title: String {
        displayName ?? DisplayText.short(memberRef)
    }

    var subtitle: String {
        DisplayText.short(memberRef, head: 12, tail: 8)
    }

    /// The npub came from the core in this process, already canonical, so it is used directly as
    /// the member ref — `createGroup` validates it anyway. Deliberately *not* re-resolved through
    /// `resolveNewChatRecipient(for:)`, which would promote the profile into the local cache.
    var recipient: NewChatRecipient {
        NewChatRecipient(
            sourceQuery: "",
            memberRef: memberRef,
            accountIdHex: accountIdHex,
            npub: npub,
            displayName: displayName,
            pictureURL: pictureURL
        )
    }
}

/// Known contacts and discovered strangers, kept in separate sections rather than interleaved so
/// a search snapshot never masquerades as someone you already talk to.
nonisolated struct MergedComposeResults: Equatable, Sendable {
    let known: [ComposeContact]
    let discovered: [DiscoveredPerson]

    var isEmpty: Bool { known.isEmpty && discovered.isEmpty }
}

nonisolated enum UserDiscoveryRanking {
    /// Maps one FFI result into a `DiscoveredPerson`, dropping results with no usable identity.
    static func person(from result: UserDirectorySearchResultFfi) -> DiscoveredPerson? {
        let hex = result.accountIdHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hex.isEmpty else { return nil }
        return DiscoveredPerson(
            accountIdHex: hex,
            npub: result.npub,
            radius: result.radius,
            providerRank: result.providerRank,
            matchQualityRank: rank(of: result.matchQuality),
            matchedFieldRank: rank(of: result.matchedField),
            displayName: firstNonBlank([
                PeerDisplayText.sanitize(result.profile?.displayName),
                PeerDisplayText.sanitize(result.profile?.name),
            ]),
            pictureURL: result.profile?.picture
        )
    }

    /// Deduped by lowercased hex (first occurrence wins) and totally ordered, so re-sorting the
    /// growing aggregate on every update never makes the rendered list jitter.
    static func sortedUnique(_ people: [DiscoveredPerson]) -> [DiscoveredPerson] {
        var seen = Set<String>()
        var unique: [DiscoveredPerson] = []
        unique.reserveCapacity(people.count)
        for person in people where seen.insert(person.accountIdHex.lowercased()).inserted {
            unique.append(person)
        }
        return unique.sorted(by: isOrderedBefore)
    }

    /// Known contacts keep their existing order and win any hex collision: a `ComposeContact` is
    /// derived from a conversation you are actually in, so its name and picture come from a real
    /// interaction and are strictly better than a search snapshot. (iOS back-fills a known
    /// candidate's missing profile from the discovered duplicate; skipped deliberately, which also
    /// keeps this a pure set operation.)
    static func merged(
        known: [ComposeContact],
        discovered: [DiscoveredPerson],
        excluding: Set<String>
    ) -> MergedComposeResults {
        let excluded = Set(excluding.map { $0.lowercased() })
        let keptKnown = known.filter { !excluded.contains($0.accountIdHex.lowercased()) }
        var claimed = excluded
        claimed.formUnion(keptKnown.map { $0.accountIdHex.lowercased() })
        let keptDiscovered = sortedUnique(discovered).filter {
            !claimed.contains($0.accountIdHex.lowercased())
        }
        return MergedComposeResults(known: keptKnown, discovered: keptDiscovered)
    }

    /// iOS's comparator minus its followed-first tier (follow is out of scope here). Radius still
    /// leads, and radius 1 already contains the follow list, so someone you follow generally still
    /// sorts near the top — just not guaranteed above a shared-group peer.
    static func isOrderedBefore(_ lhs: DiscoveredPerson, _ rhs: DiscoveredPerson) -> Bool {
        if lhs.radius != rhs.radius { return lhs.radius < rhs.radius }
        switch (lhs.providerRank, rhs.providerRank) {
        case (let left?, let right?) where left != right:
            return left > right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            break
        }
        if lhs.matchQualityRank != rhs.matchQualityRank {
            return lhs.matchQualityRank < rhs.matchQualityRank
        }
        if lhs.matchedFieldRank != rhs.matchedFieldRank {
            return lhs.matchedFieldRank < rhs.matchedFieldRank
        }
        // Total-order tiebreak: without it, two otherwise-identical results could swap places
        // between updates because `sort` is not stable.
        return lhs.accountIdHex.lowercased() < rhs.accountIdHex.lowercased()
    }

    /// Best first. Switched exhaustively so a bindings update that adds a quality breaks the build.
    static func rank(of quality: MatchQualityFfi) -> Int {
        switch quality {
        case .exact: 0
        case .prefix: 1
        case .contains: 2
        }
    }

    /// Most identifying first. Exhaustive for the same reason as `rank(of: MatchQualityFfi)`.
    static func rank(of field: MatchedFieldFfi) -> Int {
        switch field {
        case .name: 0
        case .nip05: 1
        case .displayName: 2
        case .about: 3
        case .npub: 4
        case .pubkey: 5
        }
    }
}

/// Row provenance and the search-status footer, kept out of the views so both are testable.
nonisolated enum UserDiscoveryPresentation {
    /// Provenance line for a discovered row. `nil` for radii the search never requests (0 is the
    /// searcher; 3…254 are outside the 1…2 window), so an unexpected value renders no claim about
    /// a connection rather than an invented one.
    static func provenanceLabel(radius: UInt8) -> String? {
        switch radius {
        case 1: L10n.string("In your network")
        case 2: L10n.string("Via your network")
        case 255: L10n.string("Discovery")
        default: nil
        }
    }

    /// Exactly one status at a time. `searching` outranks `failed` because an `.error` trigger is
    /// always followed by `searchCompleted` — the failure is reported once the loop actually ends,
    /// never alongside a live spinner.
    static func status(isSearching: Bool, didFail: Bool, isPartial: Bool) -> UserDiscoveryStatus {
        if isSearching { return .searching }
        if didFail { return .failed }
        if isPartial { return .partial }
        return .none
    }

    /// "No matches" must not flash between the debounce firing and the first update landing.
    static func showsNoMatches(results: MergedComposeResults, isSearching: Bool) -> Bool {
        results.isEmpty && !isSearching
    }
}

nonisolated enum UserDiscoveryStatus: Equatable, Sendable {
    case none
    case searching
    case failed
    case partial
}

@MainActor
extension WorkspaceState {
    /// Matches iOS. The identifier path has its own separate 250 ms debounce
    /// (`NewChatQueryResolutionModifier`); the two gate mutually exclusive query branches and
    /// never both fire for one query, so they are deliberately not unified.
    static let userDiscoveryDebounce = Duration.milliseconds(300)
    /// iOS's window. Radius 0 is the searcher — excluded, not searched.
    static let userDiscoveryRadiusStart: UInt8 = 1
    static let userDiscoveryRadiusEnd: UInt8 = 2

    /// Known matches plus discovered strangers for the current query, self always removed.
    ///
    /// Staged/selected members are *not* excluded: they stay visible with a filled checkmark,
    /// exactly as known contacts already do in Choose members.
    func composeSearchResults(matching query: String) -> MergedComposeResults {
        var excluded: Set<String> = []
        if let selfHex = activeAccount?.accountIdHex {
            excluded.insert(selfHex.lowercased())
        }
        return UserDiscoveryRanking.merged(
            known: filteredComposeContacts(matching: query),
            discovered: discoveredPeopleForCurrentQuery,
            excluding: excluded
        )
    }

    /// Results are only shown against the query they were produced for, so an in-flight search
    /// cannot leave the previous query's people on screen.
    var discoveredPeopleForCurrentQuery: [DiscoveredPerson] {
        let query = newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard discoveryResultsQuery == query else { return [] }
        return discoveredPeople
    }

    var userDiscoveryStatus: UserDiscoveryStatus {
        UserDiscoveryPresentation.status(
            isSearching: isSearchingPeople,
            didFail: discoveryDidFail,
            isPartial: discoveryIsPartial
        )
    }

    func scheduleUserDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        discoveredPeople = []
        discoveryResultsQuery = ""
        discoveryIsPartial = false
        discoveryDidFail = false

        let query = newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // A pasted npub/NIP-05 already names one person, so a graph traversal for it is pure
        // waste — the identifier resolver owns that branch (mirrors iOS's `shouldSearch` gate).
        guard !query.isEmpty, !looksLikeMemberRef(query) else {
            isSearchingPeople = false
            return
        }
        guard let client, let account = activeAccount else {
            isSearchingPeople = false
            return
        }

        isSearchingPeople = true
        discoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: WorkspaceState.userDiscoveryDebounce)
                guard let self, self.ownsUserDiscovery(generation: generation) else { return }
                // Spinner ownership is keyed on the generation ALONE, deliberately looser than the
                // generation+query+account guard used to commit results. Every exit — terminal
                // trigger, stream end, or abandoning a superseded search mid-stream — must clear
                // the spinner, or editing the query while a traversal is in flight strands it at
                // `true` (the shape of #110 and #255).
                defer {
                    if self.ownsUserDiscovery(generation: generation) {
                        self.isSearchingPeople = false
                        self.discoveryTask = nil
                    }
                }
                let subscription = try await client.searchUsers(
                    accountIdHex: account.accountIdHex,
                    query: query,
                    radiusStart: WorkspaceState.userDiscoveryRadiusStart,
                    radiusEnd: WorkspaceState.userDiscoveryRadiusEnd
                )
                var aggregate: [DiscoveredPerson] = []
                while let update = await subscription.nextUpdate() {
                    // A superseded search returns here and lets `subscription` deinit, which
                    // cancels the relay traversal. Draining on to `searchCompleted` instead would
                    // keep a traversal alive for a query nobody is looking at.
                    guard !Task.isCancelled,
                        self.isCurrentUserDiscovery(
                            generation: generation,
                            query: query,
                            accountId: account.id
                        )
                    else { return }

                    aggregate.append(contentsOf: update.newResults.compactMap(UserDiscoveryRanking.person))
                    self.discoveredPeople = UserDiscoveryRanking.sortedUnique(aggregate)
                    self.discoveryResultsQuery = query
                    if self.applyUserDiscovery(trigger: update.trigger) { break }
                }
                // A stream that ends without ever delivering a result still owns the query it
                // answered, so "no matches" replaces the spinner instead of both showing.
                if self.isCurrentUserDiscovery(generation: generation, query: query, accountId: account.id) {
                    self.discoveryResultsQuery = query
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.ownsUserDiscovery(generation: generation) else { return }
                self.discoveryDidFail = true
                self.isSearchingPeople = false
                self.discoveryTask = nil
            }
        }
    }

    func invalidateUserDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryGeneration &+= 1
        discoveredPeople = []
        discoveryResultsQuery = ""
        discoveryIsPartial = false
        discoveryDidFail = false
        isSearchingPeople = false
    }

    /// Returns `true` when this update was terminal.
    ///
    /// Switched exhaustively over all 8 triggers with no `default`, so a bindings update that adds
    /// one breaks the build instead of being silently ignored.
    private func applyUserDiscovery(trigger: SearchUpdateTriggerFfi) -> Bool {
        switch trigger {
        case .radiusTimeout, .radiusTruncated:
            // Partial, not failed: everything already delivered is still correct, so keep the
            // results on screen and keep looping.
            discoveryIsPartial = true
            return false
        case .error:
            // Always followed by `searchCompleted`, so keep looping and let that end the search.
            discoveryDidFail = true
            return false
        case .searchCompleted:
            return true
        case .radiusStarted, .resultsFound, .discoveryResultsFound, .radiusCompleted:
            return false
        }
    }

    /// True while `generation` still owns the discovery spinner — i.e. no newer
    /// `scheduleUserDiscovery`/`invalidateUserDiscovery` has bumped the generation. Deliberately
    /// looser than `isCurrentUserDiscovery`: spinner ownership must transfer cleanly even when the
    /// query changes mid-flight, or the spinner strands at `true` (the shape of #110 and #255).
    func ownsUserDiscovery(generation: UInt64) -> Bool {
        discoveryGeneration == generation
    }

    /// The stricter guard used before committing results: same generation, same live query, same
    /// account. Any mismatch means this search has been abandoned.
    func isCurrentUserDiscovery(generation: UInt64, query: String, accountId: String) -> Bool {
        ownsUserDiscovery(generation: generation)
            && activeAccountId == accountId
            && newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }
}
