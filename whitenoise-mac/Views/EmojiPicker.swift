import Combine
import Foundation
import SwiftUI

nonisolated struct ChatEmojiCatalogEntry: Codable, Identifiable, Hashable, Sendable {
    let emoji: String
    let name: String
    let group: Int
    let keywords: [String]

    var id: String { emoji }

    enum CodingKeys: String, CodingKey {
        case emoji = "e"
        case name = "n"
        case group = "g"
        case keywords = "k"
    }
}

nonisolated struct ChatEmojiCatalog: Sendable {
    let entries: [ChatEmojiCatalogEntry]

    private let lookup: [String: ChatEmojiCatalogEntry]
    private let entriesByGroup: [Int: [ChatEmojiCatalogEntry]]
    fileprivate let searchEntries: [ChatEmojiSearchEntry]

    init(entries: [ChatEmojiCatalogEntry]) {
        self.entries = entries
        lookup = Dictionary(entries.map { ($0.emoji, $0) }, uniquingKeysWith: { first, _ in first })
        entriesByGroup = Dictionary(grouping: entries, by: \.group)
        searchEntries = entries.map(ChatEmojiSearchEntry.init)
    }

    static let empty = ChatEmojiCatalog(entries: [])

    func entries(forGroup group: Int) -> [ChatEmojiCatalogEntry] {
        entriesByGroup[group] ?? []
    }

    func recents(from emojiOrder: [String]) -> [ChatEmojiCatalogEntry] {
        emojiOrder.compactMap { lookup[$0] }
    }
}

nonisolated fileprivate struct ChatEmojiSearchEntry: Sendable {
    let entry: ChatEmojiCatalogEntry
    let name: String
    let keywords: [String]

    init(entry: ChatEmojiCatalogEntry) {
        self.entry = entry
        name = entry.name.lowercased()
        keywords = entry.keywords.map { $0.lowercased() }
    }
}

nonisolated enum ChatEmojiSearch {
    static func results(
        in catalog: ChatEmojiCatalog,
        query: String,
        limit: Int = 160
    ) -> [ChatEmojiCatalogEntry] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return Array(catalog.entries.prefix(limit)) }

        return catalog.searchEntries.compactMap { indexed -> (ChatEmojiCatalogEntry, Int)? in
            var score = 0
            for term in terms {
                if indexed.name == term {
                    score += 100
                } else if indexed.name.hasPrefix(term) {
                    score += 60
                } else if indexed.name.contains(term) {
                    score += 35
                } else if indexed.keywords.contains(term) {
                    score += 25
                } else if indexed.keywords.contains(where: { $0.hasPrefix(term) }) {
                    score += 12
                } else if indexed.entry.emoji == term {
                    score += 100
                } else {
                    return nil
                }
            }
            return (indexed.entry, score)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.name < $1.0.name
        }
        .prefix(limit)
        .map(\.0)
    }
}

private struct ChatEmojiCategory: Identifiable {
    let id: Int
    let titleKey: String
    let systemImage: String

    var title: String { L10n.string(titleKey) }

    static let all = [
        Self(id: 0, titleKey: "Smileys & People", systemImage: "face.smiling"),
        Self(id: 1, titleKey: "People & Body", systemImage: "person.fill"),
        Self(id: 2, titleKey: "Animals & Nature", systemImage: "pawprint.fill"),
        Self(id: 3, titleKey: "Food & Drink", systemImage: "fork.knife"),
        Self(id: 4, titleKey: "Travel & Places", systemImage: "car.fill"),
        Self(id: 5, titleKey: "Activities", systemImage: "soccerball"),
        Self(id: 6, titleKey: "Objects", systemImage: "lightbulb.fill"),
        Self(id: 7, titleKey: "Symbols", systemImage: "heart.fill"),
        Self(id: 8, titleKey: "Flags", systemImage: "flag.fill"),
    ]
}

@MainActor
private final class ChatEmojiPickerModel: ObservableObject {
    @Published private(set) var catalog = ChatEmojiCatalog.empty
    @Published private(set) var searchResults: [ChatEmojiCatalogEntry] = []
    @Published private(set) var didFail = false

    private static var cachedCatalog: ChatEmojiCatalog?
    private var loadTask: Task<ChatEmojiCatalog, Error>?

