import Foundation

/// Fetches the bytes for an image the user picked out of search results.
protocol GroupImageSourceLoading {
    func data(for url: URL) async -> Data?
}
