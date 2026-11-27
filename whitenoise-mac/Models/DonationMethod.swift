//
//  DonationMethod.swift
//  whitenoise-mac
//
//  The two ways to send White Noise money: the public address, the caption that names
//  it, and the short label the Donate page's method switcher shows.
//

import Foundation

/// A way to donate to White Noise.
nonisolated enum DonationMethod: String, CaseIterable, Identifiable, Sendable {
    case lightning
    case bitcoin
    case monero

    var id: String { rawValue }

    static let lightningAddress = "whitenoise@donate.ipf.dev"

    static let bitcoinSilentPaymentAddress =
        "sp1qqvp56mxcj9pz9xudvlch5g4ah5hrc8rj6neu25p34rc9gxhp38cwqqlmld28u57w2srgckr34dkyg3q02phu8tm05cyj483q026xedp0s5f5j40p"

    static let moneroAddress =
        "4B6QrSjaSnCR5SwZbhD14sEbQ7qqTEqA72Tzh3y8qHhdY2E4yVuRYJrD5NdrTsDSmPj1ZQQgEVHUva5pbnbFDt2mGNRUZTg"

    static let cardDonationURL = URL(string: "https://donate.stripe.com/cNi5kw3IY3da1zm2wk0Jq00")!

    /// What goes on the pasteboard, and what the QR code encodes. Never a shortened form.
    var address: String {
        switch self {
        case .lightning:
            Self.lightningAddress
        case .bitcoin:
            Self.bitcoinSilentPaymentAddress
        case .monero:
            Self.moneroAddress
        }
    }

    /// The method switcher's segment title. A protocol name, so it reads the same in every
    /// language — the catalog carries it verbatim for all ten rather than leaving it out,
    /// because `just locales` measures coverage and would count a missing entry as a gap.
    var switcherLabel: String {
        switch self {
        case .lightning:
            L10n.string("Lightning")
        case .bitcoin:
            L10n.string("Bitcoin")
        case .monero:
            L10n.string("Monero")
        }
    }

    /// The caption under the copy control, naming what the address above it is. Reuses the
    /// catalog's existing `Lightning address` rather than adding a second entry that differs
    /// only in capitalization — and that entry is the one whose translations keep "Lightning"
    /// verbatim, which is this app's rule for a protocol name.
    var addressLabel: String {
        switch self {
        case .lightning:
            L10n.string("Lightning address")
        case .bitcoin:
            L10n.string("Bitcoin Silent Payment")
        case .monero:
            L10n.string("Monero address")
        }
    }

    /// The address as drawn, which is not always the address as copied.
    ///
    /// A Lightning address is a human-readable handle at 25 characters — showing it whole is
    /// the point of it, and it fits the settings column with room to spare. Silent payment and
    /// Monero addresses are long strings nobody reads end to end, so they take the head-and-tail
    /// form the identity sheet gives an npub. Deciding this here rather than leaving them to
    /// `truncationMode(.middle)` keeps the capsule a predictable width and stops the readable one
    /// from being clipped by a column that got narrower.
    var displayAddress: String {
        switch self {
        case .lightning:
            Self.lightningAddress
        case .bitcoin:
            DisplayText.short(Self.bitcoinSilentPaymentAddress, head: 14, tail: 6)
        case .monero:
            DisplayText.short(Self.moneroAddress, head: 14, tail: 6)
        }
    }

    /// Localized description of the copy action, for the button's help tag and VoiceOver.
    var copyActionDescription: String {
        String(format: L10n.string("Copy %@"), addressLabel)
    }

    /// Localized description of the QR code, which is otherwise a bitmap with nothing to
    /// announce.
    var qrCodeAccessibilityLabel: String {
        String(format: L10n.string("%@ QR code"), addressLabel)
    }
}
