import Foundation
import MarmotKit
import OSLog

/// The toast counts failures but cannot say *why* one failed, and the two causes need different
/// fixes — a fetch that never resolved (core/relay) versus a write the sandbox refused. Both are
/// logged so a report of "it says it couldn't download" is diagnosable from Console. Which of the
/// two it was is public; the error text itself is private, since neither the core nor Foundation
/// promises to keep a file name out of it.
private let mediaDownloadLogger = Logger(subsystem: "com.whitenoise.media", category: "MediaDownload")

@MainActor
extension WorkspaceState {
    /// Bounded retry for the two gaps in which a load has published `.loading` but has registered
    /// neither task `resolvedMediaDownload(_:for:)` could await: before reference resolution
    /// starts, and between it finishing and the download being registered. The first covers a
    /// disk-cache read that verifies the plaintext hash of a file that may be several megabytes,
    /// so the budget is half a second rather than the handful of milliseconds the second needs.
    ///
    /// It does not bound the waits themselves — those are awaited. See `resolvedMediaDownload`.
    private static let mediaDownloadResolutionAttempts = 10
    private static let mediaDownloadResolutionPollInterval: Duration = .milliseconds(50)

    /// Re-read the stored folder for the Storage settings row. Mirrors `refreshMediaCacheFootprint()`:
    /// the value is only needed while that pane is open.
    func refreshMediaDownloadDestinationPath() {
        mediaDownloadDestinationPath = mediaDownloadDestinationStore.defaultFolderURL?
            .path(percentEncoded: false)
    }

    /// Settings entry point for changing the folder. Cancelling leaves the previous grant alone.
    func changeMediaDownloadDestination() {
        guard let picked = mediaDownloadPanels.chooseFolder(mediaDownloadDestinationStore.defaultFolderURL)
        else { return }
        mediaDownloadDestinationStore.store(picked)
        refreshMediaDownloadDestinationPath()
    }

    /// Whether a download gesture is running on this message.
    ///
    /// Deliberately per message rather than per attachment: it is the double-click guard, and the
    /// bubble's action takes every attachment at once, so the message is the unit the gesture
    /// works in. The gallery's single-photo button shares the lock, which means saving one photo
    /// briefly disables the button for the next — the cost of never writing two copies of the same
    /// file.
    func isDownloadingMediaAttachments(for message: MessageItem) -> Bool {
        mediaDownloadingMessageIds.contains(message.id)
    }

    /// Download `attachments` to where the user says and report the outcome as a toast.
    ///
    /// Where is the default folder — Downloads, or the one picked in Storage settings (or by the
    /// panel when the default could not be opened) — unless the user has turned on "Always ask
    /// where to save", which asks every time: Save As for one file, a folder for several.
    ///
    /// One gesture per message at a time: the gallery's single-attachment button and the bubble's
    /// download-everything button both target the same message, and a double click should not
    /// leave two copies of the same photo in that folder. Writes across *different* messages are
    /// serialized a level down, by `MediaDownloadWriter`.
    func downloadMediaAttachments(_ attachments: [MessageMediaAttachment], for message: MessageItem) async {
        guard !attachments.isEmpty, !mediaDownloadingMessageIds.contains(message.id) else { return }
        mediaDownloadingMessageIds.insert(message.id)
        defer { mediaDownloadingMessageIds.remove(message.id) }

        // No destination means the user closed the panel without choosing. That is a cancelled
        // gesture, not a failure — no toast, nothing written.
        guard let destination = resolveMediaDownloadDestination(for: attachments, of: message) else { return }
        defer { if case .folder(let access) = destination { access.release() } }

        var savedFileURLs: [URL] = []
        var failedCount = 0
        for attachment in attachments {
            guard let download = await resolvedMediaDownload(attachment, for: message) else {
                mediaDownloadLogger.error(
                    """
                    Attachment could not be fetched for download: \
                    \(self.mediaDownloadFailureDetail(attachment, for: message), privacy: .public) \
                    reason=\(self.mediaDownloadFailureReason(attachment, for: message), privacy: .private)
                    """
                )
                failedCount += 1
                continue
            }
            do {
                switch destination {
                case .file(let url):
                    try await MediaDownloadWriter.shared.replace(download.payload.data, at: url)
                    savedFileURLs.append(url)
                case .folder(let access):
                    // The core's own name for the file wins over the timeline's: it is what the
                    // sender uploaded, and the timeline reference can carry a blank one.
                    let fileName = download.fileName.nilIfBlank ?? attachment.fileName
                    savedFileURLs.append(
                        try await MediaDownloadWriter.shared.write(
                            download.payload.data, fileName: fileName, into: access.url))
                }
            } catch {
                // Private for the same reason as the fetch reason above: a write error names the
                // file it could not write, and that is the destination path and the sender's own
                // file name.
                mediaDownloadLogger.error(
                    "Attachment fetched but could not be written: \(error.localizedDescription, privacy: .private)"
                )
                failedCount += 1
            }
        }

        presentMediaDownloadFeedback(savedFileURLs: savedFileURLs, failedCount: failedCount)
    }

