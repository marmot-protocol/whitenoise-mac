import CoreGraphics
import Foundation

/// The GIFs this session has already downloaded and validated, and where each one's animation was
/// last seen.
///
/// Transcript cells are recycled, and every change to the row list reloads the table, so a GIF
/// bubble is rebuilt with fresh view state far more often than it scrolls. Each rebuild used to
/// show "Load GIF" or a spinner for a moment, fetch the bytes again, and restart the animation at
/// its first frame — the GIF visibly re-rendered. A rebuilt bubble reads its playback from here
/// synchronously instead, and its player resumes from the frame that was on screen.
@MainActor
final class GiphyPlaybackCache {
    static let shared = GiphyPlaybackCache()

    /// Where an animation was: the frame ImageIO last delivered, and its image, so a rebuilt
    /// player can draw that frame before its first tick instead of an empty box.
    struct Position {
        let frameIndex: Int
        let image: CGImage
    }

    private final class Entry {
        let playback: GiphyRemoteMediaLoader.PreparedPlayback
        var position: Position?

        init(playback: GiphyRemoteMediaLoader.PreparedPlayback) {
            self.playback = playback
        }
    }

    private let entries = NSCache<NSURL, Entry>()

    /// - Parameter totalCostLimit: the encoded bytes past which `NSCache` starts evicting. It is
    ///   a threshold, not a hard cap: the cache may sit above it for a while. GIFs are capped at
    ///   `GiphySearchClient.maximumMediaBytes` each. The cost counts encoded bytes only: each
    ///   entry also keeps the one decoded frame its `Position` was recorded at.
    init(totalCostLimit: Int = 48 * 1_024 * 1_024) {
        entries.totalCostLimit = totalCostLimit
    }

    func playback(for url: URL) -> GiphyRemoteMediaLoader.PreparedPlayback? {
        entries.object(forKey: url as NSURL)?.playback
    }

    /// Stores `playback` for `url`. Storing the same playback again keeps its position.
    func insert(_ playback: GiphyRemoteMediaLoader.PreparedPlayback, for url: URL) {
        guard entries.object(forKey: url as NSURL)?.playback != playback else { return }
        entries.setObject(Entry(playback: playback), forKey: url as NSURL, cost: playback.data.count)
    }

    func position(for url: URL) -> Position? {
        entries.object(forKey: url as NSURL)?.position
    }

    /// Records where `url`'s animation is. Ignored when the playback itself is not cached: a
    /// position is only meaningful for the bytes it was read from.
    func record(_ position: Position, for url: URL) {
        entries.object(forKey: url as NSURL)?.position = position
    }
}
