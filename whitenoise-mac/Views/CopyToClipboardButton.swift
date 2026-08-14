import SwiftUI

/// A copy-to-clipboard button that confirms the copy with the app's green success toast.
///
/// macOS raises no system-level confirmation when an app writes to the pasteboard, so a bare copy
/// button leaves the user unable to tell a successful copy from a click that missed. The
/// confirmation is a toast rather than a glyph swap on the button itself, matching how every other
/// White Noise client reports a quiet success — and unlike an in-place checkmark it is legible from
/// wherever on the surface the user is actually looking.
struct CopyToClipboardButton<Label: View>: View {
    @Environment(WorkspaceState.self) private var workspace

    /// The full value written to the pasteboard.
    let value: String
    /// Localized description of the action, e.g. "Copy npub". Used for the tooltip and the
    /// accessibility label.
    let actionDescription: String
    /// Localized confirmation the toast carries, e.g. "Public key copied to clipboard". Names the
    /// value rather than the control, because the toast is read away from the button.
    let successMessage: String
    /// Whether the value is private-messenger content; see `WorkspaceState.copyText(_:concealed:notice:)`.
    var concealed = true
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            workspace.copyText(value, concealed: concealed, notice: successMessage)
        } label: {
            label()
        }
        .help(actionDescription)
        .accessibilityLabel(actionDescription)
    }
}
