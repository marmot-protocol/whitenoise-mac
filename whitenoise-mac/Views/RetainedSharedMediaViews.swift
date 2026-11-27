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
            if model.items.isEmpty {
                await model.refreshHistory()
            } else {
                await model.refreshLocalAssets()
            }
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
    /// and stops the transfer subscription once the last mounted media surface disappears.
    func retainedAttachmentTransferObservation(_ model: AttachmentViewModel) -> some View {
        modifier(RetainedAttachmentTransferObservationModifier(model: model))
    }
}

private struct RetainedAttachmentTransferObservationModifier: ViewModifier {
    let model: AttachmentViewModel
    @State private var observedModel: AttachmentViewModel?
    @State private var observationToken: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear {
                attach(to: model)
            }
            .onChange(of: ObjectIdentifier(model)) { _, _ in
                detach()
                attach(to: model)
            }
            .onDisappear {
                detach()
            }
    }

    private func attach(to target: AttachmentViewModel) {
        if observedModel === target, observationToken != nil { return }
        detach()
        observedModel = target
        observationToken = target.beginTransferObservation()
    }

    private func detach() {
        if let observedModel, let observationToken {
            observedModel.endTransferObservation(observationToken)
        }
        observedModel = nil
        observationToken = nil
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
                .font(.callout.weight(.medium))
                .foregroundStyle(WNColor.backgroundContentSecondary)
            Text(description)
                .font(.caption)
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
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
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
            actionError = UserFacingError.message(for: error)
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
            .font(.subheadline.weight(.semibold))
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
                .font(.title3.weight(.medium))
                .foregroundStyle(WNColor.backgroundContentTertiary)
        } else {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(WNColor.backgroundContentTertiary)
        }
    }
}

