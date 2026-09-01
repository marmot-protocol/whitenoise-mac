//
//  ProfileKeysSettingsView.swift
//  whitenoise-mac
//
//  The Profile Keys page: the public key you hand out, the private key you never do, and
//  the two ways the private one leaves this Mac as a file.
//
//  Ported from `wn-ios-prototype`'s `ProfileKeysSettingsView` and the Profile Keys section
//  of its `docs/screens/settings.md`. Three groups, each one key or one task, and each one
//  explained by the note under it rather than by a page subtitle. What the page used to
//  carry and no longer does:
//
//  - **The subtitle.** "Public identity details and local signing state" described the page
//    to someone already reading it. The three group names say the same thing in place.
//  - **The Account group.** An avatar, a name and a signing-mode caption, none of which is a
//    key. The identity the page acts on is the active one — the same one the drawer's
//    profile card and the account rail both show — so restating it here only pushed the
//    first key below the fold.
//  - **Account Removal.** Removing an identity is a way *out* of it, so it belongs with the
//    other one: see `SignOutSheet`, where it is the sheet's wipe toggle.
//

import SwiftUI

struct ProfileKeysSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        SettingsScaffold(title: L10n.string("Profile Keys")) {
            if let account = workspace.activeAccount {
                // The three groups, in the order `ProfileKeysPageContents` names them — no
                // subtitle above them, no Account group, no Account Removal below.
                ForEach(
                    ProfileKeysPageContents.groups(localSigning: account.localSigning),
                    id: \.self
                ) { group in
                    switch group {
                    case .publicKey: ProfileKeysPublicKeySection(account: account)
                    case .privateKey: ProfileKeysPrivateKeySection(account: account)
                    case .export: ProfileKeysExportSection()
                    }
                }
            } else {
                SettingsSection {
                    ContentUnavailableView("No active account", systemImage: "person.crop.circle.badge.exclamationmark")
                        .frame(minHeight: 220)
                }
            }
        }
    }
}

/// The key you hand to other people: the whole thing, on one line, with the copy control at the
/// trailing edge.
///
/// One line and middle-truncated rather than the three wrapped lines this used to draw. An npub is
/// an opaque 63-character string — nobody reads the middle of one, they check the ends against
/// another copy of itself — and three lines of it made the page's first group taller than the two
/// below it combined. The full value is still selectable, and the copy button is what anyone
/// actually uses.
private struct ProfileKeysPublicKeySection: View {
    @Environment(WorkspaceState.self) private var workspace
    let account: AccountItem

    var body: some View {
        SettingsSection(
            title: L10n.string("Public Key"),
            footer: L10n.string("Share this key so people can find and connect with you.")
        ) {
            let npub = workspace.npub(forAccountIdHex: account.accountIdHex)
            HStack(spacing: 12) {
                Text(npub)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(L10n.string("Public Key")))
                    .accessibilityValue(Text(npub))

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

                // Kept where the prototype has nothing, because on iOS the QR code is Share &
                // Connect's job and this app has no such screen — the sheet this opens is the only
                // scannable form of the key anywhere in Settings besides the Profile page.
                PublicIdentityQRCodeButton(
                    account: account,
                    displayName: account.displayName
                )
            }
        }
    }
}

/// The key you never hand to anyone: concealed by default, revealed by the eye, and copyable
/// without being revealed at all.
///
/// The footer carries two sentences and both are load-bearing. The first is the prototype's, and
/// it is the warning. The second is this app's audit-log disclosure, which the sheet this section
/// replaced used to carry: on macOS every one of these three actions goes through the core's
/// `revealNsec`, which writes a per-account audit line and downgrades that account's audit data
/// mode. A reader tapping an eye has no way to know that, so the page says it.
private struct ProfileKeysPrivateKeySection: View {
    @Environment(WorkspaceState.self) private var workspace
    let account: AccountItem

    @State private var revealedNsec: String?
    @State private var isRevealing = false

    private var footer: String {
        // Two sentences, one footer. `SettingsFooterText` wraps, so the blank line is what keeps
        // the warning and the disclosure from reading as one run-on paragraph.
        [
            L10n.string(
                "Keep this key private. Anyone with it can use your profile, and White Noise can't recover it."),
            ProfileKeysPageContents.auditLogDisclosure,
        ]
        .joined(separator: "\n\n")
    }

    var body: some View {
        SettingsSection(
            title: L10n.string("Private Key"),
            footer: account.localSigning ? footer : nil
        ) {
            if account.localSigning {
                keyRow
                PrivateKeyCopyButton()
            } else {
                // One answer for both the watch-only and the external-signer case, because it is
                // the same answer: there is no key here to conceal, copy or export. Which of the
                // two it is belongs to the drawer's profile card, not to a key page.
                SettingsValueRow(
                    title: L10n.string("Private key"),
                    value: L10n.string("Not stored on this Mac")
                )
            }
        }
        // Revealing is per-visit. Leaving the key on screen for the next person to open Settings
        // undoes the point of concealing it, and the value is a copy of secret material held in
        // this view's state for no longer than it is being looked at.
        .onDisappear { revealedNsec = nil }
        .onChange(of: account.id) { _, _ in revealedNsec = nil }
    }

