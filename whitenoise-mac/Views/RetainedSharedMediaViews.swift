import AVFoundation
import AppKit
import MarmotKit
import SwiftUI

/// Group info's shared-media section, after iOS's `GroupSharedMediaSection`: the most recent
/// photos and videos on one horizontally scrolling row, and a row into the full library — which
/// is where older media, files, and paging live.
struct RetainedSharedMediaSection: View {
    let model: AttachmentViewModel
    let onOpenLibrary: () -> Void
    let onOpenMedia: (SharedMediaViewerPresentation) -> Void

    /// iOS's strip tile, so the row holds the same number of tiles at the pane's width.
    static let stripTileSide: CGFloat = 92

    var body: some View {
        let visualItems = model.items.filter(\.isVisualMedia)

        Section(L10n.string("Shared Media")) {
            if model.isLoading && model.items.isEmpty {
                RetainedSharedMediaLoadingRow()
            } else if let error = model.error, model.items.isEmpty {
                RetainedSharedMediaErrorRow(error: error) {
                    Task { await model.refreshHistory() }
                }
            } else {
                if !visualItems.isEmpty {
                    RetainedSharedMediaStrip(
                        items: SharedMediaStripPreview.visible(visualItems),
                        model: model,
                        // The viewer pages through everything loaded, not only the strip.
                        onOpen: { item in
                            SharedMediaViewerPresentation(items: visualItems, initial: item).map(onOpenMedia)
                        }
                    )
                }
                DetailsDisclosureRow(
                    title: L10n.string("View Shared Media"),
                    systemImage: "photo.on.rectangle.angled",
                    value: "",
                    action: onOpenLibrary
                )
            }
        }
        .task(id: model.groupIdHex) {
            await model.refreshHistory()
        }
        .retainedAttachmentTransferObservation(model)
    }
}

/// One row of square tiles that scrolls sideways instead of wrapping.
private struct RetainedSharedMediaStrip: View {
    let items: [RetainedAttachmentItem]
    let model: AttachmentViewModel
    let onOpen: (RetainedAttachmentItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    RetainedMediaTile(
                        item: item,
                        model: model,
                        sideLength: RetainedSharedMediaSection.stripTileSide,
                        cornerRadius: 10,
                        onOpen: onOpen
                    )
                }
            }
        }
        .frame(height: RetainedSharedMediaSection.stripTileSide)
        .padding(.vertical, 2)
    }
}

extension View {
    /// Keeps the retained-asset map in step with the transfer projection while the view is up,
    /// and stops the transfer subscription when it goes away.
    func retainedAttachmentTransferObservation(_ model: AttachmentViewModel) -> some View {
        onChange(of: model.transfers) {
            Task { await model.refreshLocalAssets() }
        }
        .onDisappear {
            model.stopTransferObservation()
        }
    }
}

struct RetainedSharedMediaLoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 16)
    }
}

struct RetainedSharedMediaErrorRow: View {
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

struct RetainedFileList: View {
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

struct RetainedSharedMediaEmptyRow: View {
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

/// A square shared-media tile, loaded the way a message bubble loads its media: it asks the core
/// for the attachment as soon as it is on screen — through the automatic-download path, so the
/// download policy still decides — and draws a downsampled, center-cropped preview once the bytes
/// are retained. A video shows its first frame under a play badge.
///
/// `sideLength` fixes the tile for the group info strip; `nil` lets a grid column decide, and the
/// tile stays square either way.
struct RetainedMediaTile: View {
    @Environment(\.displayScale) private var displayScale
    let item: RetainedAttachmentItem
    let model: AttachmentViewModel
    var sideLength: CGFloat?
    var cornerRadius: CGFloat = 4
    /// Hands the tile to the full-pane viewer, which downloads it if the tile could not.
    let onOpen: (RetainedAttachmentItem) -> Void
    @State private var image: Image?
    @State private var actionError: String?

    /// Decode budget in points for a grid tile, whose side the column decides: a three-column
    /// grid on a wide pane draws tiles well past the strip's size.
    private static let gridPointSize: CGFloat = 320

