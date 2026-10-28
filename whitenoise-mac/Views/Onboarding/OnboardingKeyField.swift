//
//  OnboardingKeyField.swift
//  whitenoise-mac
//
//  The sign-in pane's one input: a private key, and the two things you ever do
//  to it.
//

import AppKit
import SwiftUI

/// The private-key field: reveal inside it, paste-or-clear beside it.
///
/// Laid out the way `whitenoise-ios`'s `ImportIdentityView` lays it out. Beside the field sits one
/// disc, the app's secondary circle control, that pastes while the field is empty and clears it
/// once it is not — always there, so the field keeps one width from the first keystroke to the
/// last. Inside the trailing edge is only the show/hide-key toggle, once there is a key to show.
/// (iOS's disc scans a QR code while the field is empty and dismisses the keyboard while it is
/// focused; a Mac has neither, so here it is paste and clear.)
///
/// The mac differences:
///
/// * **The ground is `fillSecondary`, not `.secondarySystemFill`.** Same intent, drawn from the
///   palette. It is deliberately *not* the raised button's ground: this is an input you type into,
///   the button below it is a surface you press, and the prototype separates them the same way —
///   `.secondarySystemFill` here against `.buttonStyle(.glass)` there. What the two do share is
///   the column width and the shape.
/// * **The shape is whatever the pane asked its buttons for**, read from `\.wnButtonShape` rather
///   than named here. The rule this field actually obeys is "match the button directly below me",
///   because a capsule above a rounded rectangle is two shapes in one column — so the way to keep
///   obeying it is to read the same value that button reads. Onboarding sets `.capsule`, which is
///   what the prototype draws (`Color(uiColor: .secondarySystemFill), in: .capsule`); this field
///   spent one revision as a 12pt rounded rectangle only because the buttons under it were.
/// * **Paste reads `NSPasteboard`.** The prototype fills in a canned key because it has no
///   clipboard to read. Nothing is validated on the way in — a bad paste should show the field's
///   own complaint, not silently do nothing.
/// * **Revealing swaps the field.** AppKit has no secure-entry toggle on a live field the way
///   UIKit does, so a revealed key is a plain `TextField` in the `SecureField`'s place, focus
///   carried across. Emptying the field hides the key again, as iOS does, so the next key pasted
///   in starts out hidden.
struct OnboardingKeyField: View {
    @Binding var text: String
    var isEnabled = true
    let onSubmit: () -> Void

    @Environment(\.wnButtonShape) private var buttonShape
    @FocusState private var isFocused: Bool
    @State private var isRevealed = false

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            OnboardingKeyInput(
                text: $text,
                isEmpty: isEmpty,
                isRevealed: $isRevealed,
                isFocused: $isFocused,
                shape: shape,
                onSubmit: onSubmit
            )

            // The secondary disc, not a tinted one: iOS draws it as untinted `.glass`, a side
            // control beside the input rather than an action competing with Sign In.
            GlassCircleCloseButton(
                symbol: isEmpty ? "doc.on.clipboard" : "xmark",
                help: isEmpty ? "Paste" : "Clear",
                appearance: .outline
            ) {
                if isEmpty {
                    pasteFromClipboard()
                } else {
                    text = ""
                }
            }
            .accessibilityLabel(L10n.string(isEmpty ? "Paste" : "Clear"))
            .accessibilityIdentifier("onboarding.key-field.accessory")
        }
        .onChange(of: isEmpty) { _, isEmpty in
            if isEmpty { isRevealed = false }
        }
        .disabled(!isEnabled)
    }

    private func pasteFromClipboard() {
        guard let key = Self.pastedKey(from: .general) else { return }
        text = key
    }

    /// What the paste button puts in the field: the pasteboard's text on one line, without the
    /// whitespace around it. `nil` — leave the field alone — when there is no text to paste.
    static func pastedKey(from pasteboard: NSPasteboard) -> String? {
        guard let pasted = pasteboard.string(forType: .string) else { return nil }
        return singleLine(pasted).trimmingCharacters(in: .whitespaces)
    }

    /// `text` with its line breaks taken out, and the whitespace either side of each one with
    /// them, so a key that arrives wrapped across lines — copied out of a note, a password
    /// manager's notes field, or a terminal at a narrow width — goes back together as one key on
    /// one line. A key never contains whitespace, so nothing that belongs to it is lost. Text with
    /// no line break comes back untouched, so a space typed mid-entry is not eaten under the caret.
    static func singleLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
    }

    /// Read through the shared table at `.large`, the size the pane sets on the button below this
    /// field, so the two cannot drift apart. A property on the view rather than a constant in
    /// `Metrics`, because that table is MainActor-isolated like the rest of the module and a
    /// `static let` cannot call into it.
    private var shape: AnyShape {
        WNButtonMetrics.backgroundShape(buttonShape, for: .large)
    }

    fileprivate enum Metrics {
        /// Tall enough to sit above a `.large` push button without looking like a smaller control
        /// than the one that submits it.
        static let height: CGFloat = 40
    }

    /// Where the key's first character sits, measured from the pill's leading edge. The pane
    /// insets the field's label and the hint-or-error line under it by the same amount, so all
    /// three start on one line — the way `whitenoise-ios` lines up its section label, its field
    /// text and its footer.
    static let textInset: CGFloat = 12
}

