//
//  PublicIdentityViews.swift
//  whitenoise-mac
//
//  The two ways an account's public identity is shown: as a scannable QR code, and as
//  a truncated, copyable `npub`. Shared by the Profile and Identity & Keys pages and
//  by the account switcher, so neither owns them.
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
    @Environment(WorkspaceState.self) private var workspace
    @State private var isPresented = false
    @State private var isHovering = false
    let accountIdHex: String
    let displayName: String
    var style: PublicIdentityQRCodeButtonStyle = .inline

    private var npub: String {
        workspace.npub(forAccountIdHex: accountIdHex)
    }

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
            PublicIdentityQRCodeSheet(displayName: displayName, npub: npub)
        }
    }
}

struct PublicIdentityQRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let displayName: String
    let npub: String

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .wnFont(.semiBold16)
                        .lineLimit(1)
                    Text(L10n.string("Public identity"))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }

                Spacer()

                // Outline rather than glass: the ✕ is the only way out of this sheet, but it is
                // not the thing to look at — the code is. See `GlassCircleCloseButton.Appearance`.
                GlassCircleCloseButton(appearance: .outline) {
                    dismiss()
                }
            }

            ZStack {
                // The same surface the code's own quiet zone is rendered in, so the padding around
                // it is continuous with it rather than a border. See `QRCodePalette`.
                WNColor.backgroundPrimary
                // Encode the marmot:// profile link form so scanners can route the
                // scheme; the visible text and Copy button keep the bare npub.
                QRCodeImageView(payload: MarmotProfileLink.qrPayload(npub: npub))
                    .padding(22)
            }
            .frame(width: 320, height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(WNColor.borderTertiary, lineWidth: 1)
            }

            // Head and tail are cut to what fits beside the copy glyph on one line at this
            // sheet's width; the button still copies the whole npub. Same shape as
            // `CopyableKeyLabel`, which cannot be reused here because the sheet is handed a
            // resolved npub rather than an account id.
            HStack(spacing: 8) {
                Text(DisplayText.short(npub, head: 20, tail: 16))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                CopyToClipboardButton(value: npub, actionDescription: L10n.string("Copy npub")) { isConfirming in
                    Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(
                            isConfirming ? WNColor.intentionSuccessContent : WNColor.backgroundContentSecondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background {
            LiquidGlassBackground()
        }
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

    init(_ color: NSColor) {
        let resolved = color.usingColorSpace(.sRGB) ?? .black
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
        var background = QRCodeInk(WNNSColor.backgroundPrimary)
        // Resolving under the *view's* scheme rather than the drawing appearance already current:
        // the two can disagree while an appearance override is settling, and a code rendered under
        // the wrong one would sit inverted against the sheet until the payload changed.
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            modules = QRCodeInk(WNNSColor.qrCode)
            background = QRCodeInk(WNNSColor.backgroundPrimary)
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