    /// Where one download gesture writes. `nil` means the user cancelled.
    ///
    /// Asking happens before anything is fetched, so a cancelled panel costs no download. Save As
    /// offers the core's name for the file when the tile has already loaded it — the name the row
    /// shows and the folder path writes — and the timeline's otherwise.
    private func resolveMediaDownloadDestination(
        for attachments: [MessageMediaAttachment],
        of message: MessageItem
    ) -> MediaDownloadTarget? {
        if mediaDownloadDestinationStore.alwaysAsksWhereToSave {
            // Both panels open in the default folder, so accepting one as offered lands there.
            let defaultFolder = mediaDownloadDestinationStore.defaultFolderURL
            if attachments.count == 1 {
                let attachment = attachments[0]
                var loaded: MessageMediaDownload?
                if case .loaded(let download) = mediaDownloadStateStore(for: message, attachment: attachment).state {
                    loaded = download
                }
                let suggestedName = MediaFileDownloader.suggestedFileName(
                    loaded?.fileName.nilIfBlank ?? attachment.reference.fileName,
                    mediaType: loaded?.mediaType ?? attachment.reference.mediaType)
                return mediaDownloadPanels.chooseFile(suggestedName, defaultFolder)
                    .map(MediaDownloadTarget.file)
            }
            // A folder picked for one gesture is not remembered: the user asked to be asked. The
            // panel's grant lasts for the app's lifetime, so there is nothing to release.
            return mediaDownloadPanels.chooseFolder(defaultFolder).map {
                .folder(MediaDownloadDestinationAccess(url: $0, isSecurityScoped: false))
            }
        }
        if let stored = mediaDownloadDestinationStore.resolveDestination() {
            return .folder(stored)
        }
        guard let picked = mediaDownloadPanels.chooseFolder(mediaDownloadDestinationStore.defaultFolderURL)
        else { return nil }
        mediaDownloadDestinationStore.store(picked)
        refreshMediaDownloadDestinationPath()
        // Use the panel's URL directly rather than re-resolving the bookmark just written: the
        // panel already granted access for this launch, and a freshly picked folder is not a
        // security-scoped resource this code opened, so it must not be closed either.
        return .folder(MediaDownloadDestinationAccess(url: picked, isSecurityScoped: false))
    }

    /// Non-identifying detail for the fetch-failure log line: which terminal state the store was
    /// left in, plus whether this was our own upload, since a sender downloading their own
    /// attachment resolves the media secret through a different path in the core than a received
    /// one. No file names, no bytes, and no text the core wrote — see
    /// `mediaDownloadFailureReason`.
    func mediaDownloadFailureDetail(
        _ attachment: MessageMediaAttachment,
        for message: MessageItem
    ) -> String {
        let state = mediaDownloadStateStore(for: message, attachment: attachment).state
        return "state=\(state.logLabel) outgoing=\(message.isOutgoing) kind=\(String(describing: attachment.kind))"
    }

