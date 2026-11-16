import Foundation

/// What the download gestures finished so far have to show for themselves, rendered as a transient
/// toast in the window's bottom-leading corner.
///
/// It carries the saved files and a failure count rather than a rendered sentence: the toast
/// localizes through the injected `\.locale` like every other surface, so a language switch while
/// the toast is up re-renders it, and its Show in Finder button reveals the files themselves. A
/// gesture finishing while the toast is still visible adds to these rather than replacing them —
/// see `WorkspaceState.presentMediaDownloadFeedback(savedFileURLs:failedCount:)`.
nonisolated struct MediaDownloadFeedback: Equatable, Sendable {
    let savedFileURLs: [URL]
    let failedCount: Int

    var savedCount: Int {
        savedFileURLs.count
    }

    var hasFailures: Bool {
        failedCount > 0
    }
}