    var body: some View {
        Button {
            if item.reference != nil { onOpen(item) }
        } label: {
            WNColor.backgroundTertiary
                .aspectRatio(1, contentMode: .fit)
                .frame(width: sideLength, height: sideLength)
                .overlay {
                    if let image {
                        image.resizable().scaledToFill()
                    } else {
                        RetainedMediaTilePlaceholder(
                            item: item,
                            isWorking: transferStatus?.isWorking == true
                        )
                    }
                }
                .overlay {
                    if item.category == .video, image != nil {
                        RetainedVideoPlayBadge()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.reference?.fileName ?? L10n.string("Attachment"))
        .task(id: localAssetState) {
            switch localAssetState {
            case .unknown:
                return
            case .absent:
                clearPreview()
                await requestAutomatically()
            case .retained:
                await loadPreviewIfAvailable()
            }
        }
        .contextMenu {
            RetainedAttachmentControlMenu(model: model, status: transferStatus)
        }
        .retainedAttachmentErrorAlert($actionError)
    }

    private enum LocalAssetState: Hashable {
        /// The asset map has not been read for this target yet.
        case unknown
        /// The core has no readable bytes for it.
        case absent
        case retained(String)
    }

    private var localAssetState: LocalAssetState {
        guard let asset = localAsset else { return .unknown }
        return asset.reference.map(LocalAssetState.retained) ?? .absent
    }

    private var localAsset: AttachmentLocalAssetFfi? {
        item.target.flatMap { model.localAssetsByTarget[$0] }
    }

    private var transferStatus: AttachmentTransferStatusFfi? {
        item.target.flatMap { model.transfersByTarget[$0] }
    }

    /// Bubbles fetch what scrolls into view without a click; this is the same request, routed
    /// through the core's policy fence. A refusal leaves the download glyph for an explicit tap.
    private func requestAutomatically() async {
        guard let target = item.target, item.rejection == nil else { return }
        guard let result = try? await model.requestAutomatically(target) else { return }
        try? Task.checkCancellation()
        if result.status.state == .ready {
            await model.refreshLocalAssets()
        }
    }

    private func clearPreview() {
        image = nil
    }

    private func loadPreviewIfAvailable() async {
        guard let asset = localAsset, let retainedReference = asset.reference, let reference = item.reference
        else {
            clearPreview()
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
            let maxPixelSize = (sideLength ?? Self.gridPointSize) * max(1, displayScale) * 1.5
            switch item.category {
            case .image:
                let decoded = await RemoteImageLoader.shared.image(for: loadedPayload, maxPixelSize: maxPixelSize)
                try Task.checkCancellation()
                image = decoded.map { Image(nsImage: $0.nsImage) }
            case .video:
                let poster = await videoPoster(
                    payload: loadedPayload, reference: reference, maxPixelSize: maxPixelSize)
                try Task.checkCancellation()
                image = poster.map { Image(nsImage: $0) }
            default:
                return
            }
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func playbackFileURL(
        payload: DownloadedMediaPayload, reference: MediaAttachmentReferenceFfi
    ) async -> URL? {
        let attachment = MessageMediaAttachment(id: item.id, reference: reference)
        let download = MessageMediaDownload(
            payload: payload,
            fileName: attachment.fileName,
            mediaType: attachment.mediaType,
            sizeBytes: UInt64(payload.byteCount)
        )
        return await MessageMediaPlaybackFileStore.fileURL(attachment: attachment, download: download)
    }

    private func videoPoster(
        payload: DownloadedMediaPayload, reference: MediaAttachmentReferenceFfi, maxPixelSize: CGFloat
    ) async -> NSImage? {
        guard let url = await playbackFileURL(payload: payload, reference: reference) else { return nil }
        defer { MessageMediaPlaybackFileStore.remove(at: url) }
        return await RetainedVideoPoster.firstFrame(of: url, maxPixelSize: maxPixelSize)
    }

}

/// The first frame of a video file, bounded to `maxPixelSize` on its long edge.
nonisolated enum RetainedVideoPoster {
    static func firstFrame(of url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard let (frame, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
    }
}

/// The play disc a video tile carries over its poster, as iOS draws it.
private struct RetainedVideoPlayBadge: View {
    var body: some View {
        Image(systemName: "play.fill")
            .wnFont(.semiBold14)
            .foregroundStyle(WNColor.fillContentQuaternary)
            .frame(width: 32, height: 32)
            .background(WNColor.overlayTertiary, in: Circle())
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
        isWorking = true
        defer { isWorking = false }
        do {
            try await saveRetainedAttachment(item, model: model)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// Saves one retained attachment wherever the user picks, downloading it first when the automatic
/// policy left it alone. Shared by the file row and the full-pane viewer, so both write the same
/// bytes under the same name.
func saveRetainedAttachment(_ item: RetainedAttachmentItem, model: AttachmentViewModel) async throws {
    guard let target = item.target, let reference = item.reference else { return }
    if model.localAssetsByTarget[target]?.reference == nil {
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

extension View {
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

#Preview("Empty") {
    Form {
        Section(L10n.string("Shared Media")) {
            RetainedSharedMediaEmptyRow(
                title: L10n.string("No photos or videos"),
                systemImage: "photo.on.rectangle.angled"
            )
            DetailsDisclosureRow(
                title: L10n.string("View Shared Media"),
                systemImage: "photo.on.rectangle.angled",
                value: "",
                action: {}
            )
        }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 320)
}

#Preview("Play badge") {
    WNColor.backgroundTertiary
        .frame(width: 92, height: 92)
        .overlay { RetainedVideoPlayBadge() }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding()
}
