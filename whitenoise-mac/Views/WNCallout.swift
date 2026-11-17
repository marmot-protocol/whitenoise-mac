//
//  WNCallout.swift
//  whitenoise-mac
//
//  The banner that explains a surface without interrupting it: a glyph, a
//  title, and a line of detail in a rounded, tinted box. The macOS twin of
//  `WnCallout` on the other clients, including its set of intents.
//

import SwiftUI

/// What a `WNCallout` is saying, which is what picks its colors and its default glyph.
///
/// Mirrors `CalloutType` on the other clients. `primary` is their `neutral`: the callout
/// takes the surface's own content color rather than a hue, which is what an explanatory
/// notice wants — it belongs to the page it sits on rather than interrupting it.
enum WNCalloutIntent {
    case primary
    case info
    case success
    case warning
    case error

    var background: Color {
        switch self {
        case .primary: WNColor.backgroundSecondary
        case .info: WNColor.intentionInfoBackground
        case .success: WNColor.intentionSuccessBackground
        case .warning: WNColor.intentionWarningBackground
        case .error: WNColor.intentionErrorBackground
        }
    }

    /// The glyph and the title. Paired with `background` by construction — never mix one
    /// intent's background with another's accent.
    var accent: Color {
        switch self {
        case .primary: WNColor.backgroundContentPrimary
        case .info: WNColor.intentionInfoContent
        case .success: WNColor.intentionSuccessContent
        case .warning: WNColor.intentionWarningContent
        case .error: WNColor.intentionErrorContent
        }
    }

    /// The detail text. The tinted intents need a color that holds up over a hue, which is what
    /// `backgroundContentQuaternary` is for — it is an alpha of the opposite extreme rather than
    /// a ramp step. `primary` sits on a neutral surface, so it takes the ordinary supporting color.
    var detail: Color {
        switch self {
        case .primary: WNColor.backgroundContentSecondary
        case .info, .success, .warning, .error: WNColor.backgroundContentQuaternary
        }
    }

    /// The glyph follows the intent rather than the call site: a reader learns the hue and the
    /// shape together, so a triangle in the neutral palette (or a question mark in amber) would
    /// be two signals disagreeing.
    var systemImage: String {
        switch self {
        case .primary: "questionmark.circle.fill"
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }
}

/// A titled notice, with a line of detail under it when there is one.
///
/// The detail is always shown. There is no fold: a notice worth putting on the page is worth
/// reading, and a disclosure arrow only teaches the reader to leave it closed. Nothing on it is
/// interactive — the glyph is the intent's, never a close button — so a caller that offers an
/// action puts the button beside or under the callout, not inside it.
struct WNCallout: View {
    let title: String
    var message: String? = nil
    var intent: WNCalloutIntent = .primary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: intent.systemImage)
                .wnFont(.medium18)
                .foregroundStyle(intent.accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .wnFont(.bold14)
                    .foregroundStyle(intent.accent)
                    .fixedSize(horizontal: false, vertical: true)

                if let message {
                    Text(message)
                        .wnFont(.medium12)
                        .foregroundStyle(intent.detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(intent.background, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(WNColor.borderTertiary, lineWidth: 1)
        }
    }
}

#Preview("Callout intents") {
    VStack(spacing: 12) {
        WNCallout(title: "Primary", message: "An explanatory notice that belongs to its page.")
        WNCallout(title: "Info", message: "Something worth knowing.", intent: .info)
        WNCallout(title: "A title with no detail line", intent: .info)
        WNCallout(title: "Success", message: "It worked.", intent: .success)
        WNCallout(title: "Warning", message: "Something needs attention.", intent: .warning)
        WNCallout(title: "Error", message: "Something went wrong.", intent: .error)
    }
    .padding()
    .frame(width: 480)
}
