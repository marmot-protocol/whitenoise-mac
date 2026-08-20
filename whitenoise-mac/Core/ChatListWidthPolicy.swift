//
//  ChatListWidthPolicy.swift
//  whitenoise-mac
//
//  The one rule for how wide the chat-list drawer may be, so the resize handle,
//  the restored preference and the collapsed-row rendering can never disagree
//  about what "collapsed" means.
//

import CoreGraphics
import Foundation

/// Widths the chat-list drawer is allowed to take, and the snap that turns a drag
/// into one of them.
///
/// There are deliberately only two regimes, not one continuous range: a *full* row
/// (avatar, title, timestamp, preview) between `minimumExpandedWidth` and
/// `maximumWidth`, and an *avatar-only* rail at `collapsedWidth`. Nothing renders in
/// between, because the widths in between are exactly the ones where a group name
/// truncates mid-word — the drawer would technically still fit the title column and
/// would spend it on three clipped characters. Dragging past `collapseThreshold`
/// therefore snaps: the row changes kind rather than shrinking further.
nonisolated enum ChatListWidthPolicy {
    /// Avatar-only rail: the 46pt row avatar plus the list's own horizontal padding
    /// (8 on the `LazyVStack`, 6 on the collapsed row) on both sides.
    static let collapsedWidth: CGFloat = 84
    /// Narrowest full row: measured as the width at which the title column still holds a
    /// short group name whole next to its timestamp. Below it names like "Search Load 4"
    /// start ellipsizing, which is the thing the rail exists to avoid. It sits 30pt further
    /// out than the same measurement gave before the type ramp landed, which is the ladder's
    /// sizes rather than its face: moving off the bundled Manrope onto the system face buys
    /// back under 8pt across the title and the widest timestamp together, so the threshold
    /// stays where it is. Re-measure here (`ImageRenderer` over `ChatRowContent`) if the
    /// ramp's *sizes* move.
    static let minimumExpandedWidth: CGFloat = 250
    /// The width the drawer shipped at, kept as the widest allowed so the detail
    /// pane never loses room it had before the drawer became resizable.
    static let maximumWidth: CGFloat = 300
    static let defaultWidth: CGFloat = maximumWidth

    /// Midpoint between the two regimes: a drag crossing it collapses, and a drag
    /// back across it restores the narrowest full row. One threshold in both
    /// directions (rather than separate collapse/expand thresholds) keeps the
    /// handle's position predictable — where you let go is where it snapped.
    static let collapseThreshold: CGFloat = (collapsedWidth + minimumExpandedWidth) / 2

    /// Resolves a dragged width to an allowed one.
    ///
    /// `allowsCollapse` is false while the drawer is showing something other than the
    /// chat list (settings, the compose flow): those panes have no avatar-only form, so
    /// a drag there bottoms out at `minimumExpandedWidth` instead of snapping shut.
    static func resolve(proposedWidth: CGFloat, allowsCollapse: Bool = true) -> CGFloat {
        guard proposedWidth.isFinite else { return defaultWidth }
        if allowsCollapse, proposedWidth < collapseThreshold { return collapsedWidth }
        return min(max(proposedWidth, minimumExpandedWidth), maximumWidth)
    }

    static func isCollapsed(width: CGFloat) -> Bool {
        width < minimumExpandedWidth
    }

    /// One keyboard/VoiceOver step of the handle.
    static let stepIncrement: CGFloat = 20

    enum Step {
        case narrower
        case wider
    }

    /// Steps between allowed widths for an accessibility adjustment. This cannot go through
    /// `resolve` alone: from `minimumExpandedWidth`, `resolve(220 - 20)` clamps straight back
    /// to 220, so the collapsed rail would be unreachable without a pointer. The narrowest
    /// full width therefore steps *to* the rail, and the rail steps back to it.
    static func stepped(from width: CGFloat, toward step: Step, allowsCollapse: Bool = true) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        switch step {
        case .narrower:
            if isCollapsed(width: width) { return collapsedWidth }
            if width <= minimumExpandedWidth {
                return allowsCollapse ? collapsedWidth : minimumExpandedWidth
            }
            return max(minimumExpandedWidth, width - stepIncrement)
        case .wider:
            if isCollapsed(width: width) { return minimumExpandedWidth }
            return min(maximumWidth, width + stepIncrement)
        }
    }

    /// Restores a persisted width. A missing key means "never resized", which is the
    /// default width — *not* `resolve(0)`, which would read an absent preference as a
    /// collapsed drawer.
    static func restored(storedWidth: Double?) -> CGFloat {
        guard let storedWidth else { return defaultWidth }
        return resolve(proposedWidth: CGFloat(storedWidth))
    }
}