/// The pill itself: the key, and the show/hide toggle in its trailing edge.
private struct OnboardingKeyInput: View {
    @Binding var text: String
    let isEmpty: Bool
    @Binding var isRevealed: Bool
    var isFocused: FocusState<Bool>.Binding
    let shape: AnyShape
    let onSubmit: () -> Void

    /// The field never holds a line break, however it gets one: a ⌘V of several lines would
    /// otherwise draw the key on two or more lines inside a one-line pill.
    private var singleLineText: Binding<String> {
        Binding(
            get: { text },
            set: { text = OnboardingKeyField.singleLine($0) }
        )
    }

    private var revealTitle: String {
        L10n.string(isRevealed ? "Hide private key" : "Show private key")
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if isRevealed {
                    TextField(L10n.string("nsec1..."), text: singleLineText)
                        .autocorrectionDisabled()
                } else {
                    SecureField(L10n.string("nsec1..."), text: singleLineText)
                }
            }
            .lineLimit(1)
            .textFieldStyle(.plain)
            .privacySensitive()
            .focused(isFocused)
            .onSubmit(onSubmit)
            .accessibilityIdentifier("onboarding.key-field")

            Button(action: toggleReveal) {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .contentTransition(.symbolEffect(.replace))
                    // The glyph sits on `fillSecondary`, so it takes that family's content token
                    // rather than the ambient `backgroundContentPrimary`. See the pairing rule in
                    // `WNNSColor`.
                    .foregroundStyle(WNColor.fillContentSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(revealTitle)
            .accessibilityLabel(revealTitle)
            .accessibilityIdentifier("onboarding.key-field.reveal")
            // Hidden rather than removed while there is nothing to reveal, so the text area keeps
            // its width on the keystroke that fills the field.
            .opacity(isEmpty ? 0 : 1)
            .disabled(isEmpty)
            .accessibilityHidden(isEmpty)
            // Scoped to the toggle rather than applied to the whole row. The row contains a live
            // `NSSecureTextField`: an implicit animation up there wraps the *editor* in an
            // animated transaction on the very keystroke that inserts text, which is not something
            // an AppKit field editor is asked to survive.
            .animation(.default, value: isEmpty)
            .animation(.default, value: isRevealed)
        }
        .padding(.leading, OnboardingKeyField.textInset)
        .padding(.trailing, 6)
        .frame(height: OnboardingKeyField.Metrics.height)
        .background { shape.fill(WNColor.fillSecondary) }
        // The field owns its own edge, rather than trusting the one AppKit happens to give it.
        //
        // A focused `SecureField` is drawn by a field editor — an `NSSecureTextView` that AppKit
        // sizes to the *whole* secret and then slides sideways to keep the insertion point in
        // view. Paste a 63-character nsec into this 314pt field and that editor is 523pt wide,
        // starting 205pt to the **left** of the pill: measured on this pane, the field sits at
        // x=433.5 w=318 while its editor sits at x=228 w=523.5. Nothing in this view clipped it.
        // It stayed inside only because AppKit interposes a private `_NSKeyboardFocusClipView`
        // sized to the field — a view neither SwiftUI nor this app asks for, sizes, or can count
        // on. Where that interposition does not happen, the secret's dots draw straight out of
        // the input and across the empty band under the mark — which is what a pasted key looked
        // like when this was reported. Disabling that private view's clipping reproduces it
        // exactly: ink from x=231.5 with the pill starting at x=421.5.
        //
        // So the containment is stated here. It costs nothing when AppKit already clips — the
        // editor's visible text is inside the pill either way — and it is the difference between
        // the input having an edge and the input borrowing one.
        .clipShape(shape)
    }

    /// The swap replaces the field, and the new one does not inherit focus on its own; hand it
    /// back on the next turn, once the replacement exists to take it.
    ///
    /// Focus alone is not enough. An `NSTextField` that becomes first responder selects its whole
    /// contents, so the swapped-in field came up with the key highlighted and no caret — the
    /// insertion point is not drawn over a selection. So the caret is read off the field editor
    /// before the swap and put back once the replacement's editor is up.
    private func toggleReveal() {
        let wasFocused = isFocused.wrappedValue
        let caret = Self.focusedFieldEditor()?.selectedRange()
        isRevealed.toggle()
        guard wasFocused else { return }
        let revealed = isRevealed
        Task {
            isFocused.wrappedValue = true
            // The replacement field is created and focused on a later pass of the run loop, not
            // within this task, so wait for its editor rather than assume a number of turns.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(10))
                guard let editor = Self.focusedFieldEditor(),
                    let field = editor.delegate as? NSTextField,
                    (field is NSSecureTextField) == !revealed
                else { continue }
                let length = (editor.string as NSString).length
                let location = min(caret?.location ?? length, length)
                let selectionLength = min(caret?.length ?? 0, length - location)
                editor.setSelectedRange(NSRange(location: location, length: selectionLength))
                return
            }
        }
    }

    /// The text view AppKit edits the focused field through, if a field is being edited.
    private static func focusedFieldEditor() -> NSTextView? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor
        else { return nil }
        return editor
    }
}

#Preview("Empty") {
    OnboardingKeyField(text: .constant(""), onSubmit: {})
        .frame(width: OnboardingLayout.contentWidth)
        .padding()
        .wnButtonShape(.capsule)
}

#Preview("Filled") {
    OnboardingKeyField(text: .constant("nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"), onSubmit: {})
        .frame(width: OnboardingLayout.contentWidth)
        .padding()
        .wnButtonShape(.capsule)
}
