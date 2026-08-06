import SwiftUI

/// The transient "Copied" state behind a copy affordance.
///
/// Kept out of the view so the reset window is unit-testable, and so one copy action can flip
/// several elements (glyph, title, tint) from a single source of truth.
@Observable
final class CopyConfirmation {
    /// How long the confirmation stays up. Matches the iOS client's copy affordance.
    static let defaultDuration = Duration.seconds(1.5)

    private(set) var isConfirming = false

    private let duration: Duration
    private var resetTask: Task<Void, Never>?

    init(duration: Duration = CopyConfirmation.defaultDuration) {
        self.duration = duration
    }

    /// Shows the confirmation and schedules its reset. A repeated copy restarts the window rather
    /// than letting the earlier call's pending reset clear it out from under the new copy.
    func confirm() {
        resetTask?.cancel()
        withAnimation(.smooth(duration: 0.15)) { isConfirming = true }
        resetTask = Task { [duration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.2)) { isConfirming = false }
        }
    }
}

/// A copy-to-clipboard button that confirms the copy in place: the glyph flips to a green
/// checkmark for ~1.5s, matching the iOS client.
///
/// macOS raises no system-level confirmation when an app writes to the pasteboard, so a bare copy
/// button leaves the user unable to tell a successful copy from a click that missed. `label`
/// receives `true` while the confirmation is showing, so each call site keeps its own styling and
/// decides whether to also swap its title.
struct CopyToClipboardButton<Label: View>: View {
    @Environment(WorkspaceState.self) private var workspace

    /// The full value written to the pasteboard.
    let value: String
    /// Localized description of the action, e.g. "Copy npub". Used for the tooltip and the
    /// accessibility label, both of which must stay stable while the glyph is a checkmark.
    let actionDescription: String
    /// Whether the value is private-messenger content; see `WorkspaceState.copyText(_:concealed:)`.
    var concealed = true
    @ViewBuilder var label: (Bool) -> Label

    @State private var confirmation = CopyConfirmation()

    var body: some View {
        Button {
            workspace.copyText(value, concealed: concealed)
            confirmation.confirm()
            // The checkmark is invisible to VoiceOver, so announce the same result it conveys.
            AccessibilityNotification.Announcement(L10n.string("Copied")).post()
        } label: {
            label(confirmation.isConfirming)
        }
        .help(actionDescription)
        .accessibilityLabel(actionDescription)
    }
}
