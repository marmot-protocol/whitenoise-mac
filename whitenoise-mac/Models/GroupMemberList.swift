//
//  GroupMemberList.swift
//  whitenoise-mac
//
//  Which members the group info roster draws: a search over names and keys, and a short
//  preview of a long roster that expands on request. Mirrors `GroupMemberOrdering` in the
//  iOS client, so the two show the same six people first and search the same fields.
//

import Foundation

struct GroupMemberList: Equatable {
    /// How many members a collapsed roster shows before "See all". The search field appears
    /// only past this size too — a roster that fits needs no filtering.
    static let previewCount = 6

    let members: [GroupMemberItem]
    var query = ""
    var isExpanded = false

    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var showsSearchField: Bool {
        members.count > Self.previewCount
    }

    /// Members matching the query by display name, published name, or npub. Everyone when
    /// the query is blank.
    var matching: [GroupMemberItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return members }
        return members.filter { member in
            [member.displayName, member.publishedDisplayName ?? "", member.npub]
                .contains { $0.localizedStandardContains(needle) }
        }
    }

    /// The rows to draw. A search always shows every match; otherwise a long roster is cut to
    /// the preview until it is expanded.
    var visible: [GroupMemberItem] {
        let matching = matching
        guard !isSearching, !isExpanded, matching.count > Self.previewCount else { return matching }
        return Array(matching.prefix(Self.previewCount))
    }

    /// Whether the roster is cut short, and so owes a "See all" row.
    var isTruncated: Bool {
        visible.count < matching.count
    }
}
