//
//  WNCopyCard.swift
//  whitenoise-mac
//
//  The way a public identifier is put on screen when it is the point of the
//  screen rather than a caption: a ground, big enough to read, that copies when
//  clicked anywhere. The macOS twin of `WnCopyCard` on the other clients.
//

import SwiftUI

/// How much room the value is given, and how loudly it asks to be read.
///
/// One atom rather than two components, because both tiers are the same idea — a value you are
/// meant to hand to someone else, on a ground, that copies when clicked — and splitting them
/// would let their type, ground and confirmation drift apart.
enum WNCopyCardStyle {
    /// A filled card at reading size, wrapping the value over as many lines as it needs. For a
    /// page whose subject *is* the value: the Profile form's npub.
    case card
    /// A compact capsule showing a middle-truncated value on one line. For a surface where the
    /// value is one element among several and something else is the subject — the identity
    /// sheet, where the QR code is what the eye should land on. This is the shape
    /// `wn-ios-prototype` gives the npub under a profile.
    case pill
}

/// A ground showing a long value, which copies that value when clicked.
///
/// The ground is the button — a value the user is meant to hand to someone else should not make
/// them aim at a 10pt glyph. The glyph is still drawn, as the affordance, and flips to a
/// checkmark for the confirmation window because macOS raises none of its own.
struct WNCopyCard: View {
    /// What is drawn. Usually a grouped or shortened form of `value`; never what is copied.
    let displayText: String
    /// The full value written to the pasteboard.
    let value: String
    /// Localized description of the action, e.g. "Copy npub".
    let actionDescription: String
    var style: WNCopyCardStyle = .card
    var lineLimit: Int = 2

    @State private var isHovering = false

    var body: some View {
        CopyToClipboardButton(value: value, actionDescription: actionDescription) { isConfirming in
            switch style {
            case .card:
                card(isConfirming: isConfirming)
            case .pill:
                pill(isConfirming: isConfirming)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private func card(isConfirming: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(displayText)
                .wnFont(.medium14)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            glyph(isConfirming: isConfirming)
                .wnFont(.medium18)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHovering ? WNColor.fillSecondaryHover : WNColor.fillSecondary,
            in: .rect(cornerRadius: 8, style: .continuous)
        )
        .contentShape(.rect(cornerRadius: 8, style: .continuous))
    }

    /// The compact tier. Hugs its value rather than filling the width it is offered — a capsule
    /// stretched across a sheet reads as a field, which is the opposite of what this tier is for.
    private func pill(isConfirming: Bool) -> some View {
        HStack(spacing: 8) {
            Text(displayText)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            glyph(isConfirming: isConfirming)
                .wnFont(.medium12)
                // Fixed so the checkmark and `doc.on.doc` occupy the same room and the capsule
                // does not resize under the pointer at the moment it is clicked.
                .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isHovering ? WNColor.fillSecondaryHover : WNColor.fillSecondary, in: .capsule)
        .contentShape(.capsule)
    }

    private func glyph(isConfirming: Bool) -> some View {
        Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
            .foregroundStyle(
                isConfirming ? WNColor.intentionSuccessContent : WNColor.backgroundContentSecondary)
    }
}
