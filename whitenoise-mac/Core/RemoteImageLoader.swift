import SwiftUI
import AppKit
import ImageIO

/// An NSImage wrapper that is safe to hand back from the background loader.
struct LoadedImage: @unchecked Sendable {
    let nsImage: NSImage
}

/// Drop-in replacement for `AsyncImage` that loads a remote image once, downsamples it
/// to the size it is actually displayed at (off the main thread), and caches the decoded
/// result. Bare `AsyncImage` re-fetches and decodes the full-resolution image on the main
/// thread every time a row reappears, which is wasteful across the chat list and settings
/// avatars. On any failure it shows `placeholder`.
struct DownsampledAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let maxPixelSize: CGFloat
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: Image?

    var body: some View {
        ZStack {
            if let image {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: TaskKey(url: url, size: maxPixelSize)) {
            image = nil
            guard let url else { return }
            if let loaded = await RemoteImageLoader.shared.image(for: url, maxPixelSize: maxPixelSize) {
                image = Image(nsImage: loaded.nsImage)
            }
        }
    }

    private struct TaskKey: Equatable {
        let url: URL?
        let size: CGFloat
    }
}

/// Shared image cache + downsampling pipeline. `NSCache` is thread-safe, so this needs no
/// actor; the heavy decode/resize runs in a detached task off the main thread.
nonisolated final class RemoteImageLoader: @unchecked Sendable {
    static let shared = RemoteImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    func image(for url: URL, maxPixelSize: CGFloat) async -> LoadedImage? {
        let key = "\(url.absoluteString)|\(Int(maxPixelSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return LoadedImage(nsImage: cached)
        }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        let pixelSize = maxPixelSize
        let loaded = await Task.detached(priority: .utility) {
            Self.downsample(data: data, maxPixelSize: pixelSize).map(LoadedImage.init)
        }.value
        guard let loaded else { return nil }
        cache.setObject(loaded.nsImage, forKey: key)
        return loaded
    }

    private static func downsample(data: Data, maxPixelSize: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(1, maxPixelSize))
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
