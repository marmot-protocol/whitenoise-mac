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
    let model: ProfileKeysViewModel

    var body: some View {
        SettingsScaffold(title: L10n.string("Profile Keys")) {
            if let account = workspace.activeAccount {
                ProfileKeysPublicKeySection(account: account)
                ProfileKeysPrivateKeySection(model: model, localSigning: account.localSigning)
                if account.localSigning {
                    ProfileKeysBackupSection(
                        isExporting: workspace.isExportingPrivateKey,
                        exportWithoutPassword: {
                            model.hidePrivateKey()
                            await workspace.exportActiveAccountPrivateKey(.raw)
                        },
                        willExportWithPassword: model.hidePrivateKey
                    )
                }
            } else {
                SettingsSection {
                    ContentUnavailableView("No active account", systemImage: "person.crop.circle.badge.exclamationmark")
                        .frame(minHeight: 220)
                }
            }
        }
        // Revealing is per-visit. The model outlives the page (it is account-scoped), so leaving
        // Settings must put the key back behind its bullets and drop any read still in flight.
        .onDisappear { model.reset() }
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
/// Laid out like the iOS client's private-key row (whitenoise-ios #1264): the value, the copy
/// control inside the row, and the eye beside it — the same shape as the public-key row above, so
/// the two keys read as a pair. Both controls ask first; see `ProfileKeysViewModel`.
///
/// The footer carries two sentences and both are load-bearing. The first is the warning. The
/// second is this app's audit-log disclosure: on macOS every reveal, copy and export goes through
/// the core's `revealNsec`, which writes a per-account audit line and downgrades that account's
/// audit data mode. A reader tapping an eye has no way to know that, so the page says it.
struct ProfileKeysPrivateKeySection: View {
    let model: ProfileKeysViewModel
    let localSigning: Bool

    private var footer: String {
        // Two sentences, one footer. `SettingsFooterText` wraps, so the blank line is what keeps
        // the warning and the disclosure from reading as one run-on paragraph.
        [
            L10n.string(
                "Keep this key private. Anyone with it can use your profile, and White Noise can't recover it."),
            L10n.string(
                "White Noise notes the date and time of each reveal, copy or export in this account's audit log, kept on this Mac. Your private key is never written to the log."
            ),
        ]
        .joined(separator: "\n\n")
    }

    var body: some View {
        SettingsSection(
            title: L10n.string("Private Key"),
            footer: localSigning ? footer : nil
        ) {
            if localSigning {
                PrivateKeyRow(model: model)
                if let error = model.error {
                    SettingsStatusNote(
                        text: error,
                        intention: .failure,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }
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
        .alert(
            L10n.string(model.pendingConfirmation?.confirmationTitleKey ?? ""),
            isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { if !$0 { model.cancelRequest() } }
            ),
            presenting: model.pendingConfirmation
        ) { action in
            Button(L10n.string("Cancel"), role: .cancel) { model.cancelRequest() }
            Button(L10n.string(action.confirmButtonKey), role: .destructive) {
                model.confirm(action)
            }
        } message: { _ in
            Text(L10n.string(ProfileKeysViewModel.PrivateKeyAction.confirmationMessageKey))
        }
    }
}

/// The value, its copy control, and the eye — one row, like the public key's.
private struct PrivateKeyRow: View {
    let model: ProfileKeysViewModel

    var body: some View {
        HStack(spacing: 12) {
            PrivateKeyValue(revealedNsec: model.revealedNsec)

            Button {
                model.request(.copy)
            } label: {
                PrivateKeyControlGlyph(
                    systemImage: model.copyConfirmation.isConfirming ? "checkmark" : "doc.on.doc",
                    tint: model.copyConfirmation.isConfirming
                        ? WNColor.intentionSuccessContent
                        : WNColor.backgroundContentPrimary,
                    isLoading: model.actionInFlight == .copy
                )
            }
            .buttonStyle(.borderless)
            .disabled(model.actionInFlight != nil)
            .help(L10n.string("Copy Private Key"))
            .accessibilityLabel(
                Text(model.copyConfirmation.isConfirming ? L10n.string("Copied") : L10n.string("Copy Private Key")))

            Button {
                model.request(.reveal)
            } label: {
                PrivateKeyControlGlyph(
                    systemImage: model.isRevealed ? "eye.slash" : "eye",
                    tint: WNColor.backgroundContentPrimary,
                    isLoading: model.actionInFlight == .reveal
                )
            }
            .buttonStyle(.borderless)
            .disabled(model.actionInFlight != nil)
            .help(model.isRevealed ? L10n.string("Hide private key") : L10n.string("Show private key"))
            .accessibilityLabel(
                Text(model.isRevealed ? L10n.string("Hide private key") : L10n.string("Show private key")))
        }
    }
}

/// The key itself, or as many bullets as fit where it would be.
private struct PrivateKeyValue: View {
    let revealedNsec: String?

    var body: some View {
        Group {
            if let revealedNsec {
                Text(revealedNsec)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Disabled outright, not merely left unset: ContentView turns selection on for
                    // the whole window, and a selectable key could be copied without passing the
                    // "Copy Private Key?" confirmation or getting the concealed pasteboard marker.
                    .textSelection(.disabled)
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
    }
}

/// A row control's glyph, swapped for a spinner of the same footprint while its read is out, so
/// the row does not shift when the core answers.
private struct PrivateKeyControlGlyph: View {
    let systemImage: String
    let tint: Color
    let isLoading: Bool

    var body: some View {
        Image(systemName: systemImage)
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(tint)
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading { ProgressView().controlSize(.small) }
            }
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

/// The two ways the private key becomes a file, under the iOS client's framing: a backup, with the
/// password-protected one first and recommended.
///
/// Ordered rather than presented as equals. The password-protected backup is a NIP-49
/// `ncryptsec1` file that is useless to whoever finds it without the password; the other one is
/// the account itself, in a file, and it goes behind a confirmation that says so.
struct ProfileKeysBackupSection: View {
    let isExporting: Bool
    let exportWithoutPassword: @MainActor () async -> Void
    /// Runs as the password sheet opens, so a revealed key is not left on the page behind it.
    var willExportWithPassword: @MainActor () -> Void = {}

    @State private var isShowingEncryptedExport = false
    @State private var isConfirmingRawExport = false

    var body: some View {
        SettingsSection(title: L10n.string("Back Up Your Private Key")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    L10n.string(
                        "Keep your private key somewhere safe. If you lose it, White Noise can't recover it. We recommend protecting your backup with a password."
                    )
                )
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        willExportWithPassword()
                        isShowingEncryptedExport = true
                    } label: {
                        Label(L10n.string("Back Up With a Password"), systemImage: "lock.doc")
                    }
                    .buttonStyle(.wnSecondary)

                    Button {
                        isConfirmingRawExport = true
                    } label: {
                        Label(L10n.string("Back Up Without a Password"), systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.wnSecondary)
                }
                .disabled(isExporting)
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $isShowingEncryptedExport) {
            EncryptedPrivateKeyExportSheet()
        }
        .confirmationDialog(
            L10n.string("Export Without a Password?"),
            isPresented: $isConfirmingRawExport,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Export Key"), role: .destructive) {
                Task { await exportWithoutPassword() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "We recommend exporting with a password to protect your private key. Without one, anyone with the exported key can use your profile. Keep it safe and don't share it."
                ))
        }
    }
}

#Preview("Private key, concealed") {
    Form {
        ProfileKeysPrivateKeySection(model: .preview(), localSigning: true)
    }
    .formStyle(.grouped)
    .frame(width: 520)
}

#Preview("Private key, revealed") {
    Form {
        ProfileKeysPrivateKeySection(
            model: .preview(revealedNsec: "nsec1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0jqxz3xm"),
            localSigning: true
        )
    }
    .formStyle(.grouped)
    .frame(width: 520)
}

#Preview("Backup") {
    Form {
        ProfileKeysBackupSection(isExporting: false, exportWithoutPassword: {})
    }
    .formStyle(.grouped)
    .frame(width: 520)
}
