//
//  DonateSettingsView.swift
//  whitenoise-mac
//
//  The Donate page: why to give, a switcher between the two ways to, and the selected
//  one's address as both a QR code and something you can click to copy.
//

import SwiftUI

/// Ported from `wn-ios-prototype`'s Donate destination, whose spec is a centred `heart`
/// introduction, a palette `Picker` over **Lightning** and **Bitcoin**, and one method on
/// screen at a time "so the selected QR receives the full visual focus".
///
/// Three things are deliberately not ports. The prototype puts the picker in the navigation
/// bar's `principal` slot; a settings page here has `SettingsHeader` instead of a navigation
/// bar, so the switcher moves into the content, centred directly above the code it switches.
/// Its `.palette` style is iOS-only, so it becomes the `.segmented` style this app
/// already uses for `GroupSharedMediaSection`. And the copy is the Flutter client's, not the
/// prototype's: "As a 501(c)3 non-profit…" is the shipped product line and is already written
/// in all ten of this catalog's languages, where the prototype's "free and open source"
/// sentence exists only in English.
///
/// No wallet, payment or network integration — the same boundary the prototype's spec draws.
struct DonateSettingsView: View {
    @State private var selectedMethod = DonationMethod.lightning

    var body: some View {
        SettingsStackScaffold(title: L10n.string("Donate")) {
            DonateIntroduction()

            // Centred over the code it switches, which is where the prototype's principal
            // toolbar slot put it. `SettingsStackScaffold` aligns its column leading, so the
            // switcher has to ask for the centre; `fixedSize` is what keeps it at its natural
            // two-segment width instead of stretching across the column between the spacers.
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                Picker(L10n.string("Donation method"), selection: $selectedMethod) {
                    ForEach(DonationMethod.allCases) { method in
                        Text(method.switcherLabel).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 0)
            }

            DonationMethodDetail(method: selectedMethod)
        }
    }
}

/// The reason to give, before the means of giving.
///
/// Centred and transparent, with the outline `heart`: regular informational content rather
/// than an unavailable state, so it is not a `WNEmptyStateView` and carries no card of its
/// own. The heading is Flutter's `donateTitle` rather than the prototype's English-only
/// "Support White Noise" — same job in the layout, and it arrives translated.
private struct DonateIntroduction: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart")
                .wnFont(.medium24)
                .foregroundStyle(WNColor.backgroundContentPrimary)

            Text(L10n.string("Donate to White Noise"))
                .wnFont(.semiBold16)
                .foregroundStyle(WNColor.backgroundContentPrimary)

            Text(
                L10n.string(
                    "As a 501(c)3 non-profit, White Noise exists solely for your privacy and freedom, not for profit. Your support keeps us independent and uncompromised."
                )
            )
            .wnFont(.medium14)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One donation method, drawn the way the prototype stacks it: the code, then the copy
/// control, then the caption naming what was copied.
///
/// The QR takes the identity sheet's recipe — `QRCodeImageView` on an explicit
/// `backgroundPrimary` card with a hair of quiet zone and no stroke. The explicit ground is
/// not decoration: the code is rasterized into a bitmap with no appearance of its own, so it
/// needs a surface it is guaranteed to contrast with rather than whatever shows through.
///
/// The gap above the copy control is wider than the identity sheet's, which is the prototype's
/// instruction — "the QR-to-copy spacing remains deliberately larger than the compact grouping
/// used on Share & Connect" — because here the copy control is the second way to do the same
/// thing rather than a caption on the first.
private struct DonationMethodDetail: View {
    let method: DonationMethod

    private let codeSize: CGFloat = 256
    private let codePadding: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            QRCodeImageView(payload: method.address)
                .padding(codePadding)
                .frame(width: codeSize, height: codeSize)
                .background(WNColor.backgroundPrimary, in: .rect(cornerRadius: 16, style: .continuous))
                .accessibilityElement()
                .accessibilityLabel(Text(method.qrCodeAccessibilityLabel))

            WNCopyCard(
                displayText: method.displayAddress,
                value: method.address,
                actionDescription: method.copyActionDescription,
                style: .pill
            )
            .padding(.top, 18)

            Text(method.addressLabel)
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}
