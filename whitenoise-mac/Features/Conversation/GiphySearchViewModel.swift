import Foundation
import Observation

/// The GIF picker's state: one query, its results, each result's preview, and the send of
/// whichever result is chosen.
///
/// A result can only be sent once its preview has played. The envelope carries one rendition URL
/// and every recipient applies the same admission, so a rendition the sender's own client refused
/// would fail for everyone. Each preview walks the result's candidates until one is admitted, and
/// that is the one `select` sends.
///
/// A GIF is sent as the GIPHY text envelope (`RemoteGiphyMedia.wireText`), so the send is an
/// ordinary text send; `send` is injected so the picker can be previewed and tested without a
/// conversation behind it.
@MainActor
@Observable
final class GiphySearchViewModel {
    typealias Search = @Sendable (String) async throws -> [GiphySearchResult]
    typealias Send = @MainActor (RemoteGiphyMedia) async throws -> Void
    typealias Prepare = @Sendable (RemoteGiphyMedia) async throws -> GiphyRemoteMediaLoader.PreparedPlayback

    /// One result's preview. `playing` names the rendition that was admitted.
    enum Preview: Equatable {
        case loading
        case playing(RemoteGiphyMedia, GiphyRemoteMediaLoader.PreparedPlayback)
        case failed
        case unsupported

        var playableMedia: RemoteGiphyMedia? {
            if case .playing(let media, _) = self { media } else { nil }
        }
    }

    nonisolated static let debounce: Duration = .milliseconds(300)

    var query = ""
    private(set) var results: [GiphySearchResult] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var sendingResultID: GiphySearchResult.ID?
    private(set) var sendErrorMessage: String?

    @ObservationIgnored private let searchGIFs: Search
    private var previews: [GiphySearchResult.ID: Preview] = [:]

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let prepare: Prepare
    @ObservationIgnored private let cache: GiphyPlaybackCache
    @ObservationIgnored private let debounce: Duration

    init(
        search: @escaping Search,
        send: @escaping Send,
        prepare: @escaping Prepare = { try await GiphyRemoteMediaLoader.preparePlayback(for: $0) },
        cache: GiphyPlaybackCache? = nil,
        debounce: Duration = GiphySearchViewModel.debounce
    ) {
        self.searchGIFs = search
        self.send = send
        self.prepare = prepare
        self.cache = cache ?? .shared
        self.debounce = debounce
    }

    /// The preview to draw for `result`. A rendition this session already played comes up
    /// playing from the cache, without passing through the spinner.
    func preview(for result: GiphySearchResult) -> Preview {
        if let preview = previews[result.id] { return preview }
        for candidate in result.candidates {
            if let cached = cache.playback(for: candidate.url) { return .playing(candidate, cached) }
        }
        return .loading
    }

    /// Loads `result`'s preview, trying its candidates in order. Driven by the tile's `.task`, so
    /// a tile scrolled away cancels its load and a later appearance starts it again.
    func loadPreview(for result: GiphySearchResult) async {
        if case .playing = preview(for: result) { return }
        if previews[result.id] == .unsupported { return }
        previews[result.id] = .loading
        for candidate in result.candidates {
            do {
                let playback: GiphyRemoteMediaLoader.PreparedPlayback
                if let cached = cache.playback(for: candidate.url) {
                    playback = cached
                } else {
                    playback = try await prepare(candidate)
                    cache.insert(playback, for: candidate.url)
                }
                try Task.checkCancellation()
                previews[result.id] = .playing(candidate, playback)
                return
            } catch  where !Task.isCancelled && GiphyRemoteMediaLoader.isPermanent(error) {
                // Refused for good: the next rendition may still be admitted.
                continue
            } catch {
                if Task.isCancelled || error is CancellationError {
                    // A later appearance owns the preview now; let it start over.
                    previews[result.id] = nil
                } else {
                    // Transient: a smaller rendition is no likelier to download.
                    previews[result.id] = .failed
                }
                return
            }
        }
        previews[result.id] = .unsupported
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the current query after the debounce. Driven by the view's `.task(id: query)`, so a
    /// newer keystroke cancels the older search rather than racing it — no staleness counter.
    func searchAfterDebounce() async {
        let issuedQuery = trimmedQuery
        guard !issuedQuery.isEmpty else {
            results = []
            errorMessage = nil
            isLoading = false
            return
        }
        do {
            try await Task.sleep(for: debounce)
            isLoading = true
            errorMessage = nil
            let fetched = try await searchGIFs(issuedQuery)
            try Task.checkCancellation()
            results = fetched
            let ids = Set(fetched.map(\.id))
            previews = previews.filter { ids.contains($0.key) }
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            isLoading = false
            errorMessage = UserFacingError.message(for: error)
        }
    }

    /// Sends the rendition of `result` that played and reports whether it was accepted, so the
    /// picker closes only on success and a failure stays on screen next to what the user picked.
    /// A result whose preview has not played sends nothing.
    @discardableResult
    func select(_ result: GiphySearchResult) async -> Bool {
        guard sendingResultID == nil, let media = preview(for: result).playableMedia else { return false }
        sendingResultID = result.id
        sendErrorMessage = nil
        defer { sendingResultID = nil }
        do {
            try await send(media)
            return true
        } catch {
            sendErrorMessage = UserFacingError.message(for: error)
            return false
        }
    }
}
