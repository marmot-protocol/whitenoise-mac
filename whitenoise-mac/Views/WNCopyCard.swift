//
//  WNCopyCard.swift
//  whitenoise-mac
//
//  The way a public identifier is put on screen when it is the point of the
//  screen rather than a caption: a filled card, big enough to read, that copies
//  when clicked anywhere. The macOS twin of `WnCopyCard` on the other clients.
//

import SwiftUI

/// A filled card showing a long value at reading size, which copies the value when clicked.
///
/// The card is the button — a value the user is meant to hand to someone else should not make
/// them aim at a 10pt glyph. The glyph is still drawn, as the affordance, and flips to a
/// checkmark for the confirmation window because macOS raises none of its own.
struct WNCopyCard: View {
    /// What is drawn. Usually a grouped or shortened form of `value`; never what is copied.
    let displayText: String
    /// The full value written to the pasteboard.
    let value: String
    /// Localized description of the action, e.g. "Copy npub".
    let actionDescription: String
    var lineLimit: Int = 2

    @State private var isHovering = false

    var body: some View {
        CopyToClipboardButton(value: value, actionDescription: actionDescription) { isConfirming in
            HStack(alignment: .center, spacing: 14) {
                Text(displayText)
                    .wnFont(.medium14)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(lineLimit)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                    .wnFont(.medium18)
                    .foregroundStyle(
                        isConfirming ? WNColor.intentionSuccessContent : WNColor.backgroundContentSecondary)
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
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
