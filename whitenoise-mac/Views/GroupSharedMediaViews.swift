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

private let sharedMediaThumbnailOversample: CGFloat = 1.5

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

            let projection = workspace.sharedMediaProjection
            if workspace.isLoadingSharedMedia && projection.isEmpty {
                loadingRow
            } else if let error = workspace.sharedMediaError, projection.isEmpty {
                errorRow(error)
            } else {
                switch selectedCategory {
                case .media:
                    mediaGrid(projection.media)
                case .files:
                    filesList(projection.files)
                }
            }
        }
        .sheet(item: $preview) { SharedMediaImagePreviewView(payload: $0.payload) }
    }

    @ViewBuilder
    private func mediaGrid(_ items: [GroupSharedMediaItem]) -> some View {
        if items.isEmpty {
            emptyRow(L10n.string("No photos or videos"), systemImage: "photo.on.rectangle.angled")
        } else {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(items) { item in
                    SharedMediaThumbnail(item: item) { payload in
                        preview = SharedMediaImagePreview(payload: payload)
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
    let payload: DownloadedMediaPayload
}

private struct SharedMediaThumbnail: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    let item: GroupSharedMediaItem
    let onOpen: (DownloadedMediaPayload) -> Void

    @State private var image: Image?
    @State private var imagePayload: DownloadedMediaPayload?
    @State private var didFail = false
    @State private var actionError: String?

    private var isVideo: Bool { item.attachment.kind == .video }

    var body: some View {
        // A `Button` (not a tap gesture) so tiles are keyboard/VoiceOver reachable.
        Button {
            Task { await open() }
        } label: {
            tileContent
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .accessibilityLabel(item.attachment.fileName)
        .task(id: item.id) { await load() }
        .sharedMediaErrorAlert($actionError)
    }

    // A failed image stays activatable so tapping it retries the download.
    private var canOpen: Bool { isVideo || image != nil || didFail }

    private var tileContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                image.resizable()
                    .scaledToFill()
            } else if isVideo {
                // Static placeholder — videos aren't frame-extracted here, so never spin.
                Image(systemName: "film")
                    .foregroundStyle(.tertiary)
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
    }

    private func open() async {
        if isVideo {
            await openVideo()
        } else if let imagePayload {
            onOpen(imagePayload)
        } else if didFail {
            didFail = false
            await load()
        }
    }

    private func load() async {
        guard image == nil, !isVideo else { return }
        let data = await workspace.sharedMediaData(for: item.reference, groupIdHex: item.groupIdHex)
        guard let data else {
            didFail = true
            return
        }
        let payload = DownloadedMediaPayload(id: item.id, data: data)
        guard
            let decoded = await RemoteImageLoader.shared.image(
                for: payload,
                maxPixelSize: 180 * max(1, displayScale) * sharedMediaThumbnailOversample
            ), !Task.isCancelled
        else {
            didFail = true
            return
        }
        imagePayload = payload
        image = Image(nsImage: decoded.nsImage)
    }

    /// Open a video in the default player: decrypt (uncached), stage a temp file via the shared
    /// playback store, hand off to LaunchServices, then clean up shortly after.
    private func openVideo() async {
        guard
            let data = await workspace.sharedMediaData(
                for: item.reference, groupIdHex: item.groupIdHex, cache: false)
        else {
            actionError = L10n.string("Couldn't download this video.")
            return
        }
        let download = MessageMediaDownload(
            payload: DownloadedMediaPayload(data: data),
            fileName: item.attachment.fileName,
            mediaType: item.attachment.mediaType,
            sizeBytes: UInt64(data.count)
        )
        guard
            let url = await MessageMediaPlaybackFileStore.fileURL(
                attachment: item.attachment, download: download)
        else {
            actionError = L10n.string("Couldn't open this video.")
            return
        }
        let didOpen = NSWorkspace.shared.open(url)
        let delay: TimeInterval = didOpen ? 30 : 0
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            MediaPlaybackTempStore.remove(at: url)
        }
    }
}

private struct SharedMediaImagePreviewView: View {
    let payload: DownloadedMediaPayload
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            DownsampledDataImage(
                payload: payload,
                maxPixelSize: DownsampledImageSizing.galleryPixelSize(
                    for: proxy.size,
                    displayScale: displayScale
                )
            ) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } placeholder: {
                ContentUnavailableView(L10n.string("Couldn't open image"), systemImage: "photo")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
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
    @State private var saveError: String?

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
        .sharedMediaErrorAlert($saveError)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // `cache: false` — a saved file may be large and shouldn't sit in the thumbnail cache.
        guard
            let data = await workspace.sharedMediaData(
                for: item.reference, groupIdHex: item.groupIdHex, cache: false)
        else {
            saveError = L10n.string("Couldn't download this file.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.attachment.fileName
        panel.canCreateDirectories = true
        // A cancelled panel is not an error.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            saveError = error.localizedDescription
        }
    }
}

extension View {
    /// A cancelable alert bound to an optional message, used for shared-media file/video failures.
    fileprivate func sharedMediaErrorAlert(_ message: Binding<String?>) -> some View {
        alert(
            L10n.string("Something went wrong"),
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { presented in
                    if !presented { message.wrappedValue = nil }
                }
            )
        ) {
            Button(L10n.string("OK"), role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
