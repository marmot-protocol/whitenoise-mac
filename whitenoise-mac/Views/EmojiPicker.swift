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

struct ChatEmojiPicker: View {
    let disabledEmoji: Set<String>
    let onPick: (String) -> Void

    @StateObject private var model = ChatEmojiPickerModel()
    @State private var query = ""
    @State private var selectedCategory = 0
    @State private var recentEmoji = ChatReactionDefaults.quick

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    init(
        disabledEmoji: Set<String> = [],
        onPick: @escaping (String) -> Void
    ) {
        self.disabledEmoji = disabledEmoji
        self.onPick = onPick
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                searchField
                Divider()
                emojiGrid
                Divider()
                categoryRail(proxy: proxy)
            }
        }
        .frame(width: 420, height: 430)
        .background(.regularMaterial)
        .task {
            recentEmoji = ChatEmojiRecents.values()
        }
        .task(id: query) {
            await model.load()
            await model.search(query: query)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WNColor.backgroundContentSecondary)
            TextField(L10n.string("Search emoji"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Clear search"))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(WNColor.fillSecondary, in: Capsule())
        .padding(10)
    }

    @ViewBuilder
    private var emojiGrid: some View {
        if model.catalog.entries.isEmpty, !model.didFail {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.didFail {
            ContentUnavailableView("Emoji unavailable", systemImage: "face.dashed")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    if query.isEmpty {
                        let recents = model.catalog.recents(from: recentEmoji)
                        if !recents.isEmpty {
                            emojiSection(title: L10n.string("Recently used"), entries: recents)
                                .id("recent")
                        }
                        ForEach(ChatEmojiCategory.all) { category in
                            emojiSection(
                                title: category.title,
                                entries: model.catalog.entries(forGroup: category.id)
                            )
                            .id("category-\(category.id)")
                        }
                    } else {
                        emojiSection(
                            title: L10n.string("Search results"),
                            entries: model.searchResults
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }

    private func emojiSection(title: String, entries: [ChatEmojiCatalogEntry]) -> some View {
        Section {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(entries) { entry in
                    Button {
                        recentEmoji = ChatEmojiRecents.record(entry.emoji)
                        onPick(entry.emoji)
                    } label: {
                        Text(entry.emoji)
                            .wnFont(.medium24)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(disabledEmoji.contains(entry.emoji))
                    .opacity(disabledEmoji.contains(entry.emoji) ? 0.28 : 1)
                    .accessibilityLabel(entry.name)
                }
            }
        } header: {
            Text(title)
                .wnFont(.semiBold10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }

    private func categoryRail(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 2) {
            railButton(
                systemImage: "clock.fill",
                label: L10n.string("Recently used"),
                selected: false
            ) {
                proxy.scrollTo("recent", anchor: .top)
            }
            ForEach(ChatEmojiCategory.all) { category in
                railButton(
                    systemImage: category.systemImage,
                    label: category.title,
                    selected: selectedCategory == category.id
                ) {
                    selectedCategory = category.id
                    proxy.scrollTo("category-\(category.id)", anchor: .top)
                }
                .help(category.title)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(WNColor.backgroundSecondary.opacity(0.92))
    }

    private func railButton(
        systemImage: String,
        label: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .wnFont(.semiBold14)
                .foregroundStyle(
                    selected ? WNColor.fillContentSecondary : WNColor.fillContentTertiary
                )
                .frame(width: 34, height: 28)
                .background(
                    selected ? WNColor.fillTertiaryHover : WNColor.fillTertiary,
                    in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
