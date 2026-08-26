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

/// How loudly a callout says it.
///
/// `tinted` is the default, and what Settings draws: the intent's hue, on the intent's tinted
/// background. `quiet` keeps everything else the callout is — the glyph, the two-tier title and
/// detail, the box — and drops the hue for the neutral surface and the supporting gray.
///
/// It exists for a surface that cannot spend color on a standing notice. The sign-up pane is one:
/// it is a form with a single primary button on it, and a tinted box above the fields would be
/// the loudest thing on a pane whose loudest thing has to be the button. See
/// `OnboardingPublicProfileNote`, which says exactly what Settings → Profile says, in the gray it
/// already said it in.
enum WNCalloutEmphasis {
    case tinted
    case quiet

    func background(for intent: WNCalloutIntent) -> Color {
        switch self {
        case .tinted: intent.background
        case .quiet: WNColor.backgroundSecondary
        }
    }

    /// The glyph and the title.
    func accent(for intent: WNCalloutIntent) -> Color {
        switch self {
        case .tinted: intent.accent
        case .quiet: WNColor.backgroundContentSecondary
        }
    }

    /// The detail text, a step quieter than the title in both emphases.
    func detail(for intent: WNCalloutIntent) -> Color {
        switch self {
        case .tinted: intent.detail
        case .quiet: WNColor.backgroundContentTertiary
        }
    }
}

/// A titled notice with a line of detail under it.
///
/// The detail is always shown. There is no fold: a notice worth putting on the page is worth
/// reading, and a disclosure arrow only teaches the reader to leave it closed.
struct WNCallout: View {
    let title: String
    let message: String
    var intent: WNCalloutIntent = .primary
    /// Whether the intent brings its hue with it. See `WNCalloutEmphasis`.
    var emphasis: WNCalloutEmphasis = .tinted

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: intent.systemImage)
                .wnFont(.medium18)
                .foregroundStyle(emphasis.accent(for: intent))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .wnFont(.bold14)
                    .foregroundStyle(emphasis.accent(for: intent))

                Text(message)
                    .wnFont(.medium12)
                    .foregroundStyle(emphasis.detail(for: intent))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(emphasis.background(for: intent), in: .rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(WNColor.borderTertiary, lineWidth: 1)
        }
    }
}