    /// The core's own words for why the fetch failed, which is what makes a report diagnosable —
    /// and which nothing constrains to be free of the file name or the URL it was fetched from.
    /// Logged privately for that reason; the public half of the line is
    /// `mediaDownloadFailureDetail`.
    func mediaDownloadFailureReason(
        _ attachment: MessageMediaAttachment,
        for message: MessageItem
    ) -> String {
        guard case .failed(let reason) = mediaDownloadStateStore(for: message, attachment: attachment).state
        else {
            return "none"
        }
        return reason
    }

    /// Report a finished gesture, folding it into a toast that is still up.
    ///
    /// Downloads on different messages run concurrently, so a second gesture can finish while the
    /// first one's toast is still on screen. Replacing what is there would report one file when
    /// two were saved, and Show in Finder would reveal only one, so the files and failures add —
    /// the toast describes everything it has had time to tell the user about. The toast owns its
    /// own dismissal timer, which restarts because the value changed.
    func presentMediaDownloadFeedback(savedFileURLs: [URL], failedCount: Int) {
        let showing = mediaDownloadFeedback
        mediaDownloadFeedback = MediaDownloadFeedback(
            savedFileURLs: (showing?.savedFileURLs ?? []) + savedFileURLs,
            failedCount: failedCount + (showing?.failedCount ?? 0)
        )
    }

    func dismissMediaDownloadFeedback() {
        mediaDownloadFeedback = nil
    }

    /// The decrypted bytes for `attachment`, downloading them first if the timeline has not.
    ///
    /// `loadMediaAttachment` returns immediately when a tile's automatic download is already in
    /// flight, so a click that lands mid-download would otherwise read a `.loading` store and
    /// report a failure for a file that is seconds from arriving. The tracked task is that value,
    /// though, so it is awaited directly rather than watched for through the published store.
    ///
    /// The loop covers one window and no more: `loadMediaAttachment` publishes `.loading` before
    /// `resolvedMediaReference` has registered the download it is about to start, so a click that
    /// lands inside it sees `.loading` with nothing to await yet. Every other state is terminal.
    func resolvedMediaDownload(
        _ attachment: MessageMediaAttachment,
        for message: MessageItem
    ) async -> MessageMediaDownload? {
        let stateStore = mediaDownloadStateStore(for: message, attachment: attachment)
        for _ in 0..<Self.mediaDownloadResolutionAttempts {
            if case .loaded(let download) = stateStore.state {
                return download
            }
            if let task = inFlightMediaAttachmentDownloadTask(attachment, for: message) {
                // The task itself carries no deadline — every other waiter on it supplies one, and
                // this one must too. An FFI download that never returns would otherwise hold
                // `mediaDownloadingMessageIds` for the rest of the session: no toast, and the
                // download control disabled on a message the user can still see.
                //
                // A download that fails or runs out of time is reported rather than started again
                // here: the retry would be a second wait of the same length on the same gesture,
                // and the control comes back enabled for the user to ask again.
                return try? await withMediaAttachmentDownloadTimeout { [task] in
                    try await task.value
                }
            }
            // `.loading` with no download task is a load still resolving the attachment's
            // reference — a `listMedia` FFI call with a 60-second ceiling of its own. That wait is
            // awaited, not polled past: sleeping a few times and giving up would report a failure
            // for a download that had not been started yet, which is the case this whole method
            // exists to avoid.
            //
            // Deliberately falls through to the poll below rather than looping straight back: a
            // task that has already finished but is still registered would otherwise return at
            // once, and spend every attempt doing it before anything had a chance to change.
            if case .loading = stateStore.state,
                let resolution = inFlightMediaReferenceIndexTask(for: message)
            {
                _ = try? await withMediaAttachmentDownloadTimeout { [resolution] in
                    try await resolution.value
                }
            }

            await loadMediaAttachment(attachment, for: message)
            if case .loaded(let download) = stateStore.state {
                return download
            }
            guard case .loading = stateStore.state else { return nil }
            try? await Task.sleep(for: Self.mediaDownloadResolutionPollInterval)
        }
        if case .loaded(let download) = stateStore.state {
            return download
        }
        return nil
    }
}
