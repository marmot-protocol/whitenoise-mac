//
//  OnboardingKeyField.swift
//  whitenoise-mac
//
//  The sign-in pane's one input: a private key, and the two things you ever do
//  to it.
//

import AppKit
import SwiftUI

/// The private-key field, with a paste-or-clear accessory inside it.
///
/// Ported from `wn-ios-prototype`'s `ProfileKeyInput`, which is where the single-accessory idea
/// comes from: one button in the trailing edge that pastes while the field is empty and clears it
/// once it is not, so the field never shows two controls and the accessory is always the thing you
/// would reach for next. Kept because it is just as true with a pointer as with a thumb.
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
struct OnboardingKeyField: View {
    @Binding var text: String
    var isEnabled = true
    let onSubmit: () -> Void

    @Environment(\.wnButtonShape) private var buttonShape
    @FocusState private var isFocused: Bool

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 4) {
            SecureField(L10n.string("nsec1..."), text: $text)
                .textFieldStyle(.plain)
                .privacySensitive()
                .focused($isFocused)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("onboarding.key-field")

            Button {
                if isEmpty {
                    pasteFromClipboard()
                } else {
                    text = ""
                }
            } label: {
                Image(systemName: isEmpty ? "doc.on.clipboard" : "xmark.circle.fill")
                    .contentTransition(.symbolEffect(.replace))
                    // The glyph sits on `fillSecondary`, so it takes that family's content token
                    // rather than the ambient `backgroundContentPrimary`. See the pairing rule in
                    // `WNNSColor`.
                    .foregroundStyle(WNColor.fillContentSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(L10n.string(isEmpty ? "Paste" : "Clear"))
            .accessibilityLabel(L10n.string(isEmpty ? "Paste" : "Clear"))
            .accessibilityIdentifier("onboarding.key-field.accessory")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: Metrics.height)
        .background { shape.fill(WNColor.fillSecondary) }
        .disabled(!isEnabled)
        .animation(.default, value: isEmpty)
    }

    /// Read through the shared table at `.large`, the size the pane sets on the button below this
    /// field, so the two cannot drift apart. A property on the view rather than a constant in
    /// `Metrics`, because that table is MainActor-isolated like the rest of the module and a
    /// `static let` cannot call into it.
    private var shape: AnyShape {
        WNButtonMetrics.backgroundShape(buttonShape, for: .large)
    }

    private func pasteFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum Metrics {
        /// Tall enough to sit above a `.large` push button without looking like a smaller control
        /// than the one that submits it.
        static let height: CGFloat = 40
    }
}