    private var keyRow: some View {
        HStack(spacing: 12) {
            Group {
                if let revealedNsec {
                    Text(revealedNsec)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    ConcealedKeyBullets()
                }
            }
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .privacySensitive()
            // Hidden from speech even while it is on screen: a screen reader reading an nsec
            // aloud is the one disclosure the eye control cannot take back.
            .accessibilityHidden(true)

            Button {
                Task { await toggleReveal() }
            } label: {
                if isRevealing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: revealedNsec == nil ? "eye" : "eye.slash")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                }
            }
            .buttonStyle(.borderless)
            .disabled(isRevealing)
            .help(
                revealedNsec == nil
                    ? L10n.string("Show private key")
                    : L10n.string("Hide private key")
            )
            .accessibilityLabel(
                Text(
                    revealedNsec == nil
                        ? L10n.string("Show private key")
                        : L10n.string("Hide private key")))
        }
    }

    private func toggleReveal() async {
        guard revealedNsec == nil else {
            revealedNsec = nil
            return
        }
        isRevealing = true
        defer { isRevealing = false }
        revealedNsec = await workspace.revealActiveAccountNsec()
    }
}

/// Copies the private key without revealing it.
///
/// Its own view rather than a `CopyToClipboardButton`, because that control is handed the value up
/// front and the value here does not exist until the core is asked for it. The confirmation window
/// is the same `CopyConfirmation`, so this button and every other copy affordance in the app agree
/// about how long a checkmark stays up.
private struct PrivateKeyCopyButton: View {
    @Environment(WorkspaceState.self) private var workspace

    @State private var confirmation = CopyConfirmation()
    @State private var isCopying = false

    var body: some View {
        Button {
            Task { await copy() }
        } label: {
            Label(
                L10n.string("Copy Private Key"),
                systemImage: confirmation.isConfirming ? "checkmark" : "doc.on.doc"
            )
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.wnSecondary)
        .disabled(isCopying)
        .accessibilityLabel(Text(L10n.string("Copy Private Key")))
    }

    private func copy() async {
        isCopying = true
        defer { isCopying = false }
        guard let nsec = await workspace.revealActiveAccountNsec() else { return }
        workspace.copyText(nsec, concealed: true)
        confirmation.confirm()
        AccessibilityNotification.Announcement(L10n.string("Copied")).post()
    }
}

/// The concealed private key: as many whole bullets as fit the value area, and not one partial one.
///
/// A fixed run of bullets is the obvious thing and it is wrong in both directions — too few leaves
/// a gap that reads as an empty field, too many overflow or truncate with an ellipsis that reads as
/// part of the key. Measuring one bullet and drawing `floor(width / bulletWidth)` of them is the
/// shape `wn-ios-prototype` draws, and it is why the row looks like a filled field at every pane
/// width.
private struct ConcealedKeyBullets: View {
    var body: some View {
        // The hidden `Text` is the height source: a `Canvas` alone has no intrinsic size, so it
        // would collapse the row. It also pins the font the `Canvas` resolves against.
        Text(verbatim: "•")
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                Canvas { context, size in
                    let bullet = context.resolve(Text(verbatim: "•").font(.system(.callout, design: .monospaced)))
                    let bulletSize = bullet.measure(in: size)
                    guard bulletSize.width > 0 else { return }

                    for index in 0..<Int(size.width / bulletSize.width) {
                        context.draw(
                            bullet,
                            at: CGPoint(x: CGFloat(index) * bulletSize.width, y: size.height / 2),
                            anchor: .leading
                        )
                    }
                }
            }
    }
}

/// The two ways the private key becomes a file: password-protected first, plaintext second.
///
/// Ordered rather than presented as equals. The encrypted export is a NIP-49 `ncryptsec1` file that
/// is useless to whoever finds it without the password; the raw one is the account itself, in a
/// file, and it goes behind a confirmation that says so.
private struct ProfileKeysExportSection: View {
    @Environment(WorkspaceState.self) private var workspace

    @State private var isShowingEncryptedExport = false
    @State private var isConfirmingRawExport = false

    var body: some View {
        SettingsSection(title: L10n.string("Export")) {
            Button {
                isShowingEncryptedExport = true
            } label: {
                Label(L10n.string("Export Encrypted Private Key"), systemImage: "lock.doc")
            }
            .buttonStyle(.wnSecondary)
            .disabled(workspace.isExportingPrivateKey)

            Button {
                isConfirmingRawExport = true
            } label: {
                Label(L10n.string("Export Private Key"), systemImage: "arrow.down.doc")
            }
            .buttonStyle(.wnSecondary)
            .disabled(workspace.isExportingPrivateKey)
        }
        .sheet(isPresented: $isShowingEncryptedExport) {
            EncryptedPrivateKeyExportSheet()
        }
        .confirmationDialog(
            L10n.string("Keep your private key safe"),
            isPresented: $isConfirmingRawExport,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Export Private Key"), role: .destructive) {
                Task { await workspace.exportActiveAccountPrivateKey(.raw) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "This file holds your key in plain text. Anyone who opens it controls this account. The encrypted export or a trusted password manager is safer."
                ))
        }
    }
}
