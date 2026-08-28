//
//  IdentityKeysSettingsView.swift
//  whitenoise-mac
//
//  The Identity & Keys page: the public identity details, the local signing state
//  behind them, and the private-key backup sheet.
//

import SwiftUI

struct IdentityKeysSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showRemoveAccountConfirmation = false
    @State private var showKeyBackup = false

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Identity & Keys"),
            subtitle: L10n.string("Public identity details and local signing state.")
        ) {
            if let account = workspace.activeAccount {
                SettingsSection(title: L10n.string("Account")) {
                    HStack(spacing: 12) {
                        ProfileImageAvatarView(
                            seed: account.accountIdHex,
                            initials: account.initials,
                            sanitizedPictureURL: account.sanitizedPictureURL,
                            isOwnAccountImage: true,
                            size: 52,
                            isSelected: false
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.displayName)
                                .wnFont(.semiBold14)
                                .lineLimit(1)
                            Text(accountSigningDescription(for: account))
                                .wnFont(.medium10)
                                .foregroundStyle(WNColor.backgroundContentSecondary)
                        }
                    }
                }

                SettingsSection(title: L10n.string("Public Identity")) {
                    let npub = workspace.npub(forAccountIdHex: account.accountIdHex)
                    LabeledContent(L10n.string("npub")) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(npub)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(WNColor.backgroundContentSecondary)
                                .lineLimit(3)
                                .textSelection(.enabled)

                            CopyToClipboardButton(
                                value: npub,
                                actionDescription: L10n.string("Copy npub")
                            ) { isConfirming in
                                Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(
                                        isConfirming
                                            ? WNColor.intentionSuccessContent
                                            : WNColor.backgroundContentPrimary)
                            }
                            .buttonStyle(.borderless)

                            PublicIdentityQRCodeButton(
                                account: account,
                                displayName: account.displayName
                            )
                        }
                    }
                }

                SettingsSection(title: L10n.string("Private Key")) {
                    SettingsValueRow(
                        title: L10n.string("Private key"),
                        value: account.localSigning
                            ? L10n.string("Stored in Keychain")
                            : L10n.string("Not stored on this Mac")
                    )

                    Button {
                        showKeyBackup = true
                    } label: {
                        Label(L10n.string("Back Up Private Key…"), systemImage: "key")
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(!account.localSigning)
                    .help(
                        account.localSigning
                            ? L10n.string("Reveal your nsec or export an encrypted NIP-49 backup")
                            : L10n.string("This account has no private key stored on this Mac"))
                }

                SettingsSection(
                    title: L10n.string("Account Removal"),
                    footer: L10n.string(
                        "Remove this identity from this Mac. Messages and keys managed by Marmot for this account will no longer be available locally."
                    )
                ) {
                    Button {
                        showRemoveAccountConfirmation = true
                    } label: {
                        Label(
                            workspace.isRemovingAccount ? L10n.string("Removing...") : L10n.string("Remove Account"),
                            systemImage: "person.crop.circle.badge.minus")
                    }
                    // Outline rather than red by explicit request, and with no destructive
                    // `role` to contradict that. The confirmation dialog this opens is
                    // system-rendered, so the irreversible step is still the one drawn in red.
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isAccountMutationInProgress)
                }
            } else {
                SettingsSection {
                    ContentUnavailableView("No active account", systemImage: "person.crop.circle.badge.exclamationmark")
                        .frame(minHeight: 220)
                }
            }

        }
        .removeAccountConfirmation(
            account: workspace.activeAccount,
            isPresented: $showRemoveAccountConfirmation,
            isRemoveDisabled: workspace.isAccountMutationInProgress
        ) {
            Task { await workspace.removeActiveAccount() }
        }
        .sheet(isPresented: $showKeyBackup) {
            PrivateKeyBackupSheet()
        }
    }

    private func accountSigningDescription(for account: AccountItem) -> String {
        if account.localSigning {
            return L10n.string("Local signing account")
        }
        return account.externalSigning ? L10n.string("External signing account") : L10n.string("Watch-only account")
    }
}

/// Private-key backup sheet: reveal the raw `nsec` or export a passphrase-encrypted
/// NIP-49 (`ncryptsec`) backup of the active account's signing key.
struct PrivateKeyBackupSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    private enum Mode: Hashable {
        case nsec
        case encrypted
    }

    @State private var mode: Mode = .encrypted
    @State private var passphrase = ""
    @State private var revealedSecret: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("Back Up Private Key"))
                    .wnFont(.semiBold16)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            backupTypeSelector
                .onChange(of: mode) { _, _ in revealedSecret = nil }

            switch mode {
            case .encrypted:
                Text(L10n.string("Protect your key with a passphrase. You'll need it to restore the backup."))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField(L10n.string("Passphrase"), text: $passphrase)
                    .textFieldStyle(.roundedBorder)
            case .nsec:
                // Two lines on purpose: the warning carries the risk, the footnote spells out
                // exactly what "recorded" means. The core writes a per-account audit line
                // holding only a timestamp, a salted account hash, and a surface label — never
                // the key material itself — so say so rather than leaving users to assume the
                // nsec is written to a log.
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        L10n.string("Anyone with your nsec controls this account. Never share it."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(WNColor.intentionWarningContent)

                    Text(
                        L10n.string(
                            "White Noise notes the date and time of each reveal in this account's audit log, kept on this Mac, so you can spot a reveal you didn't make. Your nsec is never written to the log."
                        )
                    )
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                .wnFont(.medium12)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let revealedSecret {
                GroupBox {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(revealedSecret)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        CopyToClipboardButton(
                            value: revealedSecret,
                            actionDescription: L10n.string("Copy")
                        ) { isConfirming in
                            Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(
                                    isConfirming
                                        ? WNColor.intentionSuccessContent
                                        : WNColor.backgroundContentPrimary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    Task { await produceBackup() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .nsec ? L10n.string("Reveal nsec") : L10n.string("Export Backup"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || (mode == .encrypted && passphrase.isEmpty))
            }

            if let error = workspace.lastError {
                Text(error)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentDestructive)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var backupTypeSelector: some View {
        HStack(spacing: 0) {
            backupTypeButton(L10n.string("Encrypted (NIP-49)"), mode: .encrypted)
            backupTypeButton(L10n.string("Raw nsec"), mode: .nsec)
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WNColor.fillSecondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Backup type"))
    }

    private func backupTypeButton(_ title: String, mode targetMode: Mode) -> some View {
        let isSelected = mode == targetMode
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                mode = targetMode
            }
        } label: {
            Text(title)
                .wnFont(.semiBold12)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(
                    isSelected ? WNColor.fillContentPrimary : WNColor.fillContentTertiary
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(WNColor.fillPrimary)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func produceBackup() async {
        isWorking = true
        defer { isWorking = false }
        switch mode {
        case .nsec:
            revealedSecret = await workspace.revealActiveAccountNsec()
        case .encrypted:
            revealedSecret = await workspace.exportActiveAccountEncryptedKey(passphrase: passphrase)
        }
    }
}