    func load() async {
        guard catalog.entries.isEmpty else { return }
        if let cachedCatalog = Self.cachedCatalog {
            catalog = cachedCatalog
            return
        }
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json") else {
            didFail = true
            return
        }
        let task: Task<ChatEmojiCatalog, Error>
        if let loadTask {
            task = loadTask
        } else {
            let newTask = Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let entries = try JSONDecoder().decode([ChatEmojiCatalogEntry].self, from: data)
                return ChatEmojiCatalog(entries: entries)
            }
            loadTask = newTask
            task = newTask
        }
        do {
            let catalog = try await task.value
            loadTask = nil
            Self.cachedCatalog = catalog
            self.catalog = catalog
        } catch {
            loadTask = nil
            didFail = true
        }
    }

    func search(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }
        let catalog = self.catalog
        let results = await Task.detached(priority: .userInitiated) {
            ChatEmojiSearch.results(in: catalog, query: query)
        }.value
        guard !Task.isCancelled else { return }
        searchResults = results
    }
}

enum ChatEmojiRecents {
    static let key = "chat.emoji-picker.recents"
    static let maximumCount = 40

    static func values(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? ChatReactionDefaults.quick
    }

    @discardableResult
    static func record(_ emoji: String, defaults: UserDefaults = .standard) -> [String] {
        var result = values(defaults: defaults).filter { $0 != emoji }
        result.insert(emoji, at: 0)
        let stored = Array(result.prefix(maximumCount))
        defaults.set(stored, forKey: key)
        return stored
    }
}

private enum ChatEmojiRailSelection: Hashable {
    case custom
    case recent
    case category(Int)
}

struct ChatEmojiPicker: View {
    let disabledEmoji: Set<String>
    /// Custom emoji and emoji sets, offered where a pick can send one: a conversation's composer and
    /// reactions. A custom pick reaches `onPick` as its `:shortcode:` token.
    let custom: CustomEmojiPickerContent?
    let onPick: (String) -> Void

    @StateObject private var model = ChatEmojiPickerModel()
    @State private var query = ""
    @State private var selectedRail: ChatEmojiRailSelection = .category(0)
    @State private var recentEmoji = ChatReactionDefaults.quick
    @State private var isBrowsingEmojiSets = false

    init(
        disabledEmoji: Set<String> = [],
        custom: CustomEmojiPickerContent? = nil,
        onPick: @escaping (String) -> Void
    ) {
        self.disabledEmoji = disabledEmoji
        self.custom = custom
        self.onPick = onPick
    }

    var body: some View {
        Group {
            if isBrowsingEmojiSets, let library = custom?.emojiSets {
                EmojiSetBrowser(library: library, onBack: { isBrowsingEmojiSets = false })
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        ChatEmojiSearchField(query: $query)
                        Divider()
                        ChatEmojiGridContent(
                            model: model,
                            query: query,
                            recentEmoji: recentEmoji,
                            disabledEmoji: disabledEmoji,
                            custom: custom,
                            onPickStandard: { emoji in
                                recentEmoji = ChatEmojiRecents.record(emoji)
                                onPick(emoji)
                            },
                            onPickCustom: { onPick($0.token) },
                            onManageSets: { isBrowsingEmojiSets = true }
                        )
                        Divider()
                        ChatEmojiCategoryRail(
                            hasCustom: custom != nil,
                            selection: $selectedRail,
                            proxy: proxy
                        )
                    }
                }
            }
        }
        .frame(width: 420, height: 430)
        .task {
            recentEmoji = ChatEmojiRecents.values()
        }
        .task {
            await custom?.emojiSets?.loadInstalledIfNeeded()
        }
        .task(id: query) {
            await model.load()
            await model.search(query: query)
        }
    }
}

