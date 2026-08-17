import Foundation

/// The result of one "download to Downloads" gesture, rendered as a transient toast in the
/// window's bottom-leading corner.
///
/// It carries counts rather than a rendered sentence: the toast localizes through the injected
/// `\.locale` like every other surface, so a language switch while the toast is up re-renders it.
nonisolated struct MediaDownloadFeedback: Identifiable, Equatable, Sendable {
    /// Monotonic per-workspace, so a second download replaces the first toast instead of
    /// letting the first one's dismissal timer close it.
    let id: UInt64
    let savedCount: Int
    let failedCount: Int

    var hasFailures: Bool {
        failedCount > 0
    }
}
