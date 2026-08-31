//
//  NostrAddressVerification.swift
//  whitenoise-mac
//
//  Whether a profile's Verified Nostr Address actually points back at the
//  account showing it.
//

import Foundation

/// What is known about a NIP-05 address's claim.
///
/// The product name for the value is **Verified Nostr Address** — `NIP-05` appears in the
/// new-chat field, where it names an input format, and nowhere on a profile. That is
/// `wn-ios-prototype`'s rule (`docs/screens/verified-nostr-address.md`) and it is kept here.
///
/// **The seal is earned, not asserted.** The prototype's verification is a fixture — its
/// addresses are deterministic and it says outright that it invents no network check. This app
/// has `NIP05Resolver`, so the seal means the thing it looks like it means: the domain's
/// `/.well-known/nostr.json` maps that name to *this* account's public key. An address that is
/// merely typed in and published is `.unverified`, and draws no seal.
enum NostrAddressVerification: Equatable, Sendable {
    /// Nothing to verify: the profile carries no address, or what it carries is not address-shaped.
    case none
    /// The well-known document is being fetched.
    case checking
    /// The domain names this account for this address.
    case verified
    /// The domain names somebody else, names nobody, or could not be reached. One case rather
    /// than three, because the honest thing to draw for all three is the same: no seal.
    case unverified
}