/// Truthful metadata subtitle for a file row in Shared Media → Files, using only already-known
/// MIME type and retained local byte count (never touching disk or triggering a download).
nonisolated enum RetainedFileRowMetadata {
    static func subtitle(
        mediaType: String?,
        isRejected: Bool,
        retainedByteCount: UInt64?
    ) -> String {
        if isRejected { return L10n.string("Attachment couldn’t be read") }
        let typeLabel =
            mediaType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "application/octet-stream"
        guard let retainedByteCount, retainedByteCount > 0 else { return typeLabel }
        let formattedSize = ByteCountFormatter.string(
            fromByteCount: Int64(min(retainedByteCount, UInt64(Int64.max))),
            countStyle: .file
        )
        return "\(typeLabel) · \(formattedSize)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct RetainedFileRow: View {
    let item: RetainedAttachmentItem
    let model: AttachmentViewModel
    @State private var isWorking = false
    @State private var actionError: String?

    var body: some View {
        HStack(spacing: 10) {
            if let reference = item.reference {
                let attachment = MessageMediaAttachment(id: item.id, reference: reference)
                Image(
                    nsImage: AttachmentFileTypeIcon.icon(
                        mediaType: attachment.mediaType,
                        fileName: attachment.fileName
                    )
                )
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isWorking || transferStatus?.isWorking == true {
                ProgressView().controlSize(.small)
                if let reference = transferStatus?.reference, transferStatus?.isWorking == true {
                    Button {
                        Task { _ = try? await model.control(reference: reference, .cancel) }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Cancel"))
                    .accessibilityLabel(L10n.string("Cancel"))
                }
            } else {
                if let reference = transferStatus?.reference, transferStatus?.canRetry == true {
                    Button {
                        Task { _ = try? await model.control(reference: reference, .retry) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("Retry"))
                    .accessibilityLabel(L10n.string("Retry"))
                }
                if item.target != nil {
                    Button {
                        Task { await saveOrDownload() }
                    } label: {
                        Image(systemName: localAsset?.reference == nil ? "arrow.down.circle" : "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help(localAsset?.reference == nil ? L10n.string("Download") : L10n.string("Save file"))
                    .accessibilityLabel(
                        localAsset?.reference == nil ? L10n.string("Download") : L10n.string("Save file")
                    )
                }
            }
            RetainedAttachmentControlMenu(model: model, status: transferStatus, includeTransferControls: false)
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
        RetainedFileRowMetadata.subtitle(
            mediaType: item.reference?.mediaType,
            isRejected: item.rejection != nil,
            retainedByteCount: localAsset?.reference != nil ? localAsset?.byteCount : nil
        )
    }

    private func saveOrDownload() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await saveRetainedAttachment(item, model: model)
        } catch {
            actionError = UserFacingError.message(for: error)
        }
    }
}

/// Saves one retained attachment wherever the user picks, downloading it first when the automatic
/// policy left it alone. Shared by the file row and the full-pane viewer, so both write the same
/// bytes under the same name.
///
/// The bytes come from MDK's handoff lease when it can lend one, so a large file is copied on disk
/// rather than read through app memory; the lease is released as soon as the copy is written.
func saveRetainedAttachment(_ item: RetainedAttachmentItem, model: AttachmentViewModel) async throws {
    guard let target = item.target, let reference = item.reference else { return }
    if model.localAssetsByTarget[target]?.reference == nil {
        _ = try await model.downloadExplicitly(target)
    }
    guard let asset = model.localAssetsByTarget[target], let retainedReference = asset.reference else {
        return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = MessageMediaAttachment(id: item.id, reference: reference).fileName
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if let lease = try? await model.openHandoff(target) {
        defer { lease.release() }
        try RetainedAttachmentFileCopy.copy(from: lease.url, to: url)
        return
    }
    let data = try await model.readRetainedAsset(
        reference: retainedReference,
        byteCount: asset.byteCount
    )
    try data.write(to: url, options: .atomic)
}

/// Copies a leased file to the place the user chose. The save panel already confirmed replacing
/// an existing file there, which `copyItem` would otherwise refuse.
nonisolated enum RetainedAttachmentFileCopy {
    static func copy(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }
}

private struct RetainedAttachmentControlMenu: View {
    let model: AttachmentViewModel
    let status: AttachmentTransferStatusFfi?
    var includeTransferControls = true

    private var showsCancel: Bool {
        includeTransferControls && status?.isWorking == true
    }

    private var showsRetry: Bool {
        includeTransferControls && status?.isWorking != true && status?.canRetry == true
    }

    private var showsRemove: Bool {
        status?.canRemove == true
    }

    var body: some View {
        if let status, let reference = status.reference, showsCancel || showsRetry || showsRemove {
            Menu {
                if showsCancel {
                    Button(L10n.string("Cancel")) {
                        Task { _ = try? await model.control(reference: reference, .cancel) }
                    }
                } else if showsRetry {
                    Button(L10n.string("Retry")) {
                        Task { _ = try? await model.control(reference: reference, .retry) }
                    }
                }
                if showsRemove {
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
            .removed, .cleanedBySetting, .policyBlocked, .previouslyAcquiredUnavailable,
            .completedUnretained, .retryExhausted, .storageBlocked:
            false
        }
    }

    var canRetry: Bool {
        switch state {
        // `storageBlocked` is parked for free space, not on a timer: an explicit Retry readmits it.
        case .failed, .cancelled, .paused, .policyBlocked, .previouslyAcquiredUnavailable,
            .completedUnretained, .retryExhausted, .storageBlocked:
            true
        // `cleanedBySetting` is a removal by the "Keep media" setting, so it behaves like `removed`.
        case .unavailable, .notRequested, .queued, .downloading, .verifyingCiphertext, .decrypting,
            .verifyingPlaintext, .ready, .retryScheduled, .removed, .cleanedBySetting:
            false
        }
    }

    var canRemove: Bool {
        switch state {
        case .unavailable, .notRequested, .removed, .cleanedBySetting:
            false
        case .queued, .downloading, .verifyingCiphertext, .decrypting, .verifyingPlaintext, .ready,
            .retryScheduled, .failed, .cancelled, .paused, .policyBlocked,
            .previouslyAcquiredUnavailable, .completedUnretained, .retryExhausted, .storageBlocked:
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
