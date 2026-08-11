import Foundation

extension Collection {
    /// Removes duplicates by `key`, keeping the **last** occurrence of each key and preserving the
    /// relative order of the kept elements.
    ///
    /// Last-wins is the semantic the FFI delta paths need: a refreshed chat row or timeline message
    /// arrives after the stale one it supersedes, so the later copy is the current truth.
    ///
    /// `nonisolated` is load-bearing: the target builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it this extension would inherit
    /// main-actor isolation and could not be called from the off-main FFI paths that produce those
    /// deltas.
    nonisolated func uniquedLastWins<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seenKeys = Set<Key>()
        var result: [Element] = []
        result.reserveCapacity(count)

        for element in reversed() {
            guard seenKeys.insert(key(element)).inserted else { continue }
            result.append(element)
        }

        return Array(result.reversed())
    }
}
