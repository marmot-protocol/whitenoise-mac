import AppKit
import MarmotKit
import SwiftUI

private enum RetainedSharedMediaCategory: String, CaseIterable, Identifiable {
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

struct RetainedSharedMediaSection: View {
    let model: AttachmentViewModel
    @State private var category = RetainedSharedMediaCategory.media
    @State private var preview: RetainedImagePreview?
    @State private var isMediaExpanded = false

    var body: some View {
        let mediaGrid = SharedMediaGridPreview(
            items: model.items.filter(\.isVisualMedia),
            isExpanded: isMediaExpanded
        )

        Section(L10n.string("Shared Media")) {
            Picker(L10n.string("Shared media type"), selection: $category) {
                ForEach(RetainedSharedMediaCategory.allCases) { category in
                    Text(category.label).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.isLoading && model.items.isEmpty {
                RetainedSharedMediaLoadingRow()
            } else if let error = model.error, model.items.isEmpty {
                RetainedSharedMediaErrorRow(error: error) {
                    Task { await model.refreshHistory() }
                }
            } else if category == .media {
                RetainedMediaGrid(
                    grid: mediaGrid,
                    isExpanded: $isMediaExpanded,
                    model: model,
                    onPreview: { preview = RetainedImagePreview(payload: $0) }
                )
            } else {
                RetainedFileList(
                    items: model.items.filter { !$0.isVisualMedia },
                    model: model
                )
            }

            if category == .files ? model.hasMore : mediaGrid.showsLoadMore(hasMore: model.hasMore) {
                Button(L10n.string("Load more")) {
                    Task { await model.loadMore() }
                }
                .disabled(model.isLoading)
            }
        }
        .task(id: model.groupIdHex) {
            isMediaExpanded = false
            await model.refreshHistory()
        }
        .onChange(of: model.transfers) {
            Task { await model.refreshLocalAssets() }
        }
        .onDisappear {
            model.stopTransferObservation()
        }
        .sheet(item: $preview) { preview in
            RetainedImagePreviewView(payload: preview.payload)
        }
    }
}

private struct RetainedSharedMediaLoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 16)
    }
}

private struct RetainedSharedMediaErrorRow: View {
    let error: AttachmentFeatureError
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.string("Shared media unavailable"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(WNColor.backgroundContentSecondary)
            Text(description)
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            Button(L10n.string("Retry"), action: retry)
        }
        .padding(.vertical, 4)
    }

    private var description: String {
        switch error {
        case .unavailable(let message): message
        case .invalidPage: L10n.string("Shared media unavailable")
        case .assetBecameUnavailable, .truncatedAsset: L10n.string("Attachment couldn’t be read")
        }
    }
}

private struct RetainedMediaGrid: View {
    let grid: SharedMediaGridPreview<RetainedAttachmentItem>
    @Binding var isExpanded: Bool
    let model: AttachmentViewModel
    let onPreview: (DownloadedMediaPayload) -> Void
    private let columns = Array(repeating: GridItem(.flexible(minimum: 72), spacing: 3), count: 3)

    var body: some View {
        if grid.items.isEmpty {
            RetainedSharedMediaEmptyRow(
                title: L10n.string("No photos or videos"),
                systemImage: "photo.on.rectangle.angled"
            )
        } else {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(grid.visible) { item in
                    RetainedMediaTile(item: item, model: model, onPreview: onPreview)
                }
            }
            .padding(.vertical, 2)

            if grid.isTruncated {
                RetainedMediaGridExpanderRow(title: L10n.string("View more")) { isExpanded = true }
            } else if grid.canCollapse {
                RetainedMediaGridExpanderRow(title: L10n.string("View less")) { isExpanded = false }
            }
        }
    }
}

private struct RetainedMediaGridExpanderRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .wnFont(.semiBold12)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct RetainedFileList: View {
    let items: [RetainedAttachmentItem]
    let model: AttachmentViewModel

    var body: some View {
        if items.isEmpty {
            RetainedSharedMediaEmptyRow(title: L10n.string("No files"), systemImage: "doc")
        } else {
            ForEach(items) { item in
                RetainedFileRow(item: item, model: model)
            }
        }
    }
}

private struct RetainedSharedMediaEmptyRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .wnFont(.medium18)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
                Text(title)
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 18)
    }
}

