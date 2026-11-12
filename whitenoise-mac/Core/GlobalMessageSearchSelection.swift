import Foundation

/// Keyboard selection in the "Search all messages" results: which row ↓ / ↑ highlight and Return
/// opens. The selection is a result id rather than an index, so a refreshed result list keeps the
/// reader on the same message when it is still there.
nonisolated enum GlobalMessageSearchSelection {
    /// ↓: the first result when nothing is selected yet, otherwise the next one, stopping at the last.
    static func next(after selected: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else { return ids.first }
        return ids[min(index + 1, ids.count - 1)]
    }

    /// ↑: the previous result, stopping at the first. Nothing selected stays nothing selected, so
    /// the key falls through to the search field.
    static func previous(before selected: String?, in ids: [String]) -> String? {
        guard let selected, let index = ids.firstIndex(of: selected) else { return nil }
        return ids[max(index - 1, 0)]
    }

    /// After the results are replaced, keep the selection only when its message is still listed.
    /// While a search is still running the list is a placeholder — a refresh empties it before the
    /// new results land — so the selection is left alone until the completed results arrive.
    static func reanchored(_ selected: String?, in ids: [String], whileSearching: Bool = false) -> String? {
        guard !whileSearching else { return selected }
        guard let selected, ids.contains(selected) else { return nil }
        return selected
    }
}
