import Foundation

/// The "download this message's attachments" gesture, as one value the three entry points share.
///
/// The hover strip, the right-click menu and the image gallery all offer downloading, and they have
/// to agree on when it is possible, what it is called, and whether one is already running — three
/// copies of that is how they come to disagree. Failing to initialize *is* the capability check, so
/// a call site that forgets to ask cannot render a control that does nothing.
@MainActor
struct MessageMediaDownloadAction {
    /// What to call the gesture, phrased for the number of files it will actually save.
    let title: String
    /// Whether this message already has a download running. One gesture per message: a second
    /// click must not leave two copies of the same photo in the folder.
    let isInFlight: Bool
    let perform: @MainActor () -> Void

    /// Every attachment on the message — the hover strip and the right-click menu.
    init?(message: MessageItem, workspace: WorkspaceState) {
        self.init(message: message, attachments: message.mediaAttachments, workspace: workspace)
    }

    /// A chosen subset: the gallery saves the photo on screen, not the whole message.
    init?(message: MessageItem, attachments: [MessageMediaAttachment], workspace: WorkspaceState) {
        guard message.canDownloadMediaAttachments, !attachments.isEmpty else { return nil }
        title = MessageItem.mediaDownloadActionTitle(forAttachmentCount: attachments.count)
        isInFlight = workspace.isDownloadingMediaAttachments(for: message)
        perform = {
            Task { await workspace.downloadMediaAttachments(attachments, for: message) }
        }
    }
}
