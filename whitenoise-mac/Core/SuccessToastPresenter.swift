import Foundation

/// Transient success feedback for an action whose only other evidence is invisible — a pasteboard
/// write, above all. macOS raises no system-level confirmation when an app writes to the
/// pasteboard, so without this the user cannot tell a copy that landed from a click that missed.
///
/// Mirrors the Flutter client's `WnSystemNotice` in its temporary variant: a second action replaces
/// the notice in place rather than queueing behind it, and the notice clears itself after
/// `defaultDuration`.
///
/// State lives here rather than in the view for two reasons. The auto-hide window is unit-testable
/// this way; and an action buried in a context menu or an overflow popover — neither of which
/// reliably inherits an injected environment value in this app — can raise a notice that a
/// container several levels up draws.
@Observable
final class SuccessToastPresenter {
    /// How long a notice stays up. Matches the Flutter client's temporary-notice auto-hide window.
    static let defaultDuration = Duration.seconds(3)

    /// The notice on screen, or `nil` when nothing is showing.
    private(set) var message: String?

    /// Containers that can draw a notice, in the order they installed themselves.
    ///
    /// Only the last one draws. A sheet installs its own surface on top of the window's, and macOS
    /// draws a sheet in a child window above every part of its parent — so without this ordering a
    /// copy made inside a sheet would paint the toast twice: once inside the sheet and once on the
    /// window behind it, where the sheet does not cover it.
    private(set) var surfaces: [UUID] = []

    private let duration: Duration
    private var dismissTask: Task<Void, Never>?

    init(duration: Duration = SuccessToastPresenter.defaultDuration) {
        self.duration = duration
    }

    /// The surface responsible for drawing the current notice: the most recently installed one.
    var drawingSurface: UUID? { surfaces.last }

    /// Shows `message` and schedules its clear. A second call restarts the window rather than
    /// letting the earlier call's pending clear blank the newer notice out from under the user.
    func show(_ message: String) {
        dismissTask?.cancel()
        self.message = message
        dismissTask = Task { [duration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self.message = nil
        }
    }

    /// Clears the notice now, cancelling any pending auto-hide.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        message = nil
    }

    /// Registers a container as able to draw notices. Idempotent, because a view's `onAppear` can
    /// run again without an intervening `onDisappear`.
    func installSurface(_ id: UUID) {
        guard !surfaces.contains(id) else { return }
        surfaces.append(id)
    }

    func removeSurface(_ id: UUID) {
        surfaces.removeAll { $0 == id }
    }
}
