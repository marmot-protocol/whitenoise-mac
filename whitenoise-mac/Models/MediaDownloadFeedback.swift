import Foundation

/// What the download gestures finished so far have to show for themselves, rendered as a transient
/// toast in the window's bottom-leading corner.
///
/// It carries counts rather than a rendered sentence: the toast localizes through the injected
/// `\.locale` like every other surface, so a language switch while the toast is up re-renders it.
/// A gesture finishing while the toast is still visible adds to these counts rather than replacing
/// them — see `WorkspaceState.presentMediaDownloadFeedback(savedCount:failedCount:)`.
nonisolated struct MediaDownloadFeedback: Equatable, Sendable {
    let savedCount: Int
    let failedCount: Int

    var hasFailures: Bool {
        failedCount > 0
    }
}
