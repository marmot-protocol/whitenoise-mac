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

    /// Bounded wait for an attachment whose automatic download is already in flight. See
    /// `resolvedMediaDownload(_:for:)`.
    private static let mediaDownloadResolutionAttempts = 6
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

    func isDownloadingMediaAttachments(for message: MessageItem) -> Bool {
        mediaDownloadingMessageIds.contains(message.id)
    }

    /// Download `attachments` into the Downloads folder and report the tally as a toast.
    ///
    /// One gesture per message at a time: the gallery's single-attachment button and the bubble's
    /// download-everything button both target the same message, and a double click should not
    /// leave two copies of the same photo in Downloads. Writes across *different* messages are
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
        let stateDescription: String
        switch mediaDownloadStateStore(for: message, attachment: attachment).state {
        case .idle:
            stateDescription = "idle"
        case .loading:
            stateDescription = "loading"
        case .loaded:
            stateDescription = "loaded"
        case .failed:
            stateDescription = "failed"
        }
        return
            "state=\(stateDescription) outgoing=\(message.isOutgoing) kind=\(String(describing: attachment.kind))"
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

    func presentMediaDownloadFeedback(savedCount: Int, failedCount: Int) {
        nextMediaDownloadFeedbackId &+= 1
        let feedback = MediaDownloadFeedback(
            id: nextMediaDownloadFeedbackId,
            savedCount: savedCount,
            failedCount: failedCount
        )
        mediaDownloadFeedback = feedback
        mediaDownloadFeedbackDismissTask?.cancel()
        mediaDownloadFeedbackDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.mediaDownloadFeedbackDuration)
            guard !Task.isCancelled, let self, self.mediaDownloadFeedback?.id == feedback.id else { return }
            self.mediaDownloadFeedback = nil
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
    /// report a failure for a file that is seconds from arriving. Wait on the tracked download
    /// task instead, bounded so a stalled download reports rather than hangs the toast.
    private func resolvedMediaDownload(
        _ attachment: MessageMediaAttachment,
        for message: MessageItem
    ) async -> MessageMediaDownload? {
        let stateStore = mediaDownloadStateStore(for: message, attachment: attachment)
        for _ in 0..<Self.mediaDownloadResolutionAttempts {
            if case .loaded(let download) = stateStore.state {
                return download
            }
            await loadMediaAttachment(attachment, for: message)
            if case .loaded(let download) = stateStore.state {
                return download
            }
            guard case .loading = stateStore.state else { return nil }
            await awaitInFlightMediaAttachmentDownload(attachment, for: message)
        }
        if case .loaded(let download) = stateStore.state {
            return download
        }
        return nil
    }

    private func awaitInFlightMediaAttachmentDownload(
        _ attachment: MessageMediaAttachment,
        for message: MessageItem
    ) async {
        if let accountId = activeAccountId {
            let cacheKey = MessageMediaDiskCacheKey(
                accountId: accountId,
                groupIdHex: message.groupIdHex,
                reference: attachment.reference
            )
            if let task = mediaAttachmentDownloadTasks[cacheKey.cacheID]?.task {
                // The task itself carries no deadline — every other waiter on it supplies one, and
                // this one must too. An FFI download that never returns would otherwise hold
                // `mediaDownloadingMessageIds` for the rest of the session: no toast, and the
                // download control disabled on a message the user can still see.
                _ = try? await withMediaAttachmentDownloadTimeout { [task] in
                    try await task.value
                }
            }
        }
        // The state store is published by whichever task started the load, one hop after the
        // download task returns, so yielding once is not enough to observe `.loaded`.
        try? await Task.sleep(for: Self.mediaDownloadResolutionPollInterval)
    }
}
