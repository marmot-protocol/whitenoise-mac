//
//  SignInIdentityField.swift
//  whitenoise-mac
//
//  The capsule the sign-in key is typed or pasted into.
//

import AppKit
import SwiftUI

/// The sign-in key field: a masked capsule with one accessory that pastes when the field is
/// empty and clears it when it is not.
///
/// Ported from the prototype's `ProfileKeyInput`. The single dual-purpose accessory is the part
/// worth keeping — a key is pasted far more often than it is typed, and on the one occasion it
/// is wrong the same button is already under the pointer to empty the field.
///
/// The ground is `fillSecondary` with `fillContentSecondary` content, the palette's answer to
/// the phone's `secondarySystemFill`. Both halves come from the *fill* family: pairing a fill
/// background with `backgroundContent*` text is the palette mistake that passes a glance in one
/// appearance and fails in the other.
struct SignInIdentityField: View {
    @Binding var identity: String
    var isEnabled = true
    let onSubmit: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    private var isEmpty: Bool {
        SignInIdentityValidation.normalized(identity).isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            SecureField(L10n.string("nsec1..."), text: $identity)
                .textFieldStyle(.plain)
                .wnFont(.medium14)
                .foregroundStyle(WNColor.fillContentSecondary)
                .focused($isFocused)
                .privacySensitive()
                .onSubmit(onSubmit)
                .padding(.leading, 16)

            Button(action: pasteOrClear) {
                Image(systemName: isEmpty ? "doc.on.clipboard" : "xmark.circle.fill")
                    .wnFont(.medium14)
                    .foregroundStyle(WNColor.fillContentTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .help(isEmpty ? L10n.string("Paste") : L10n.string("Clear"))
            .accessibilityLabel(isEmpty ? L10n.string("Paste") : L10n.string("Clear"))
        }
        .frame(height: 46)
        .background(WNColor.fillSecondary, in: .capsule)
        .overlay {
            Capsule().stroke(borderColor, lineWidth: 1)
        }
        .contentShape(.capsule)
        .onHover { isHovering = $0 }
        .disabled(!isEnabled)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private var borderColor: Color {
        if isFocused { return WNColor.borderPrimary }
        if isHovering { return WNColor.borderSecondary }
        return .clear
    }

    /// One accessory, two jobs — see the type's note. Reading the pasteboard here rather than
    /// leaning on ⌘V is what makes the paste reachable without the field being focused first.
    private func pasteOrClear() {
        guard isEnabled else { return }

        if isEmpty {
            guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
            identity = SignInIdentityValidation.normalized(pasted)
            isFocused = true
        } else {
            identity = ""
            isFocused = true
        }
    }
}

#Preview {
    @Previewable @State var identity = ""

    SignInIdentityField(identity: $identity, onSubmit: {})
        .frame(width: OnboardingMetrics.formColumnWidth)
        .padding(40)
}
