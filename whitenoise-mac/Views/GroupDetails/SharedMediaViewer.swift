//
//  SharedMediaViewer.swift
//  whitenoise-mac
//
//  The full-pane viewer a shared-media tile opens: the photo or video at full size over a dark
//  backdrop, paging through the rest of what group info has loaded. It is the message gallery's
//  presentation — same backdrop, chrome, and keys — fed from retained attachments instead.
//

import AVKit
import MarmotKit
import SwiftUI

struct SharedMediaViewerOverlay: View {
    let presentation: SharedMediaViewerPresentation
    let model: AttachmentViewModel
    let onClose: () -> Void
    @State private var selectedIndex: Int
    @State private var zoom = ImageZoomState()
    @State private var isSaving = false
    @State private var saveError: String?

    init(presentation: SharedMediaViewerPresentation, model: AttachmentViewModel, onClose: @escaping () -> Void) {
        self.presentation = presentation
        self.model = model
        self.onClose = onClose
        _selectedIndex = State(initialValue: presentation.initialIndex)
    }

    private var selectedItem: RetainedAttachmentItem {
        presentation.items[min(max(0, selectedIndex), presentation.items.count - 1)]
    }

    private var canNavigate: Bool {
        presentation.items.count > 1
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // The message gallery's backdrop: the palette's black at viewer strength, so the
                // pane behind does not read through the photo.
                WNColor.shadow.opacity(0.92)
                    .onTapGesture(perform: onClose)

                SharedMediaViewerPage(item: selectedItem, model: model, zoom: $zoom)
                    .id(selectedItem.id)
                    .frame(
                        maxWidth: max(1, geometry.size.width - 104),
                        maxHeight: max(1, geometry.size.height - 120)
                    )

                VStack {
                    SharedMediaViewerTopBar(
                        title: selectedItem.reference?.fileName ?? L10n.string("Attachment"),
                        position: canNavigate ? (selectedIndex + 1, presentation.items.count) : nil,
                        download: selectedItem.target == nil
                            ? nil : SharedMediaViewerDownload(isInFlight: isSaving, perform: save),
                        onClose: onClose
                    )
                    Spacer()
                }

                if canNavigate {
                    HStack {
                        SharedMediaViewerNavigationButton(
                            systemName: "chevron.left",
                            accessibilityLabel: L10n.string("Previous image"),
                            isEnabled: selectedIndex > 0 && !zoom.isZoomed
                        ) {
                            selectedIndex = max(0, selectedIndex - 1)
                        }
                        .keyboardShortcut(.leftArrow, modifiers: [])

                        Spacer()

                        SharedMediaViewerNavigationButton(
                            systemName: "chevron.right",
                            accessibilityLabel: L10n.string("Next image"),
                            isEnabled: selectedIndex < presentation.items.count - 1 && !zoom.isZoomed
                        ) {
                            selectedIndex = min(presentation.items.count - 1, selectedIndex + 1)
                        }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .padding(.horizontal, 22)
                }
            }
        }
        .onExitCommand(perform: onClose)
        // Each page starts fitted, as in the message gallery.
        .onChange(of: selectedIndex) { zoom.reset() }
        .retainedAttachmentErrorAlert($saveError)
    }

    /// Saves the item on screen, not the whole message — as the message gallery's button does.
    private func save() {
        let item = selectedItem
        Task {
            isSaving = true
            defer { isSaving = false }
            do {
                try await saveRetainedAttachment(item, model: model)
            } catch is CancellationError {
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

/// The top bar's download button: what it does, and whether a save is already running.
private struct SharedMediaViewerDownload {
    let isInFlight: Bool
    let perform: () -> Void
}

private struct SharedMediaViewerTopBar: View {
    let title: String
    /// One-based index and total; `nil` when there is only one item.
    let position: (Int, Int)?
    /// `nil` when the item on screen has nothing the core could fetch.
    let download: SharedMediaViewerDownload?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .wnFont(.semiBold12)
                .foregroundStyle(WNColor.fillContentQuaternary)
                .lineLimit(1)

            Spacer()

            if let (index, total) = position {
                Text(verbatim: "\(index) / \(total)")
                    .wnFont(.semiBold10.monospacedDigit())
                    .foregroundStyle(WNColor.fillContentQuaternary.opacity(0.72))
            }

            if let download {
                Button(action: download.perform) {
                    Group {
                        if download.isInFlight {
                            ProgressView()
                                .controlSize(.small)
                                .tint(WNColor.fillContentQuaternary)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .wnFont(.bold16)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(WNColor.fillContentQuaternary.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(WNColor.fillContentQuaternary)
                .disabled(download.isInFlight)
                .help(L10n.string("Download"))
                .accessibilityLabel(L10n.string("Download"))
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .wnFont(.bold16)
                    .frame(width: 34, height: 34)
                    .background(WNColor.fillContentQuaternary.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(WNColor.fillContentQuaternary)
            .help(L10n.string("Close"))
            .accessibilityLabel(L10n.string("Close"))
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
    }
}

private struct SharedMediaViewerNavigationButton: View {
    let systemName: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .wnFont(.bold28)
                .frame(width: 54, height: 54)
                .background(WNColor.fillContentQuaternary.opacity(isEnabled ? 0.16 : 0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(WNColor.fillContentQuaternary.opacity(isEnabled ? 0.96 : 0.28))
        .disabled(!isEnabled)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// One photo or video in the viewer. Opening it is an explicit request, so an attachment the
/// automatic policy left alone is downloaded here; the page then waits for the retained bytes to
/// appear in the model's asset map.
private struct SharedMediaViewerPage: View {
    let item: RetainedAttachmentItem
    let model: AttachmentViewModel
    @Binding var zoom: ImageZoomState
    @State private var phase = Phase.loading
    @State private var player: AVPlayer?
    @State private var videoURL: URL?

    private enum Phase {
        case loading
        case image(DownloadedMediaPayload)
        case video
        case failed
    }

    private var retainedReference: String? {
        item.target.flatMap { model.localAssetsByTarget[$0]?.reference }
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.regular)
                    .tint(WNColor.fillContentQuaternary)
            case .image(let payload):
                ZoomableMediaImage(
                    payload: payload,
                    zoom: $zoom,
                    accessibilityLabel: item.reference?.fileName
                ) {
                    SharedMediaViewerUnavailable(onRetry: nil)
                }
            case .video:
                if let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                }
            case .failed:
                SharedMediaViewerUnavailable {
                    Task { await load(downloadingIfNeeded: true) }
                }
            }
        }
        .task(id: retainedReference) {
            await load(downloadingIfNeeded: true)
        }
        .onDisappear(perform: releaseVideo)
    }

    /// The playback store never cleans up after itself, and every `fileURL` call materializes a
    /// fresh decrypted copy, so whichever copy the page holds is deleted here — after its player
    /// lets go of it.
    private func releaseVideo() {
        player?.pause()
        player = nil
        if let videoURL {
            MessageMediaPlaybackFileStore.remove(at: videoURL)
        }
        videoURL = nil
    }

    private func load(downloadingIfNeeded: Bool) async {
        guard let target = item.target, let reference = item.reference else {
            phase = .failed
            return
        }
        guard let asset = model.localAssetsByTarget[target], let retained = asset.reference else {
            guard downloadingIfNeeded else { return }
            phase = .loading
            do {
                _ = try await model.downloadExplicitly(target)
            } catch is CancellationError {
                return
            } catch {
                phase = .failed
            }
            // A finished download changes `retainedReference`, which reruns this task.
            return
        }
        do {
            let bytes = try await model.readRetainedAsset(reference: retained, byteCount: asset.byteCount)
            try Task.checkCancellation()
            let payload = DownloadedMediaPayload(id: "retained:\(retained)", data: bytes)
            guard item.category == .video else {
                phase = .image(payload)
                return
            }
            let attachment = MessageMediaAttachment(id: item.id, reference: reference)
            let download = MessageMediaDownload(
                payload: payload,
                fileName: attachment.fileName,
                mediaType: attachment.mediaType,
                sizeBytes: UInt64(payload.byteCount)
            )
            guard let url = await MessageMediaPlaybackFileStore.fileURL(attachment: attachment, download: download)
            else {
                phase = .failed
                return
            }
            guard !Task.isCancelled else {
                // Not attached to the page yet, so nothing else would ever remove it.
                MessageMediaPlaybackFileStore.remove(at: url)
                return
            }
            // A new retained reference reruns this load over a video already on screen.
            releaseVideo()
            videoURL = url
            player = AVPlayer(url: url)
            phase = .video
        } catch is CancellationError {
            return
        } catch {
            phase = .failed
        }
    }
}

private struct SharedMediaViewerUnavailable: View {
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .wnFont(.medium18)
            Text(L10n.string("Attachment unavailable"))
                .wnFont(.semiBold12)
            if let onRetry {
                Button(action: onRetry) {
                    Label(L10n.string("Retry"), systemImage: "arrow.clockwise")
                }
            }
        }
        .foregroundStyle(WNColor.fillContentQuaternary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Chrome") {
    ZStack {
        WNColor.shadow.opacity(0.92)
        SharedMediaViewerUnavailable(onRetry: {})
        VStack {
            SharedMediaViewerTopBar(
                title: "IMG_2041.jpg",
                position: (3, 9),
                download: SharedMediaViewerDownload(isInFlight: false, perform: {}),
                onClose: {}
            )
            Spacer()
        }
        HStack {
            SharedMediaViewerNavigationButton(
                systemName: "chevron.left", accessibilityLabel: "Previous image", isEnabled: true, action: {})
            Spacer()
            SharedMediaViewerNavigationButton(
                systemName: "chevron.right", accessibilityLabel: "Next image", isEnabled: false, action: {})
        }
        .padding(.horizontal, 22)
    }
    .frame(width: 720, height: 480)
}
