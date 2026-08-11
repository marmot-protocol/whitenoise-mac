import Foundation

struct SecureGroupImageSourceLoader: GroupImageSourceLoading {
    func data(for url: URL) async -> Data? {
        await RemoteImageLoader.shared.data(for: url)
    }
}
