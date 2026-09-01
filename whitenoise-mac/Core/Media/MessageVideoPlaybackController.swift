//
//  MessageVideoPlaybackController.swift
//  whitenoise-mac
//

import AVFoundation
import Foundation
import Observation

/// Playing one video attachment: the `AVPlayer`, the decrypted scratch file it reads from, and the
/// teardown that reclaims that file.
///
/// Lifted out of `MessageVideoAttachmentPlayer` because the thing worth guarding here is not a
/// shape in the view — it is that **the plaintext on disk is deleted every way playback can end**.
/// Transcript rows are eager, so a row scrolled out of the viewport is never removed and
/// `onDisappear` never runs for it; without a scroll-visibility teardown a reader who scrolled past
/// a video left a decrypted copy of it in the container until the app quit.
@MainActor
@Observable
final class MessageVideoPlaybackController {
    private(set) var player: AVPlayer?
    private(set) var isLoading = false
    private(set) var didFail = false

    /// The decrypted scratch file currently on disk, or `nil` when nothing is materialized. The
    /// property every teardown path exists to bring back to `nil`.
    private(set) var playbackURL: URL?

    private var preparationID: UUID?
    private var playbackTask: Task<Void, Never>?
    private var endOfPlaybackObserver: NSObjectProtocol?

    var isPreparingPlayback: Bool {
        preparationID != nil
    }

    var accessibilityLabel: String {
        MessageVideoAttachmentPlayerAccessibility.label(
            isPreparingPlayback: isPreparingPlayback,
            didFail: didFail
        )
    }

    func activatePlayback(attachment: MessageMediaAttachment, download: MessageMediaDownload) {
        if isPreparingPlayback {
            tearDownPlayback()
        } else {
            playbackTask?.cancel()
            playbackTask = Task { [weak self] in
                await self?.togglePlayback(attachment: attachment, download: download)
            }
        }
    }

    /// Transcript rows are eager, so scrolling one out of the viewport does not take it away.
    func scrollVisibilityChanged(to isVisible: Bool) {
        guard !isVisible else { return }
        tearDownPlayback()
    }

    func disappeared() {
        tearDownPlayback()
    }

    /// The view's identity outlived a change of the attachment it renders — a grid slot flipped to
    /// another attachment, or the download's decrypted payload changed. Tearing down here is what
    /// stops playback and the scratch-file cleanup from ever targeting the previous
    /// attachment's `playbackURL`. See #339.
    func attachmentChanged() {
        didFail = false
        tearDownPlayback()
    }

    /// Cancels in-flight preparation, releases the player, and deletes the decrypted scratch file.
    func tearDownPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        stopPlayback()
    }

    private func togglePlayback(
        attachment: MessageMediaAttachment,
        download: MessageMediaDownload
    ) async {
        guard !Task.isCancelled else { return }
        if isPreparingPlayback {
            stopPlayback()
            return
        }
        await startPlayback(attachment: attachment, download: download)
    }

    private func startPlayback(
        attachment: MessageMediaAttachment,
        download: MessageMediaDownload
    ) async {
        guard !Task.isCancelled else { return }

        let nextPreparationID = UUID()
        preparationID = nextPreparationID
        isLoading = true
        didFail = false
        defer {
            if preparationID == nextPreparationID {
                preparationID = nil
                isLoading = false
            }
        }

        let resolvedURL: URL?
        if let playbackURL {
            resolvedURL = playbackURL
        } else {
            resolvedURL = await MessageMediaPlaybackFileStore.fileURL(
                attachment: attachment,
                download: download
            )
        }
        guard preparationID == nextPreparationID, !Task.isCancelled else {
            // Preparation was superseded or cancelled after `fileURL` materialized a fresh
            // decrypted scratch file. `playbackURL` is still unset on this path, so the teardown
            // paths can't reclaim it — delete it here to avoid leaking plaintext.
            if let resolvedURL, resolvedURL != playbackURL {
                MessageMediaPlaybackFileStore.remove(at: resolvedURL)
            }
            return
        }
        guard let url = resolvedURL else {
            didFail = true
            return
        }
        playbackURL = url
        let next = AVPlayer(url: url)
        player = next
        observeEndOfPlayback(for: next)
        next.play()
    }

    /// Seeks the playhead back to the start when the item plays to completion so the next click
    /// restarts playback instead of no-op-ing on the final frame. Mirrors the audio replay fix
    /// (#118) for the separate `AVPlayer` video code path.
    private func observeEndOfPlayback(for player: AVPlayer) {
        removeEndOfPlaybackObserver()
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
        }
    }

    private func removeEndOfPlaybackObserver() {
        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
            self.endOfPlaybackObserver = nil
        }
    }

    /// Ordered so `AVPlayer` no longer references the file before it is removed.
    private func stopPlayback() {
        preparationID = nil
        isLoading = false
        removeEndOfPlaybackObserver()
        player?.pause()
        player = nil
        if let url = playbackURL {
            MessageMediaPlaybackFileStore.remove(at: url)
            playbackURL = nil
        }
    }
}
