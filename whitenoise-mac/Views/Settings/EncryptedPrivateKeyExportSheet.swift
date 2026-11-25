//
//  EncryptedPrivateKeyExportSheet.swift
//  whitenoise-mac
//
//  Setting the password for a NIP-49 (`ncryptsec1`) export of the active account's private
//  key, then handing off to the save panel.
//

import SwiftUI

struct EncryptedPrivateKeyExportSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SettingsWindowCoordinator.self) private var settings: SettingsWindowCoordinator?
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmation = ""
    @FocusState private var isPasswordFocused: Bool

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
                    .font(.headline)
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
                SecureField(L10n.string("Password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($isPasswordFocused)
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
                            "Use a long, unique password. You'll need it to open the encrypted backup. White Noise never stores it."
                        )
                    )
                    .font(.subheadline)
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
                .wnSecondaryButtonStyle()
                .keyboardShortcut(.cancelAction)
                .disabled(workspace.isExportingPrivateKey)

                Button(action: { Task { await export() } }) {
                    if workspace.isExportingPrivateKey {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.string("Export"))
                    }
                }
                .wnPrimaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady || workspace.isExportingPrivateKey)
            }
            .wnSheetFooterButtons()

            if let error = settings?.lastError {
                SettingsErrorView(error: error)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(workspace.isExportingPrivateKey)
        .onAppear {
            workspace.setSettingsError(nil)
            isPasswordFocused = true
        }
    }

    private func export() async {
        if await workspace.exportActiveAccountPrivateKey(.encrypted, passphrase: password) {
            dismiss()
        }
    }
}

/// The strength rating: the word, then the bar.
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
                .font(.subheadline)
                .foregroundStyle(WNColor.backgroundContentSecondary)

            Text(L10n.string(strength.labelKey))
                .font(.subheadline.weight(.semibold))
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

#Preview("Encrypted private key export") {
    EncryptedPrivateKeyExportSheet()
        .environment(WorkspaceState.preview())
}
