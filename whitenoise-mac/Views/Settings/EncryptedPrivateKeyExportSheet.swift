//
//  EncryptedPrivateKeyExportSheet.swift
//  whitenoise-mac
//
//  Setting the password for a NIP-49 (`ncryptsec1`) export of the active account's private
//  key, then handing off to the save panel.
//

import SwiftUI

/// The password gate in front of the encrypted export.
///
/// Ported from `wn-ios-prototype`'s `EncryptedPrivateKeySheet`, with its three decisions kept:
///
/// - **The mismatch replaces the guidance,** in the same place, rather than appearing as a row of
///   its own. A separate error row shifts everything under it on the first wrong keystroke.
/// - **The strength rating keeps its word,** and adds the colour. Red / yellow / green alone is
///   the one signal a reader who cannot separate them gets nothing from.
/// - **Export becomes available only when both fields are non-empty and equal.** An empty password
///   would produce an `ncryptsec1` file anyone can open — worse than the plaintext export,
///   because it looks protected.
///
/// The rating and the readiness rule are `PrivateKeyExportPasswordStrength` and
/// `PrivateKeyExportPasswordEntry`, so neither is a chain of `&&` inside this body.
struct EncryptedPrivateKeyExportSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmation = ""

    private var isReady: Bool {
        PrivateKeyExportPasswordEntry.isReady(password: password, confirmation: confirmation)
    }

    private var showsMismatch: Bool {
        PrivateKeyExportPasswordEntry.showsMismatch(password: password, confirmation: confirmation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("Encrypted Private Key"))
                    .wnFont(.semiBold16)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(workspace.isExportingPrivateKey)
                .accessibilityLabel(Text(L10n.string("Close")))
            }

            VStack(alignment: .leading, spacing: 8) {
                // Native field chrome, not a custom-drawn one: AppKit puts a `SecureField`'s
                // editor in a private focus clip view, and a field that draws its own ground has
                // to clip itself or the editor lands next to the field rather than inside it.
                SecureField(L10n.string("Password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField(L10n.string("Confirm Password"), text: $confirmation)
                    .textFieldStyle(.roundedBorder)

                if showsMismatch {
                    SettingsStatusNote(
                        text: L10n.string("Passwords don't match."),
                        intention: .failure,
                        systemImage: "exclamationmark.circle.fill"
                    )
                } else {
                    Text(
                        L10n.string(
                            "Use a long, unique password. You'll need it to open the encrypted file.")
                    )
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !password.isEmpty {
                PasswordStrengthReadout(strength: .evaluate(password))
            }

            HStack(spacing: 10) {
                Spacer()
                Button(L10n.string("Cancel")) {
                    dismiss()
                }
                .buttonStyle(.wnSecondary)
                .disabled(workspace.isExportingPrivateKey)

                WNPrimaryButton(action: { Task { await export() } }) {
                    if workspace.isExportingPrivateKey {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.string("Export"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady || workspace.isExportingPrivateKey)
            }

            if let error = workspace.lastError {
                SettingsErrorView(error: error)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            // A failure from minutes ago — a profile save, a relay write — would render under the
            // password fields as though this sheet had produced it. `exportActiveAccountPrivateKey`
            // clears it on entry too; this covers the window before anything is pressed.
            workspace.lastError = nil
        }
    }

    private func export() async {
        // Dismiss only on a written file. A cancelled save panel, a wrong-account guard or a
        // failed write all leave the sheet up with the password still typed, so the reader can
        // retry rather than start over — and `lastError` has somewhere to be read.
        if await workspace.exportActiveAccountPrivateKey(.encrypted, passphrase: password) {
            dismiss()
        }
    }
}

/// The strength rating: the word, then the bar.
///
/// The word leads because it is the part that survives being unable to tell the three colours
/// apart, and the bar's tint comes from `SettingsStatusNote.Intention` so a rating cannot be drawn
/// in a colour the palette has no meaning for.
private struct PasswordStrengthReadout: View {
    let strength: PrivateKeyExportPasswordStrength

    private var intention: SettingsStatusNote.Intention {
        switch strength {
        case .low: .failure
        case .fair: .warning
        case .strong: .success
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.string("Strength"))
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)

            Text(L10n.string(strength.labelKey))
                .wnFont(.semiBold12)
                .foregroundStyle(intention.color)

            Spacer(minLength: 8)

            ProgressView(
                value: Double(strength.rawValue),
                total: PrivateKeyExportPasswordStrength.scale
            )
            .tint(intention.color)
            .frame(width: 120)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.string("Strength")))
        .accessibilityValue(Text(L10n.string(strength.labelKey)))
    }
}