private struct RetainedImagePreview: Identifiable {
    let id = UUID()
    let payload: DownloadedMediaPayload
}

private struct RetainedMediaTile: View {
    @Environment(\.displayScale) private var displayScale
    let item: RetainedAttachmentItem
    let model: AttachmentViewModel
    let onPreview: (DownloadedMediaPayload) -> Void
    @State private var image: Image?
    @State private var payload: DownloadedMediaPayload?
    @State private var isWorking = false
    @State private var actionError: String?

    var body: some View {
        Button {
            Task { await activate() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(WNColor.fillSecondary)
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    RetainedMediaTilePlaceholder(
                        item: item,
                        isWorking: isWorking || transferStatus?.isWorking == true
                    )
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.reference?.fileName ?? L10n.string("Attachment"))
        .task(id: localAsset?.reference) {
            await loadImageIfAvailable()
        }
        .contextMenu {
            RetainedAttachmentControlMenu(model: model, status: transferStatus)
        }
        .retainedAttachmentErrorAlert($actionError)
    }

    private var localAsset: AttachmentLocalAssetFfi? {
        item.target.flatMap { model.localAssetsByTarget[$0] }
    }

    private var transferStatus: AttachmentTransferStatusFfi? {
        item.target.flatMap { model.transfersByTarget[$0] }
    }

    private func activate() async {
        guard let reference = item.reference, let target = item.target else { return }
        if let payload {
            if item.category == .video {
                await openVideo(payload: payload, reference: reference)
            } else {
                onPreview(payload)
            }
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await model.downloadExplicitly(target)
            await loadImageIfAvailable()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func loadImageIfAvailable() async {
        guard let asset = localAsset, let retainedReference = asset.reference else {
            image = nil
            payload = nil
            return
        }
        do {
            let bytes = try await model.readRetainedAsset(
                reference: retainedReference,
                byteCount: asset.byteCount
            )
            try Task.checkCancellation()
            let loadedPayload = DownloadedMediaPayload(
                id: "retained:\(retainedReference)",
                data: bytes
            )
            payload = loadedPayload
            guard item.category == .image else { return }
            let decoded = await RemoteImageLoader.shared.image(
                for: loadedPayload,
                maxPixelSize: 180 * max(1, displayScale) * 1.5
            )
            try Task.checkCancellation()
            image = decoded.map { Image(nsImage: $0.nsImage) }
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func openVideo(payload: DownloadedMediaPayload, reference: MediaAttachmentReferenceFfi) async {
        let attachment = MessageMediaAttachment(id: item.id, reference: reference)
        let download = MessageMediaDownload(
            payload: payload,
            fileName: attachment.fileName,
            mediaType: attachment.mediaType,
            sizeBytes: UInt64(payload.byteCount)
        )
        guard let url = await MessageMediaPlaybackFileStore.fileURL(attachment: attachment, download: download) else {
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

private struct RetainedMediaTilePlaceholder: View {
    let item: RetainedAttachmentItem
    let isWorking: Bool

    var body: some View {
        if isWorking {
            ProgressView().controlSize(.small)
        } else if item.rejection != nil {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(WNColor.backgroundContentTertiary)
        } else if item.category == .video {
            Image(systemName: "play.circle.fill")
                .wnFont(.medium18)
                .foregroundStyle(WNColor.backgroundContentTertiary)
        } else {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(WNColor.backgroundContentTertiary)
        }
    }
}

private struct RetainedFileRow: View {
    let item: RetainedAttachmentItem
    let model: AttachmentViewModel
    @State private var isWorking = false
    @State private var actionError: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .wnFont(.medium16)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isWorking || transferStatus?.isWorking == true {
                ProgressView().controlSize(.small)
            } else if item.target != nil {
                Button {
                    Task { await saveOrDownload() }
                } label: {
                    Image(systemName: localAsset?.reference == nil ? "arrow.down.circle" : "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help(localAsset?.reference == nil ? L10n.string("Download") : L10n.string("Save file"))
            }
            RetainedAttachmentControlMenu(model: model, status: transferStatus)
        }
        .padding(.vertical, 2)
        .retainedAttachmentErrorAlert($actionError)
    }

    private var localAsset: AttachmentLocalAssetFfi? {
        item.target.flatMap { model.localAssetsByTarget[$0] }
    }

    private var transferStatus: AttachmentTransferStatusFfi? {
        item.target.flatMap { model.transfersByTarget[$0] }
    }

    private var title: String {
        item.reference.map { MessageMediaAttachment(id: item.id, reference: $0).fileName }
            ?? L10n.string("Unsupported attachment")
    }

    private var subtitle: String {
        if item.rejection != nil { return L10n.string("Attachment couldn’t be read") }
        return item.reference?.mediaType ?? "application/octet-stream"
    }

    private var systemImage: String {
        guard let reference = item.reference else { return "exclamationmark.triangle" }
        return MessageMediaAttachment(id: item.id, reference: reference).kind.systemImageName
    }

    private func saveOrDownload() async {
        guard let target = item.target, let reference = item.reference else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if localAsset?.reference == nil {
                _ = try await model.downloadExplicitly(target)
            }
            guard let asset = model.localAssetsByTarget[target], let retainedReference = asset.reference else {
                return
            }
            let data = try await model.readRetainedAsset(
                reference: retainedReference,
                byteCount: asset.byteCount
            )
            let panel = NSSavePanel()
            panel.nameFieldStringValue = MessageMediaAttachment(id: item.id, reference: reference).fileName
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct RetainedAttachmentControlMenu: View {
    let model: AttachmentViewModel
    let status: AttachmentTransferStatusFfi?

    var body: some View {
        if let status, let reference = status.reference {
            Menu {
                if status.isWorking {
                    Button(L10n.string("Cancel")) {
                        Task { _ = try? await model.control(reference: reference, .cancel) }
                    }
                } else if status.canRetry {
                    Button(L10n.string("Retry")) {
                        Task { _ = try? await model.control(reference: reference, .retry) }
                    }
                }
                if status.canRemove {
                    Button(L10n.string("Remove"), role: .destructive) {
                        Task { _ = try? await model.control(reference: reference, .remove) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

private struct RetainedImagePreviewView: View {
    let payload: DownloadedMediaPayload
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = ImageZoomState()

    var body: some View {
        ZoomableMediaImage(payload: payload, zoom: $zoom) {
            ContentUnavailableView(L10n.string("Couldn't open image"), systemImage: "photo")
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(WNColor.shadow.opacity(0.85))
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .wnFont(.medium18)
                    .foregroundStyle(WNColor.fillContentQuaternary.opacity(0.9))
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }
}

private extension AttachmentTransferStatusFfi {
    var isWorking: Bool {
        switch state {
        case .queued, .downloading, .verifyingCiphertext, .decrypting, .verifyingPlaintext:
            true
        case .unavailable, .notRequested, .ready, .retryScheduled, .failed, .cancelled, .paused,
            .removed, .policyBlocked, .previouslyAcquiredUnavailable, .completedUnretained,
            .retryExhausted:
            false
        }
    }

    var canRetry: Bool {
        switch state {
        case .failed, .cancelled, .paused, .policyBlocked, .previouslyAcquiredUnavailable,
            .completedUnretained, .retryExhausted:
            true
        case .unavailable, .notRequested, .queued, .downloading, .verifyingCiphertext, .decrypting,
            .verifyingPlaintext, .ready, .retryScheduled, .removed:
            false
        }
    }

    var canRemove: Bool {
        switch state {
        case .unavailable, .notRequested, .removed:
            false
        case .queued, .downloading, .verifyingCiphertext, .decrypting, .verifyingPlaintext, .ready,
            .retryScheduled, .failed, .cancelled, .paused, .policyBlocked,
            .previouslyAcquiredUnavailable, .completedUnretained, .retryExhausted:
            true
        }
    }
}

private extension View {
    func retainedAttachmentErrorAlert(_ message: Binding<String?>) -> some View {
        alert(
            L10n.string("Something went wrong"),
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented { message.wrappedValue = nil }
                }
            )
        ) {
            Button(L10n.string("OK"), role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

#Preview {
    Form {
        Section(L10n.string("Shared Media")) {
            RetainedSharedMediaEmptyRow(
                title: L10n.string("No photos or videos"),
                systemImage: "photo.on.rectangle.angled"
            )
        }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 320)
}

#Preview("Grid expander") {
    Form {
        Section(L10n.string("Shared Media")) {
            RetainedMediaGridExpanderRow(title: L10n.string("View more")) {}
            RetainedMediaGridExpanderRow(title: L10n.string("View less")) {}
        }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 200)
}
