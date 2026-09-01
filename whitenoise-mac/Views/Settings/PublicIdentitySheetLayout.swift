//
//  PublicIdentitySheetLayout.swift
//  whitenoise-mac
//

import Foundation

/// One of the things the public-identity sheet stacks, top to bottom.
nonisolated enum PublicIdentitySheetElement: Hashable, Sendable {
    case avatar
    case displayName
    /// Only when the account has one, and only when the profile in hand is that account's.
    case nostrAddress
    case npubCard
    case qrCode
    case caption
}

/// The order the public-identity sheet stacks its parts in, and the two numbers that shape the
/// code's card.
///
/// The order is the request: the identity — avatar, name, Nostr address, npub — above the code, and
/// the caption saying what the code is for below it. That is `share_profile_screen.dart`'s order in
/// the sibling clients, and it is the half of this sheet no rendered assertion can see, so it is
/// written down once here instead of being implicit in a stack.
nonisolated enum PublicIdentitySheetLayout {
    static func elements(hasNostrAddress: Bool) -> [PublicIdentitySheetElement] {
        var elements: [PublicIdentitySheetElement] = [.avatar, .displayName]
        if hasNostrAddress {
            elements.append(.nostrAddress)
        }
        elements.append(contentsOf: [.npubCard, .qrCode, .caption])
        return elements
    }

    /// `wn-ios-prototype`'s `ShareableQRCodeView` names a 16pt continuous container and no stroke at
    /// all: a QR code is already an object made of high-contrast marks, so an outline around it only
    /// adds an edge competing with the matrix.
    static let codeCardCornerRadius: CGFloat = 16
}
