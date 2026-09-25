import Foundation
import Observation

/// The GIF picker's state: one query, its results, and the send of whichever result is chosen.
///
/// A GIF is sent as the GIPHY text envelope (`RemoteGiphyMedia.wireText`), so the send is an
/// ordinary text send; `send` is injected so the picker can be previewed and tested without a
/// conversation behind it.
@MainActor
@Observable
final class GiphySearchViewModel {
    typealias Search = @Sendable (String) async throws -> [GiphySearchResult]
    typealias Send = @MainActor (RemoteGiphyMedia) async throws -> Void

    nonisolated static let debounce: Duration = .milliseconds(300)

    var query = ""
    private(set) var results: [GiphySearchResult] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var sendingResultID: GiphySearchResult.ID?
    private(set) var sendErrorMessage: String?

    @ObservationIgnored private let searchGIFs: Search
    @ObservationIgnored private let send: Send
    @ObservationIgnored private let debounce: Duration

    init(search: @escaping Search, send: @escaping Send, debounce: Duration = GiphySearchViewModel.debounce) {
        self.searchGIFs = search
        self.send = send
        self.debounce = debounce
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
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    /// Sends `result` and reports whether it was accepted, so the picker closes only on success
    /// and a failure stays on screen next to what the user picked.
    @discardableResult
    func select(_ result: GiphySearchResult) async -> Bool {
        guard sendingResultID == nil else { return false }
        sendingResultID = result.id
        sendErrorMessage = nil
        defer { sendingResultID = nil }
        do {
            try await send(result.media)
            return true
        } catch {
            sendErrorMessage = error.localizedDescription
            return false
        }
    }
}
