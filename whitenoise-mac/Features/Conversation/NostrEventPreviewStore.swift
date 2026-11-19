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

    nonisolated enum Entry: Equatable, Sendable {
        case loading
        case loaded(NostrEventPreview)
        /// Deleted by its author, or not an event at all: no card, and no point asking again.
        case unavailable
    }

    private(set) var entries: [String: Entry] = [:]
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

    func entry(for reference: String) -> Entry? {
        entries[reference]
    }

    func author(_ accountIdHex: String) -> Author? {
        authors[accountIdHex]
    }

    /// Reads, then refreshes, `reference`, unless a load is already running or it is known to be
    /// unavailable. A miss or a failed fetch is forgotten, so the next time the card is shown it
    /// asks again; MDK's own cooldown keeps that cheap.
    func load(_ reference: String) {
        guard loads[reference] == nil, entries[reference] != .unavailable else { return }
        if entries[reference] == nil { entries[reference] = .loading }
        loads[reference] = Task { [weak self] in
            await self?.fetch(reference)
        }
    }

    /// The conversation is going away: stop every fetch. A cut-short load is forgotten, so the
    /// next `load` starts over.
    func cancelAll() {
        for (reference, task) in loads {
            task.cancel()
            if entries[reference] == .loading { entries[reference] = nil }
        }
        loads.removeAll()
    }

    private func fetch(_ reference: String) async {
        defer {
            loads[reference] = nil
            if entries[reference] == .loading { entries[reference] = nil }
        }
        let accountRef = accountRef
        let runtime = runtime

        let cached = try? await FFIExecutor.run {
            try runtime.cachedPublicEventPreviews(accountRef: accountRef, references: [reference]).first
        }
        guard !Task.isCancelled else { return }
        if let cached { await apply(cached, for: reference) }

        guard mayFetch(), !Task.isCancelled,
            let resolved = try? await runtime.resolvePublicEventPreview(accountRef: accountRef, reference: reference),
            !Task.isCancelled
        else { return }
        await apply(resolved, for: reference)
    }

    /// A present event replaces the card; a deletion retracts it for good. A miss changes nothing:
    /// MDK keeps prior content when a fetch comes back empty.
    private func apply(_ result: PublicEventPreviewFfi, for reference: String) async {
        switch result.state {
        case .present:
            guard let json = result.eventJson, let preview = NostrEventPreview.parse(eventJson: json) else {
                entries[reference] = .unavailable
                return
            }
            if entries[reference] != .loaded(preview) { entries[reference] = .loaded(preview) }
            await loadAuthor(preview.authorIdHex)
        case .deleted, .unsupported:
            entries[reference] = .unavailable
        case .missing:
            break
        }
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
