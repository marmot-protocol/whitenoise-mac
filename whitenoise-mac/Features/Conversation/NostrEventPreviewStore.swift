import Foundation
import MarmotKit
import Observation

/// The public Nostr events one conversation's messages link, and their authors, for the cards
/// drawn under those messages.
///
/// MDK owns the fetch, the signature check and the cache (`resolvePublicEventPreview`); this
/// reads its cached copy first so a card already seen draws at once, then asks it to refresh.
/// The relay fetch queries relays the message's sender chose, so the card only asks for it while
/// "Show Link Previews" is on.
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
        /// Deleted by its author, not found, or not an event: no card, the link stays a link.
        case unavailable
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var authors: [String: Author] = [:]

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private let profileRelays: [String]
    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var authorLoads: [String: Task<Void, Never>] = [:]

    init(accountRef: String, runtime: any MarmotRuntime, profileRelays: [String] = MarmotClient.accountRelays) {
        self.accountRef = accountRef
        self.runtime = runtime
        self.profileRelays = profileRelays
    }

    func entry(for reference: String) -> Entry? {
        entries[reference]
    }

    func author(_ accountIdHex: String) -> Author? {
        authors[accountIdHex]
    }

    /// Reads, then refreshes, `reference` unless it is loaded, loading, or known to be unavailable.
    func load(_ reference: String) {
        guard entries[reference] == nil, loads[reference] == nil else { return }
        entries[reference] = .loading
        loads[reference] = Task { [weak self] in
            await self?.fetch(reference)
        }
    }

    /// The conversation is going away: stop every fetch. A cut-short load is forgotten, so the
    /// next `load` starts over.
    func cancelAll() {
        for task in loads.values { task.cancel() }
        for task in authorLoads.values { task.cancel() }
        for (reference, _) in loads where entries[reference] == .loading {
            entries[reference] = nil
        }
        loads.removeAll()
        authorLoads.removeAll()
    }

    private func fetch(_ reference: String) async {
        defer { loads[reference] = nil }
        let accountRef = accountRef
        let runtime = runtime

        let cached = try? await FFIExecutor.run {
            try runtime.cachedPublicEventPreviews(accountRef: accountRef, references: [reference]).first
        }
        guard !Task.isCancelled else { return }
        if let cached, let preview = Self.preview(from: cached) {
            apply(.loaded(preview), for: reference)
        }

        let resolved: PublicEventPreviewFfi
        do {
            resolved = try await runtime.resolvePublicEventPreview(accountRef: accountRef, reference: reference)
        } catch {
            guard !Task.isCancelled else { return }
            // A failed fetch keeps whatever the cache had; with nothing cached there is no card.
            if entries[reference] == .loading { entries[reference] = .unavailable }
            return
        }
        guard !Task.isCancelled else { return }
        if let preview = Self.preview(from: resolved) {
            apply(.loaded(preview), for: reference)
        } else if resolved.state == .deleted || entries[reference] == .loading {
            // A deletion retracts a card already drawn from the cache; a miss only means no card.
            entries[reference] = .unavailable
        }
    }

    private func apply(_ entry: Entry, for reference: String) {
        guard entries[reference] != entry else { return }
        entries[reference] = entry
        if case .loaded(let preview) = entry {
            loadAuthor(preview.authorIdHex)
        }
    }

    nonisolated static func preview(from result: PublicEventPreviewFfi) -> NostrEventPreview? {
        guard result.state == .present, let json = result.eventJson else { return nil }
        return NostrEventPreview.parse(eventJson: json)
    }

    /// The author's name and picture: MDK's local copy, or one relay lookup when it has none.
    private func loadAuthor(_ accountIdHex: String) {
        guard authors[accountIdHex] == nil, authorLoads[accountIdHex] == nil else { return }
        authorLoads[accountIdHex] = Task { [weak self] in
            await self?.fetchAuthor(accountIdHex)
        }
    }

    private func fetchAuthor(_ accountIdHex: String) async {
        defer { authorLoads[accountIdHex] = nil }
        let runtime = runtime
        let read = { try? await FFIExecutor.run { try runtime.userProfile(accountIdHex: accountIdHex) } }
        var profile = await read() ?? nil
        if profile == nil {
            guard !Task.isCancelled else { return }
            try? await runtime.refreshProfile(accountIdHex: accountIdHex, relays: profileRelays)
            guard !Task.isCancelled else { return }
            profile = await read() ?? nil
        }
        guard !Task.isCancelled else { return }
        authors[accountIdHex] = Self.author(from: profile)
    }

    nonisolated static func author(from profile: UserProfileMetadataFfi?) -> Author {
        let name = PeerDisplayText.sanitize(profile?.displayName) ?? PeerDisplayText.sanitize(profile?.name)
        return Author(
            name: name.map { String($0.prefix(64)) },
            pictureURL: RemoteImageURLPolicy.sanitizedURL(from: profile?.picture)
        )
    }
}
