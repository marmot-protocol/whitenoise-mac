import Foundation
import MarmotKit
import Observation

/// The public Nostr events one conversation's messages link, and their authors, for the cards
/// drawn under those messages.
///
/// MDK owns the fetch, the signature check, the cache and its refresh policy
/// (`resolvePublicEventPreview`); this reads its cached copy first so a card already seen draws
/// at once, then asks it to refresh every time the card comes on screen. The relay fetch queries
/// relays the message's sender chose, so it only runs while "Show Link Previews" is on, checked
/// again right before the fetch starts. Authors come from MDK's local profile copy only: looking
/// one up on relays would tell them whose post the viewer just opened.
@MainActor
@Observable
final class NostrEventPreviewStore {
    nonisolated struct Author: Equatable, Sendable {
        let name: String?
        let pictureURL: URL?
    }

    /// The events with a card, keyed by reference. Anything absent draws no card.
    private(set) var previews: [String: NostrEventPreview] = [:]
    private(set) var authors: [String: Author] = [:]

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private let mayFetch: @MainActor () -> Bool
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]

    init(
        accountRef: String,
        runtime: any MarmotRuntime,
        mayFetch: @escaping @MainActor () -> Bool = { LinkPreviewPreference.shared.showsPreviews }
    ) {
        self.accountRef = accountRef
        self.runtime = runtime
        self.mayFetch = mayFetch
    }

    func preview(for reference: String) -> NostrEventPreview? {
        previews[reference]
    }

    func author(_ accountIdHex: String) -> Author? {
        authors[accountIdHex]
    }

    /// Reads, then refreshes, `reference` unless a load of it is already running. Called every
    /// time its card comes on screen; MDK's cooldown and refresh policy keep that cheap.
    func load(_ reference: String) {
        guard loads[reference] == nil else { return }
        loads[reference] = Task { [weak self] in
            await self?.fetch(reference)
        }
    }

    /// The conversation is going away: stop every fetch.
    func cancelAll() {
        for task in loads.values { task.cancel() }
        loads.removeAll()
    }

    private func fetch(_ reference: String) async {
        defer { loads[reference] = nil }
        let accountRef = accountRef
        let runtime = runtime

        let cached = try? await FFIExecutor.run {
            try runtime.cachedPublicEventPreviews(accountRef: accountRef, references: [reference]).first
        }
        guard !Task.isCancelled else { return }
        if let cached { await apply(cached, for: reference) }

        // A thrown fetch keeps the card: MDK's cache is unchanged by it.
        guard mayFetch(), !Task.isCancelled,
            let resolved = try? await runtime.resolvePublicEventPreview(accountRef: accountRef, reference: reference),
            !Task.isCancelled
        else { return }
        await apply(resolved, for: reference)
    }

    /// Either result is MDK's local state for the reference, so it decides the card outright: a
    /// present event draws, and anything else (deleted, no longer held, not an event) draws none.
    /// MDK keeps prior content when a fetch comes back empty, so a miss here is not a relay hiccup.
    private func apply(_ result: PublicEventPreviewFfi, for reference: String) async {
        guard result.state == .present, let json = result.eventJson,
            let preview = NostrEventPreview.parse(eventJson: json)
        else {
            previews[reference] = nil
            return
        }
        if previews[reference] != preview { previews[reference] = preview }
        await loadAuthor(preview.authorIdHex)
    }

    private func loadAuthor(_ accountIdHex: String) async {
        guard authors[accountIdHex] == nil else { return }
        let runtime = runtime
        // Not remembered while MDK has no profile, so one its directory learns later still shows.
        guard let profile = try? await FFIExecutor.run({ try runtime.userProfile(accountIdHex: accountIdHex) }),
            !Task.isCancelled, authors[accountIdHex] == nil
        else { return }
        authors[accountIdHex] = Self.author(from: profile)
    }

    nonisolated static func author(from profile: UserProfileMetadataFfi) -> Author {
        let name = PeerDisplayText.sanitize(profile.displayName) ?? PeerDisplayText.sanitize(profile.name)
        return Author(
            name: name.map { String($0.prefix(64)) },
            pictureURL: RemoteImageURLPolicy.sanitizedURL(from: profile.picture)
        )
    }
}
