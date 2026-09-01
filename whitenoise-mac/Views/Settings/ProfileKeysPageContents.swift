//
//  ProfileKeysPageContents.swift
//  whitenoise-mac
//

import Foundation

/// A group on the Profile Keys page.
nonisolated enum ProfileKeysGroup: Hashable, Sendable {
    case publicKey
    case privateKey
    /// Only for an account this Mac holds the key for; an externally-signed one has nothing to
    /// export.
    case export

    var titleKey: String {
        switch self {
        case .publicKey: "Public Key"
        case .privateKey: "Private Key"
        case .export: "Export"
        }
    }
}

/// What the Profile Keys page is made of.
///
/// Three groups and no fourth. The page used to open with a subtitle and an Account group — an
/// avatar and a line reporting the signing mode — restating an identity the reader had just come
/// through the drawer's profile card to reach, and it used to end with Account Removal, which now
/// lives whole inside the sign-out sheet where the confirmation is.
nonisolated enum ProfileKeysPageContents {
    static func groups(localSigning: Bool) -> [ProfileKeysGroup] {
        localSigning ? [.publicKey, .privateKey, .export] : [.publicKey, .privateKey]
    }

    /// The privacy contract this page inherited from the backup sheet it replaced.
    ///
    /// On macOS the eye, the copy button and the raw export all go through the core's `revealNsec`,
    /// which writes an audit line and downgrades that account's audit data mode — so the page has to
    /// say so. A comment cannot make that promise; the shipped string is the promise.
    static var auditLogDisclosure: String {
        L10n.string(
            "White Noise notes the date and time of each reveal, copy or export in this account's audit log, kept on this Mac. Your private key is never written to the log."
        )
    }
}
