//
//  SharedMediaPresentation.swift
//  whitenoise-mac
//
//  Which shared-media tiles group info draws, and how the full library groups them. Ported from
//  the iOS client's `GroupSharedMediaSection` and `SharedMediaLibraryPresentation`: group info
//  previews the most recent photos and videos on one scrollable row, and everything else lives
//  in the library one step further in.
//

import Foundation

enum SharedMediaStripPreview {
    /// How many tiles the group info row carries before the library takes over.
    static let previewCount = 9

    /// The newest photos and videos, in history order, cut to the strip's length.
    static func visible<Item>(_ items: [Item]) -> [Item] {
        Array(items.prefix(previewCount))
    }
}

/// One month of the library's media grid.
struct SharedMediaMonthSection<Item: Identifiable>: Identifiable where Item.ID == String {
    let id: String
    let title: String
    var items: [Item]
}

enum SharedMediaMonthGrouping {
    /// Contiguous month runs, in the order history hands the items over. Two runs of the same
    /// month stay separate rather than being merged, so a timestamp that moves backward never
    /// reorders what the core sorted.
    ///
    /// `timestamp` is seconds since 1970; zero means the item carries no date and lands under
    /// "Recent".
    static func sections<Item: Identifiable>(
        _ items: [Item],
        timestamp: (Item) -> UInt64,
        calendar: Calendar = .current,
        locale: Locale
    ) -> [SharedMediaMonthSection<Item>] where Item.ID == String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMM y")

        var sections: [SharedMediaMonthSection<Item>] = []
        var previousKey: String?
        for item in items {
            let key: String
            let title: String
            let seconds = timestamp(item)
            if seconds > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(seconds))
                let components = calendar.dateComponents([.year, .month], from: date)
                key = "\(components.year ?? 0)-\(components.month ?? 0)"
                title = formatter.string(from: date)
            } else {
                key = "undated"
                title = L10n.string("Recent")
            }
            if previousKey == key, !sections.isEmpty {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append(SharedMediaMonthSection(id: "\(key):\(item.id)", title: title, items: [item]))
                previousKey = key
            }
        }
        return sections
    }
}

/// What the full-pane media viewer pages through: every loaded photo and video it can actually
/// show, opened at the one that was clicked.
struct SharedMediaViewerPresentation: Identifiable, Equatable {
    let id: String
    let items: [RetainedAttachmentItem]
    let initialIndex: Int

    /// `nil` when the clicked item has nothing to show — a rejected attachment, or one that is
    /// not a photo or video.
    init?(items: [RetainedAttachmentItem], initial: RetainedAttachmentItem) {
        let viewable = items.filter { $0.isVisualMedia && $0.reference != nil }
        guard let initialIndex = viewable.firstIndex(where: { $0.id == initial.id }) else { return nil }
        self.id = "shared-media-viewer:\(initial.id)"
        self.items = viewable
        self.initialIndex = initialIndex
    }
}
