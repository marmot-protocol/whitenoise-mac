//
//  ProfilePrivacyNote.swift
//  whitenoise-mac
//
//  What publishing a profile means, said where the button that publishes it is.
//

import SwiftUI

/// `whitenoise-ios`'s `WNProfilePrivacyNote`: an eye, two short lines, and a `Learn more` link, in a
/// gray card at the top of the form, where the old public-profile notice stood.
///
/// All three screens that edit a profile draw it in the same place — Sign Up, the account-setup
/// profile step and Settings → Profile — directly above the Name field. On iOS `Learn more` opens
/// `WNProfilePrivacyDetailsView` as a sheet; a sheet over a pane this small would cover the form it
/// is explaining, so here the card opens in place and shows the details' two paragraphs under the
/// summary. The strings are iOS's, translations included.
///
/// `Learn more` opens it; once open, the link gives way to a chevron in the top-right corner that
/// closes it again. Each card state has exactly one control. See `ProfilePrivacyDisclosure`.
///
/// Opening the card makes the form taller, so every screen that draws it has to scroll once it
/// outgrows its window — Sign Up through `OnboardingShortWindowScroll`, the setup step through
/// `AccountSetupStepLayout`, Settings through `SettingsStackScaffold`. The card is at the top, so
/// the scroll position staying put keeps it in view while it opens.
struct ProfilePrivacyNote: View {
    @Environment(\.locale) private var locale
    @State private var disclosure: ProfilePrivacyDisclosure

    init(isExpanded: Bool = false) {
        _disclosure = State(initialValue: ProfilePrivacyDisclosure(isExpanded: isExpanded))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "eye")
                .wnFont(.medium14)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(Self.summaryKey, locale: locale))
                    .fixedSize(horizontal: false, vertical: true)

                if disclosure.isExpanded {
                    ForEach(Array(Self.detailKeys.enumerated()), id: \.element) { index, key in
                        Text(L10n.string(key, locale: locale))
                            // iOS's details view draws the first paragraph primary and the
                            // second secondary.
                            .foregroundStyle(
                                index == 0 ? WNColor.backgroundContentPrimary : WNColor.backgroundContentSecondary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                }

                if disclosure.showsLearnMore {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { disclosure.expand() }
                    } label: {
                        Text(L10n.string("Learn more", locale: locale))
                            .underline()
                            .foregroundStyle(WNColor.backgroundContentPrimary)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .accessibilityIdentifier("profile.privacy-learn-more")
                }
            }
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            if disclosure.showsChevron {
                ProfilePrivacyChevron {
                    withAnimation(.easeOut(duration: 0.2)) { disclosure.collapse() }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(WNColor.backgroundSecondary, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(WNColor.borderTertiary, lineWidth: 1)
        }
    }

    /// iOS's catalog keys, shared literals so tests measure the strings the card draws.
    static let summaryKey = "Your name, photo, and bio are public.\nShare only what you’re comfortable with."
    static let detailKeys = [
        "Anyone can see your name, photo, and bio, including people using other apps on the same network. You can use a nickname instead of your real name.",
        "Share only what you’re comfortable making public. Photos may stay online even after you remove them from your profile.",
    ]
}

/// The open card's way back: an up chevron, labelled and tooltipped with what pressing it does.
struct ProfilePrivacyChevron: View {
    @Environment(\.locale) private var locale
    let action: () -> Void

    var body: some View {
        let label = L10n.string(ProfilePrivacyDisclosure.collapseLabelKey, locale: locale)
        Button(action: action) {
            Image(systemName: ProfilePrivacyDisclosure.chevronSymbol)
                .wnFont(.semiBold12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(width: 12)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("profile.privacy-disclosure")
    }
}

#Preview("Collapsed") {
    ProfilePrivacyNote()
        .frame(width: OnboardingLayout.contentWidth)
        .padding()
}

#Preview("Expanded") {
    ProfilePrivacyNote(isExpanded: true)
        .frame(width: OnboardingLayout.contentWidth)
        .padding()
}
