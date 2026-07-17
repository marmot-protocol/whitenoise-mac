import Combine
import Foundation
import SwiftUI

nonisolated struct ChatEmojiCatalogEntry: Codable, Identifiable, Hashable {
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

nonisolated enum ChatEmojiSearch {
    static func results(
        in entries: [ChatEmojiCatalogEntry],
        query: String,
        limit: Int = 160
    ) -> [ChatEmojiCatalogEntry] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return Array(entries.prefix(limit)) }

        return entries.compactMap { entry -> (ChatEmojiCatalogEntry, Int)? in
            let name = entry.name.lowercased()
            let keywords = entry.keywords.map { $0.lowercased() }
            var score = 0
            for term in terms {
                if name == term {
                    score += 100
                } else if name.hasPrefix(term) {
                    score += 60
                } else if name.contains(term) {
                    score += 35
                } else if keywords.contains(term) {
                    score += 25
                } else if keywords.contains(where: { $0.hasPrefix(term) }) {
                    score += 12
                } else if entry.emoji == term {
                    score += 100
                } else {
                    return nil
                }
            }
            return (entry, score)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.name < $1.0.name
        }
        .prefix(limit)
        .map(\.0)
    }
}

nonisolated enum ChatReactionDefaults {
    static let quick = ["❤️", "👍", "👎", "😂", "😮", "😢"]
}

private struct ChatEmojiCategory: Identifiable {
    let id: Int
    let title: String
    let systemImage: String

    static let all = [
        Self(id: 0, title: "Smileys & People", systemImage: "face.smiling"),
        Self(id: 1, title: "People & Body", systemImage: "person.fill"),
        Self(id: 2, title: "Animals & Nature", systemImage: "pawprint.fill"),
        Self(id: 3, title: "Food & Drink", systemImage: "fork.knife"),
        Self(id: 4, title: "Travel & Places", systemImage: "car.fill"),
        Self(id: 5, title: "Activities", systemImage: "soccerball"),
        Self(id: 6, title: "Objects", systemImage: "lightbulb.fill"),
        Self(id: 7, title: "Symbols", systemImage: "heart.fill"),
        Self(id: 8, title: "Flags", systemImage: "flag.fill"),
    ]
}

@MainActor
private final class ChatEmojiPickerModel: ObservableObject {
    @Published private(set) var entries: [ChatEmojiCatalogEntry] = []
    @Published private(set) var didFail = false

    private static var cachedEntries: [ChatEmojiCatalogEntry]?

    func load() async {
        guard entries.isEmpty else { return }
        if let cachedEntries = Self.cachedEntries {
            entries = cachedEntries
            return
        }
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json") else {
            didFail = true
            return
        }
        do {
            let decoded = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                return try JSONDecoder().decode([ChatEmojiCatalogEntry].self, from: data)
            }.value
            Self.cachedEntries = decoded
            entries = decoded
        } catch {
            didFail = true
        }
    }
}

private enum ChatEmojiRecents {
    static let key = "chat.emoji-picker.recents"
    static let maximumCount = 40

    static var values: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? ChatReactionDefaults.quick
    }

    static func record(_ emoji: String) {
        var result = values.filter { $0 != emoji }
        result.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(result.prefix(maximumCount)), forKey: key)
    }
}

struct ChatEmojiPicker: View {
    let onPick: (String) -> Void

    @StateObject private var model = ChatEmojiPickerModel()
    @State private var query = ""
    @State private var selectedCategory = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

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
        .task { await model.load() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search emoji", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .padding(10)
    }

    @ViewBuilder
    private var emojiGrid: some View {
        if model.entries.isEmpty, !model.didFail {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.didFail {
            ContentUnavailableView("Emoji unavailable", systemImage: "face.dashed")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    if query.isEmpty {
                        let lookup = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.emoji, $0) })
                        let recents = ChatEmojiRecents.values.compactMap { lookup[$0] }
                        if !recents.isEmpty {
                            emojiSection(title: "Recently used", entries: recents)
                                .id("recent")
                        }
                        ForEach(ChatEmojiCategory.all) { category in
                            emojiSection(
                                title: category.title,
                                entries: model.entries.filter { $0.group == category.id }
                            )
                            .id("category-\(category.id)")
                        }
                    } else {
                        emojiSection(
                            title: "Search results",
                            entries: ChatEmojiSearch.results(in: model.entries, query: query)
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
                        ChatEmojiRecents.record(entry.emoji)
                        onPick(entry.emoji)
                    } label: {
                        Text(entry.emoji)
                            .font(.system(size: 25))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.name)
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

    private func categoryRail(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 2) {
            railButton(systemImage: "clock.fill", selected: false) {
                proxy.scrollTo("recent", anchor: .top)
            }
            ForEach(ChatEmojiCategory.all) { category in
                railButton(systemImage: category.systemImage, selected: selectedCategory == category.id) {
                    selectedCategory = category.id
                    proxy.scrollTo("category-\(category.id)", anchor: .top)
                }
                .help(category.title)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
    }

    private func railButton(
        systemImage: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 34, height: 28)
                .background(selected ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}
