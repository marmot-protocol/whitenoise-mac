import AppKit

/// Writes the app-icon badge. `NSApp.dockTile` is the one badge macOS draws both in the Dock
/// and in the ⌘-Tab app switcher.
@MainActor
final class DockBadgeController {
    private let setLabel: @MainActor (String?) -> Void
    private var appliedLabel: String?

    init(setLabel: @escaping @MainActor (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 }) {
        self.setLabel = setLabel
    }

    /// `nil` means "not known right now" (an account switch, or an account MDK cannot total
    /// yet) and leaves the current badge alone; zero clears it.
    func apply(count: Int?) {
        guard let count else { return }
        let label = Self.label(forCount: count)
        guard label != appliedLabel else { return }
        appliedLabel = label
        setLabel(label)
    }

    /// Clears the badge when the account that was active is no longer signed in. Its total was
    /// what the badge showed, and the replacement scope may report `nil` (another account still
    /// unavailable) for a while; keeping the label would then show a signed-out account's count.
    /// An ordinary switch, where the previous account is still signed in, leaves the badge alone.
    func activeAccountDidChange(from previousAccountId: String?, signedInAccountIds: Set<String>) {
        guard let previousAccountId, !signedInAccountIds.contains(previousAccountId) else { return }
        apply(count: 0)
    }

    nonisolated static func label(forCount count: Int) -> String? {
        guard count > 0 else { return nil }
        return count.formatted(.number.grouping(.never))
    }
}