private struct ChatEmojiSearchField: View {
    @Binding var query: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n.string("Search emoji"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onExitCommand {
                    if !query.isEmpty { query = "" }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("Clear search"))
                .accessibilityLabel(L10n.string("Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { isFocused = true }
    }
}

private struct ChatEmojiGridContent: View {
    @ObservedObject var model: ChatEmojiPickerModel
    let query: String
    let recentEmoji: [String]
    let disabledEmoji: Set<String>
    let custom: CustomEmojiPickerContent?
    let onPickStandard: (String) -> Void
    let onPickCustom: (CustomEmojiSendable) -> Void
    let onManageSets: () -> Void

    var body: some View {
        if model.catalog.entries.isEmpty, !model.didFail {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.didFail {
            ContentUnavailableView("Emoji unavailable", systemImage: "face.dashed")
        } else {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let customMatches = trimmed.isEmpty ? [] : (custom?.matching(query) ?? [])
            if !trimmed.isEmpty, customMatches.isEmpty, model.searchResults.isEmpty {
                WNEmptyStateView(
                    title: L10n.string("No Results"),
                    systemImage: "magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                        if let custom {
                            if trimmed.isEmpty {
                                let groups = CustomEmojiSendCatalog.pickerGroups(custom.sendables)
                                ForEach(groups) { group in
                                    CustomEmojiPickerSection(
                                        title: group.title, emoji: group.emoji, content: custom,
                                        disabledEmoji: disabledEmoji, onPick: onPickCustom
                                    )
                                    // The rail's Custom Emoji control scrolls to the first group.
                                    .id(group.id == groups.first?.id ? "custom" : "custom-\(group.id)")
                                }
                                if custom.emojiSets != nil {
                                    CustomEmojiManageSetsButton(action: onManageSets)
                                }
                            } else if !customMatches.isEmpty {
                                CustomEmojiPickerSection(
                                    title: L10n.string("Custom Emoji"), emoji: customMatches, content: custom,
                                    disabledEmoji: disabledEmoji, onPick: onPickCustom)
                            }
                        }
                        if trimmed.isEmpty {
                            let recents = model.catalog.recents(from: recentEmoji)
                            if !recents.isEmpty {
                                ChatEmojiSection(
                                    title: L10n.string("Recently used"),
                                    entries: recents,
                                    disabledEmoji: disabledEmoji,
                                    onPick: onPickStandard
                                )
                                .id("recent")
                            }
                            ForEach(ChatEmojiCategory.all) { category in
                                ChatEmojiSection(
                                    title: category.title,
                                    entries: model.catalog.entries(forGroup: category.id),
                                    disabledEmoji: disabledEmoji,
                                    onPick: onPickStandard
                                )
                                .id("category-\(category.id)")
                            }
                        } else if !model.searchResults.isEmpty {
                            ChatEmojiSection(
                                title: L10n.string("Search results"),
                                entries: model.searchResults,
                                disabledEmoji: disabledEmoji,
                                onPick: onPickStandard
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct ChatEmojiSection: View {
    let title: String
    let entries: [ChatEmojiCatalogEntry]
    let disabledEmoji: Set<String>
    let onPick: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(entries) { entry in
                    ChatEmojiGridCell(
                        entry: entry,
                        isDisabled: disabledEmoji.contains(entry.emoji),
                        onPick: { onPick(entry.emoji) }
                    )
                }
            }
        } header: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }
}

private struct ChatEmojiGridCell: View {
    let entry: ChatEmojiCatalogEntry
    let isDisabled: Bool
    let onPick: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onPick) {
            Text(entry.emoji)
                .font(.system(size: 24))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(
                    isHovering && !isDisabled ? WNColor.fillSecondaryHover : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.28 : 1)
        .onHover { isHovering = $0 }
        .help(entry.name)
        .accessibilityLabel(entry.name)
    }
}

private struct ChatEmojiCategoryRail: View {
    let hasCustom: Bool
    @Binding var selection: ChatEmojiRailSelection
    let proxy: ScrollViewProxy

    var body: some View {
        HStack(spacing: 2) {
            if hasCustom {
                ChatEmojiRailButton(
                    systemImage: "sparkles",
                    label: L10n.string("Custom Emoji"),
                    selected: selection == .custom
                ) {
                    selection = .custom
                    proxy.scrollTo("custom", anchor: .top)
                }
            }
            ChatEmojiRailButton(
                systemImage: "clock.fill",
                label: L10n.string("Recently used"),
                selected: selection == .recent
            ) {
                selection = .recent
                proxy.scrollTo("recent", anchor: .top)
            }
            ForEach(ChatEmojiCategory.all) { category in
                ChatEmojiRailButton(
                    systemImage: category.systemImage,
                    label: category.title,
                    selected: selection == .category(category.id)
                ) {
                    selection = .category(category.id)
                    proxy.scrollTo("category-\(category.id)", anchor: .top)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
    }
}

private struct ChatEmojiRailButton: View {
    let systemImage: String
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.medium))
                .foregroundStyle(
                    selected ? WNColor.textPrimary : Color(nsColor: .secondaryLabelColor)
                )
                .frame(width: 34, height: 28)
                .background(
                    selected || isHovering ? WNColor.fillSecondary : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview("Emoji picker") {
    ChatEmojiPicker(onPick: { _ in })
}
