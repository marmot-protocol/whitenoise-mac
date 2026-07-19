//
//  GroupSharedMediaViews.swift
//  whitenoise-mac
//
//  The group-details "Shared Media" section: a segmented Media/Files browser over the
//  conversation's media records, with self-loading thumbnails and a file saver.
//

import AppKit
import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

enum GroupSharedMediaCategory: String, CaseIterable, Identifiable {
    case media = "Media"
    case files = "Files"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .media: return L10n.string("Media")
        case .files: return L10n.string("Files")
        }
    }
}

nonisolated struct GroupSharedMediaItem: Identifiable, Hashable {
    let id: String
    let reference: MediaAttachmentReferenceFfi
    let groupIdHex: String
    let timestamp: UInt64

    var attachment: MessageMediaAttachment { MessageMediaAttachment(id: id, reference: reference) }
    var isVisual: Bool { attachment.kind == .image || attachment.kind == .video }

    static func items(from records: [MediaRecordFfi]) -> [GroupSharedMediaItem] {
        records
            .enumerated()
            .map { index, record in
                let stableRecordID =
                    record.messageIdHex.isEmpty
                    ? record.reference.plaintextSha256.lowercased() : record.messageIdHex
                return GroupSharedMediaItem(
                    id: "shared-media:\(stableRecordID):\(record.attachmentIndex):\(index)",
                    reference: record.reference,
                    groupIdHex: record.groupIdHex,
                    timestamp: max(record.recordedAt, record.receivedAt)
                )
            }
            .sorted { lhs, rhs in
                lhs.timestamp != rhs.timestamp ? lhs.timestamp > rhs.timestamp : lhs.id > rhs.id
            }
    }
}

struct GroupSharedMediaSection: View {
    @Environment(WorkspaceState.self) private var workspace
    let groupIdHex: String

    @State private var selectedCategory = GroupSharedMediaCategory.media
    @State private var preview: SharedMediaImagePreview?

    private let columns = Array(repeating: GridItem(.flexible(minimum: 72), spacing: 3), count: 3)

    var body: some View {
        Section("Shared Media") {
            Picker("Shared media type", selection: $selectedCategory) {
                ForEach(GroupSharedMediaCategory.allCases) { category in
                    Text(category.label).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let items = GroupSharedMediaItem.items(from: workspace.sharedMediaRecords)
            if workspace.isLoadingSharedMedia && items.isEmpty {
                loadingRow
            } else if let error = workspace.sharedMediaError, items.isEmpty {
                errorRow(error)
            } else {
                switch selectedCategory {
                case .media:
                    mediaGrid(items.filter(\.isVisual))
                case .files:
                    filesList(items.filter { !$0.isVisual })
                }
            }
        }
        .sheet(item: $preview) { SharedMediaImagePreviewView(data: $0.data) }
    }

    @ViewBuilder
    private func mediaGrid(_ items: [GroupSharedMediaItem]) -> some View {
        if items.isEmpty {
            emptyRow(L10n.string("No photos or videos"), systemImage: "photo.on.rectangle.angled")
        } else {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(items) { item in
                    SharedMediaThumbnail(item: item) { data in
                        preview = SharedMediaImagePreview(data: data)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func filesList(_ items: [GroupSharedMediaItem]) -> some View {
        if items.isEmpty {
            emptyRow(L10n.string("No files"), systemImage: "doc")
        } else {
            ForEach(items) { item in
                SharedMediaFileRow(item: item)
            }
        }
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 16)
    }

    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.string("Shared media unavailable"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L10n.string("Retry")) {
                Task { await workspace.loadSharedMedia(groupIdHex: groupIdHex) }
            }
        }
        .padding(.vertical, 4)
    }

    private func emptyRow(_ title: String, systemImage: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 18)
    }
}

private struct SharedMediaImagePreview: Identifiable {
    let id = UUID()
    let data: Data
}

private struct SharedMediaThumbnail: View {
    @Environment(WorkspaceState.self) private var workspace
    let item: GroupSharedMediaItem
    let onOpen: (Data) -> Void

    @State private var image: NSImage?
    @State private var imageData: Data?
    @State private var didFail = false

    private var isVideo: Bool { item.attachment.kind == .video }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if didFail {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isVideo, let imageData else { return }
            onOpen(imageData)
        }
        .task(id: item.id) { await load() }
    }

    private func load() async {
        guard image == nil, !isVideo else { return }
        let data = await workspace.sharedMediaData(for: item.reference, groupIdHex: item.groupIdHex)
        guard let data, let decoded = NSImage(data: data) else {
            didFail = true
            return
        }
        imageData = data
        image = decoded
    }
}

private struct SharedMediaImagePreviewView: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L10n.string("Couldn't open image"), systemImage: "photo")
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color.black.opacity(0.85))
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }
}

private struct SharedMediaFileRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let item: GroupSharedMediaItem

    @State private var isSaving = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.attachment.kind.systemImageName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.attachment.fileName)
                    .lineLimit(1)
                Text(item.attachment.mediaType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isSaving {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await save() }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("Save file"))
            }
        }
        .padding(.vertical, 2)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        guard let data = await workspace.sharedMediaData(for: item.reference, groupIdHex: item.groupIdHex)
        else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.attachment.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}
