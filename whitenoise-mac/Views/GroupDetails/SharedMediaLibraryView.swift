//
//  SharedMediaLibraryView.swift
//  whitenoise-mac
//
//  Every attachment the group has shared, one step in from group info. Laid out after the iOS
//  client's `SharedMediaLibraryView`: a Media/Files switch, photos and videos as a square grid
//  grouped by month, and paging into older history at the bottom.
//

import SwiftUI

private enum SharedMediaLibraryCategory: String, CaseIterable, Identifiable {
    case media
    case files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .media: L10n.string("Media")
        case .files: L10n.string("Files")
        }
    }
}

/// The library page. It shares group info's `AttachmentViewModel`, so pages already loaded for the
/// preview row are not fetched again, and paging here extends the same history.
struct SharedMediaLibraryView: View {
    let model: AttachmentViewModel
    let onBack: () -> Void
    let onOpenMedia: (SharedMediaViewerPresentation) -> Void
    @State private var category = SharedMediaLibraryCategory.media
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            GroupDetailsTopBar(
                title: L10n.string("Shared Media"),
                isLoading: model.isLoading && !model.items.isEmpty,
                backHelp: "Back",
                onBack: onBack,
                onEdit: nil
            )

            GlassSeparator(axis: .horizontal)

            SharedMediaCategoryPicker(category: $category)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            if model.isLoading && model.items.isEmpty {
                RetainedSharedMediaLoadingRow()
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if let error = model.error, model.items.isEmpty {
                RetainedSharedMediaErrorRow(error: error) {
                    Task { await model.refreshHistory() }
                }
                .padding(.horizontal, 20)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                switch category {
                case .media:
                    let visualItems = model.items.filter(\.isVisualMedia)
                    SharedMediaLibraryGrid(
                        sections: SharedMediaMonthGrouping.sections(
                            visualItems,
                            timestamp: \.timelineAt,
                            locale: locale
                        ),
                        model: model,
                        onOpen: { item in
                            SharedMediaViewerPresentation(items: visualItems, initial: item).map(onOpenMedia)
                        }
                    )
                case .files:
                    Form {
                        Section {
                            RetainedFileList(items: model.items.filter { !$0.isVisualMedia }, model: model)
                            SharedMediaLoadMoreButton(model: model)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .task(id: model.groupIdHex) {
            // Group info has normally loaded the first page already; picking it up again only
            // restarts the transfer subscription that group info's disappearance stopped.
            if model.items.isEmpty {
                await model.refreshHistory()
            } else {
                await model.refreshLocalAssets()
            }
        }
        .retainedAttachmentTransferObservation(model)
    }
}

private struct SharedMediaCategoryPicker: View {
    @Binding var category: SharedMediaLibraryCategory

    var body: some View {
        Picker(L10n.string("Shared media type"), selection: $category) {
            ForEach(SharedMediaLibraryCategory.allCases) { category in
                Text(category.label).tag(category)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Photos and videos as a square grid, a month header over each run.
private struct SharedMediaLibraryGrid: View {
    let sections: [SharedMediaMonthSection<RetainedAttachmentItem>]
    let model: AttachmentViewModel
    let onOpen: (RetainedAttachmentItem) -> Void

    /// iOS's three columns, so a tile reads as a photo rather than a thumbnail strip.
    private let columns = Array(repeating: GridItem(.flexible(minimum: 72), spacing: 3), count: 3)

    var body: some View {
        if sections.isEmpty {
            VStack(spacing: 0) {
                RetainedSharedMediaEmptyRow(
                    title: L10n.string("No photos or videos"),
                    systemImage: "photo.on.rectangle.angled"
                )
                SharedMediaLoadMoreButton(model: model)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            SharedMediaMonthHeader(title: section.title)
                            LazyVGrid(columns: columns, spacing: 3) {
                                ForEach(section.items) { item in
                                    RetainedMediaTile(item: item, model: model, onOpen: onOpen)
                                }
                            }
                        }
                    }
                    SharedMediaLoadMoreButton(model: model)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct SharedMediaMonthHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .wnFont(.semiBold14)
            .foregroundStyle(WNColor.backgroundContentPrimary)
    }
}

/// Pages in older history. Absent once the core says there is nothing older.
private struct SharedMediaLoadMoreButton: View {
    let model: AttachmentViewModel

    var body: some View {
        if model.hasMore {
            Button(L10n.string("Load more")) {
                Task { await model.loadMore() }
            }
            .disabled(model.isLoading)
            .padding(.vertical, 8)
        }
    }
}

#Preview("Chrome") {
    @Previewable @State var category = SharedMediaLibraryCategory.media
    VStack(alignment: .leading, spacing: 0) {
        GroupDetailsTopBar(title: "Shared Media", backHelp: "Back", onBack: {}, onEdit: nil)
        SharedMediaCategoryPicker(category: $category)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        VStack(alignment: .leading, spacing: 8) {
            SharedMediaMonthHeader(title: "September 2026")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(0..<7, id: \.self) { _ in
                    WNColor.backgroundTertiary
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 20)
        Spacer()
    }
    .frame(width: 520, height: 420)
}
