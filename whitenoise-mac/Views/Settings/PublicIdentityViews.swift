//
//  PublicIdentityViews.swift
//  whitenoise-mac
//
//  The ways an account's public identity is shown: as a scannable QR code, as a
//  truncated, copyable `npub`, and as a NIP-05 Nostr address. Shared by the Profile
//  and Identity & Keys pages and by the account switcher, so none of them owns them.
//

import AppKit
import CoreImage
import SwiftUI

/// How prominent the QR affordance is at a given call site.
enum PublicIdentityQRCodeButtonStyle {
    /// A bare glyph sitting inside a row of other text — an account switcher entry, a key row.
    case inline
    /// A tile that stands next to a `WNCopyCard` and matches its height, for the screens where
    /// handing your identity to someone else is the point rather than an aside.
    case tile
}

struct PublicIdentityQRCodeButton: View {
    @State private var isPresented = false
    @State private var isHovering = false
    /// The account whose identity the sheet shows. Carried whole rather than as a hex id so the
    /// sheet can draw its avatar without looking it back up.
    let account: AccountItem
    let displayName: String
    var style: PublicIdentityQRCodeButtonStyle = .inline

    var body: some View {
        // The two styles differ in their button style as well as their label, and `buttonStyle`
        // has to be applied to the `Button` itself, so the branch covers the whole control.
        Group {
            switch style {
            case .inline:
                Button {
                    isPresented = true
                } label: {
                    Image(systemName: "qrcode")
                        .wnFont(.semiBold14)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
            case .tile:
                Button {
                    isPresented = true
                } label: {
                    Image(systemName: "qrcode")
                        .wnFont(.medium24)
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                        .frame(width: 56)
                        .frame(maxHeight: .infinity)
                        .background(
                            isHovering ? WNColor.fillSecondaryHover : WNColor.fillSecondary,
                            in: .rect(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(.rect(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
            }
        }
        .help(L10n.string("Show npub QR code"))
        .accessibilityLabel(Text(L10n.string("Show npub QR code")))
        .sheet(isPresented: $isPresented) {
            PublicIdentityQRCodeSheet(account: account, displayName: displayName)
        }
    }
}

/// The identity you hand to someone else, drawn the way the other clients draw their Share
/// Profile screen: avatar, name, Nostr address, npub, then the code, then the caption that says
/// what the code is for. Ordering, spacing and tokens follow the Flutter client's
/// `share_profile_screen.dart`, which is the design source of truth for this surface; the iOS
/// prototype's Share/Connect segmented control and its Share toolbar action are deliberately
/// absent, because neither has a macOS counterpart — there is no camera scanner here, and
/// handing the npub on is what the copy card already does.
///
/// Only ever shown for an account signed in on this Mac, and in practice only for the active
/// one: all three call sites read `activeAccount`. `nostrAddress` is read from
/// `profileDraft` for that reason, and returns nil for any other account rather than showing
/// the active account's address under someone else's name.
struct PublicIdentityQRCodeSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let account: AccountItem
    /// The name to draw. Separate from `account.displayName` so the Profile page can show the
    /// name being typed into its form rather than the last published one.
    let displayName: String

    /// The Flutter client's `WnAvatarSize.large`, and the third-of-the-width the prototype's
    /// header lands on at an iPhone's width.
    private let avatarSize: CGFloat = 96
    /// `share_profile_screen.dart` caps the matrix at 256 regardless of the width it is given.
    private let codeSize: CGFloat = 256
    /// The prototype hugs its matrix with 12pt inside a card 81% of a phone's width — a hair
    /// under 4%. Kept as a ratio of *this* card rather than as its 12pt, which would be three
    /// times the quiet zone at this size.
    private let codePadding: CGFloat = 10
    /// `ShareableCodeViews.CompactCopyValueLabel`'s split: enough of the head to recognise the
    /// key, enough of the tail to check it against another copy of itself.
    private let npubHead = 14
    private let npubTail = 4

    private var npub: String {
        workspace.npub(forAccountIdHex: account.accountIdHex)
    }

    private var nostrAddress: String? {
        Self.nostrAddress(
            for: account.accountIdHex,
            loadedFor: workspace.activeAccount?.accountIdHex,
            nip05: workspace.profileDraft.nip05
        )
    }

    /// The NIP-05 to draw under `accountIdHex`, given the account `profileDraft` was loaded for.
    ///
    /// `profileDraft` holds exactly one account's metadata — whichever `loadSettingsData()` last
    /// ran — so its `nip05` is only *this* account's address when the two ids agree. Without that
    /// check a sheet opened for any other identity would caption it with the active account's
    /// address, which is a wrong claim about who someone is rather than a missing field. NIP-05 is
    /// not editable anywhere in the app, so when the ids do agree the draft cannot have drifted
    /// from what was published.
    nonisolated static func nostrAddress(
        for accountIdHex: String,
        loadedFor loadedAccountIdHex: String?,
        nip05: String
    ) -> String? {
        guard loadedAccountIdHex == accountIdHex else { return nil }
        return nip05.nilIfBlank
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileImageAvatarView(
                seed: account.accountIdHex,
                initials: displayName,
                sanitizedPictureURL: account.sanitizedPictureURL,
                isOwnAccountImage: true,
                size: avatarSize,
                isSelected: false
            )

            Text(displayName)
                .wnFont(.semiBold16)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 8)

            if let nostrAddress {
                NostrAddressLabel(address: nostrAddress)
                    .padding(.top, 3)
            }

            // The compact tier, not the Profile page's full-width card: here the code is the
            // subject and the npub is the alternative to it, which is the split
            // `wn-ios-prototype` draws with a capsule under the name.
            WNCopyCard(
                displayText: DisplayText.short(npub, head: npubHead, tail: npubTail),
                value: npub,
                actionDescription: L10n.string("Copy npub"),
                style: .pill
            )
            .padding(.top, 8)

            // No stroke, and only a hair of quiet zone. The prototype's card carries no border
            // either: what makes a QR code read as an object is its own matrix, so an outline
            // around it only adds an edge to look at. The surface still has to be named — the
            // code is rasterized into a bitmap with no appearance of its own, so it needs a
            // ground it is guaranteed to contrast with rather than whatever shows through.
            QRCodeImageView(payload: MarmotProfileLink.qrPayload(npub: npub))
                .padding(codePadding)
                .frame(width: codeSize, height: codeSize)
                .background(WNColor.backgroundPrimary, in: .rect(cornerRadius: 16, style: .continuous))
                .padding(.top, 28)

            Text(L10n.string("Scan to connect"))
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 22)
        // Deeper than the top: the caption is the last thing on the sheet and the prototype
        // gives it 32pt of room rather than closing up behind it.
        .padding(.bottom, 32)
        .overlay(alignment: .topTrailing) {
            // Outline rather than glass: the ✕ is the only way out of this sheet, but it is
            // not the thing to look at — the identity is. See `GlassCircleCloseButton.Appearance`.
            GlassCircleCloseButton(appearance: .outline) {
                dismiss()
            }
            .padding(22)
        }
        .frame(width: 420)
        // Flat, not `LiquidGlassBackground()`. The prototype draws this screen on the grouped
        // background, and glass resolves near `fillSecondary` in light — which left the npub
        // capsule sitting on its own colour with nothing to separate them.
        .background(WNColor.backgroundSecondary)
    }
}

/// A NIP-05 Nostr address, drawn under the name it belongs to.
///
/// No verification seal, unlike the iOS prototype's `InlineVerifiedNostrAddressValue`: this app
/// resolves a NIP-05 only to *look someone up* (`NIP05Resolver.accountReference(for:)`), and
/// stores no verified state for anyone, so a seal here would assert something nothing has
/// checked. When verification does land, it belongs in this one view rather than at its call
/// sites.
struct NostrAddressLabel: View {
    let address: String

    var body: some View {
        Text(address)
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .accessibilityLabel(Text(L10n.string("Nostr address")))
            .accessibilityValue(Text(address))
    }
}

/// One appearance's resolved QR colors, flattened to components so the Core Image work can happen
/// off the main actor. Resolved rather than carried as a dynamic `NSColor` deliberately: a QR code
/// is rasterized once into a bitmap that has no appearance of its own, so the two colors have to be
/// pinned at render time and the bitmap re-rendered when the appearance changes.
struct QRCodeInk: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    /// `fallback` is what an unconvertible color becomes. It has to be per-ink: defaulting both
    /// halves of the pair to black would turn a failed conversion into a black code on a black
    /// card, which is unscannable rather than merely wrong-looking.
    init(_ color: NSColor, fallback: NSColor = .black) {
        let resolved = color.usingColorSpace(.sRGB) ?? fallback
        red = resolved.redComponent
        green = resolved.greenComponent
        blue = resolved.blueComponent
    }

    var ciColor: CIColor { CIColor(red: red, green: green, blue: blue) }

    /// The resolved color as AppKit sees it — a static color, since the whole point of this type is
    /// that the appearance has already been chosen.
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// The palette's own QR pair: `qrCode` modules on `backgroundPrimary`. Both invert with the
/// appearance, which is the point — a code pinned to black-on-white sits as a lit card in a dark
/// window. A conforming decoder reads either polarity (asserted in `SemanticPaletteTests`); what it
/// cannot read is a tinted or low-contrast code, which is why neither of these is an accent.
struct QRCodePalette: Equatable, Sendable {
    let modules: QRCodeInk
    let background: QRCodeInk

    @MainActor
    static func resolved(for colorScheme: ColorScheme) -> QRCodePalette {
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        var modules = QRCodeInk(WNNSColor.qrCode)
        var background = QRCodeInk(WNNSColor.backgroundPrimary, fallback: .white)
        // Resolving under the *view's* scheme rather than the drawing appearance already current:
        // the two can disagree while an appearance override is settling, and a code rendered under
        // the wrong one would sit inverted against the sheet until the payload changed.
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            modules = QRCodeInk(WNNSColor.qrCode)
            background = QRCodeInk(WNNSColor.backgroundPrimary, fallback: .white)
        }
        return QRCodePalette(modules: modules, background: background)
    }
}

struct QRCodeImageView: View {
    let payload: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedPayload: String?
    @State private var renderedPalette: QRCodePalette?
    @State private var renderedImage: NSImage?

    private var isRendered: Bool {
        renderedPayload == payload && renderedPalette == QRCodePalette.resolved(for: colorScheme)
    }

    var body: some View {
        Group {
            if isRendered, let renderedImage {
                Image(nsImage: renderedImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else if isRendered {
                ContentUnavailableView("QR code unavailable", systemImage: "qrcode")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
        // Keyed on the appearance as well as the payload: the rasterized code carries no appearance
        // of its own, so switching Aqua and Dark Aqua has to re-render it rather than re-resolve it.
        .task(id: QRCodeRenderKey(payload: payload, palette: QRCodePalette.resolved(for: colorScheme))) {
            let palette = QRCodePalette.resolved(for: colorScheme)
            let image = await Task.detached(priority: .utility) {
                Self.image(for: payload, palette: palette)
            }.value
            guard !Task.isCancelled else { return }
            renderedImage = image?.nsImage
            renderedPayload = payload
            renderedPalette = palette
        }
    }

    nonisolated static func ciImage(for payload: String, palette: QRCodePalette) -> CIImage? {
        guard !payload.isEmpty,
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }

        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        // `CIQRCodeGenerator` hands back opaque black modules on an opaque white quiet zone, so the
        // `backgroundPrimary` behind this view never showed through — recoloring is what actually
        // puts the code on the app's surface instead of on a white card.
        guard let falseColor = CIFilter(name: "CIFalseColor") else { return scaledImage }
        falseColor.setValue(scaledImage, forKey: kCIInputImageKey)
        falseColor.setValue(palette.modules.ciColor, forKey: "inputColor0")
        falseColor.setValue(palette.background.ciColor, forKey: "inputColor1")
        return falseColor.outputImage ?? scaledImage
    }

    nonisolated private static func image(for payload: String, palette: QRCodePalette) -> RenderedQRCodeImage? {
        guard let ciImage = ciImage(for: payload, palette: palette) else { return nil }
        let representation = NSCIImageRep(ciImage: ciImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return RenderedQRCodeImage(nsImage: image)
    }
}

private nonisolated struct RenderedQRCodeImage: @unchecked Sendable {
    let nsImage: NSImage
}

private struct QRCodeRenderKey: Equatable {
    let payload: String
    let palette: QRCodePalette
}

// Shows a user's public key as a truncated `npub` (derived from the hex), with an optional
// one-click copy-to-clipboard icon. Use everywhere a pubkey is surfaced so users always see
// — and can copy — the canonical npub form rather than raw hex.
struct CopyableKeyLabel: View {
    @Environment(WorkspaceState.self) private var workspace
    let accountIdHex: String
    var head: Int = 12
    var tail: Int = 10
    var showsCopyButton: Bool = true

    var body: some View {
        let npub = workspace.npub(forAccountIdHex: accountIdHex)
        HStack(spacing: 6) {
            Text(DisplayText.short(npub, head: head, tail: tail))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if showsCopyButton {
                CopyToClipboardButton(value: npub, actionDescription: L10n.string("Copy npub")) { isConfirming in
                    Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                        .wnFont(.medium10)
                        .foregroundStyle(
                            isConfirming ? WNColor.intentionSuccessContent : WNColor.backgroundContentSecondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
