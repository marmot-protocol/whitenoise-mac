//
//  SharedMediaGridPreview.swift
//  whitenoise-mac
//
//  Which tiles the group info media grid draws: a three-by-three preview of a long history
//  that expands on request, the same way the member roster previews its first six people.
//

import Foundation

struct SharedMediaGridPreview<Item> {
    /// How many tiles a collapsed grid shows before "View more" — three full rows of three.
    static var previewCount: Int { 9 }

    let items: [Item]
    var isExpanded = false

    /// The tiles to draw. A long grid is cut to the preview until it is expanded.
    var visible: [Item] {
        guard !isExpanded, items.count > Self.previewCount else { return items }
        return Array(items.prefix(Self.previewCount))
    }

    /// Whether the grid is cut short, and so owes a "View more" row.
    var isTruncated: Bool {
        visible.count < items.count
    }

    /// Whether an expanded grid is long enough to be worth collapsing again.
    var canCollapse: Bool {
        isExpanded && items.count > Self.previewCount
    }

    /// Paging in older history only makes sense once every loaded tile is on screen; while the
    /// preview hides some, "View more" is the next step instead.
    func showsLoadMore(hasMore: Bool) -> Bool {
        hasMore && !isTruncated
    }
}
