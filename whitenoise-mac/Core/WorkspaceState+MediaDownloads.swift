import AppKit
import Foundation
import OSLog

/// The toast counts failures but cannot say *why* one failed, and the two causes need different
/// fixes — a fetch that never resolved (core/relay) versus a write the sandbox refused. Both are
/// logged so a report of "it says it couldn't download" is diagnosable from Console. Which of the
/// two it was is public; the error text itself is private, since neither the core nor Foundation
/// promises to keep a file name out of it.
private let mediaDownloadLogger = Logger(subsystem: "com.whitenoise.media", category: "MediaDownload")

@MainActor
extension WorkspaceState {
    /// How long a download toast stays up before it dismisses itself.
    static let mediaDownloadFeedbackDuration: Duration = .seconds(4)

    /// Bounded retry for the two gaps in which a load has published `.loading` but has registered
    /// neither task `resolvedMediaDownload(_:for:)` could await: before reference resolution
    /// starts, and between it finishing and the download being registered. The first covers a
    /// disk-cache read that verifies the plaintext hash of a file that may be several megabytes,
    /// so the budget is half a second rather than the handful of milliseconds the second needs.
    ///
    /// It does not bound the waits themselves — those are awaited. See `resolvedMediaDownload`.
    private static let mediaDownloadResolutionAttempts = 10
    private static let mediaDownloadResolutionPollInterval: Duration = .milliseconds(50)

    /// Ask the user which folder downloads go to.
    ///
    /// The app is sandboxed with only `files.user-selected.read-write`, so a folder is writable
    /// precisely because the user picked it here — the panel is the permission grant, not a
    /// formality. It runs once; the grant is then remembered as an app-scoped bookmark.
    static func chooseMediaDownloadDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Choose where to save downloads")
        panel.message = L10n.string("White Noise saves downloaded attachments to this folder.")
        panel.prompt = L10n.string("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Re-read the stored folder for the Storage settings row. Mirrors `refreshMediaCacheFootprint()`:
    /// the value is only needed while that pane is open.
    func refreshMediaDownloadDestinationPath() {
        mediaDownloadDestinationPath = mediaDownloadDestinationStore.storedDestinationURL?
            .path(percentEncoded: false)
    }

    /// Settings entry point for changing the folder. Cancelling leaves the previous grant alone.
    func changeMediaDownloadDestination() {
        guard let picked = mediaDownloadDestinationPicker() else { return }
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

    /// Download `attachments` into the folder the user chose and report the tally as a toast.
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
        guard let destination = resolveMediaDownloadDestination() else { return }
        defer { destination.release() }
        let directory = destination.url

        var savedCount = 0
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
            // The core's own name for the file wins over the timeline's: it is what the sender
            // uploaded, and the timeline reference can carry a blank one.
            let fileName = download.fileName.nilIfBlank ?? attachment.fileName
            do {
                try await MediaDownloadWriter.shared.write(
                    download.payload.data, fileName: fileName, into: directory)
                savedCount += 1
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

        presentMediaDownloadFeedback(savedCount: savedCount, failedCount: failedCount)
    }

    /// The folder to write into: the remembered grant if there is one, otherwise whatever the user
    /// picks now. `nil` means the user cancelled.
    private func resolveMediaDownloadDestination() -> MediaDownloadDestinationAccess? {
        if let stored = mediaDownloadDestinationStore.resolveDestination() {
            return stored
        }
        guard let picked = mediaDownloadDestinationPicker() else { return nil }
        mediaDownloadDestinationStore.store(picked)
        refreshMediaDownloadDestinationPath()
        // Use the panel's URL directly rather than re-resolving the bookmark just written: the
        // panel already granted access for this launch, and a freshly picked folder is not a
        // security-scoped resource this code opened, so it must not be closed either.
        return MediaDownloadDestinationAccess(url: picked, isSecurityScoped: false)
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

    /// Report a finished gesture, folding the tally into a toast that is still up.
    ///
    /// Downloads on different messages run concurrently, so a second gesture can finish while the
    /// first one's toast is still on screen. Replacing the count there would report one file when
    /// two were saved, so the counts add and the dismissal timer restarts — the toast describes
    /// everything it has had time to tell the user about.
    func presentMediaDownloadFeedback(savedCount: Int, failedCount: Int) {
        let showing = mediaDownloadFeedback
        mediaDownloadFeedback = MediaDownloadFeedback(
            savedCount: savedCount + (showing?.savedCount ?? 0),
            failedCount: failedCount + (showing?.failedCount ?? 0)
        )
        // Cancelling is the whole of the handover: the previous timer is flagged before it can
        // resume, so it cannot close a toast it no longer describes.
        mediaDownloadFeedbackDismissTask?.cancel()
        mediaDownloadFeedbackDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.mediaDownloadFeedbackDuration)
            guard !Task.isCancelled else { return }
            self?.mediaDownloadFeedback = nil
        }
    }

    func dismissMediaDownloadFeedback() {
        mediaDownloadFeedbackDismissTask?.cancel()
        mediaDownloadFeedbackDismissTask = nil
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
    private func resolvedMediaDownload(
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
