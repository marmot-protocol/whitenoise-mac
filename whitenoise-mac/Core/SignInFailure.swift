//
//  SignInFailure.swift
//  whitenoise-mac
//
//  What the sign-in pane says when the core refuses a sign-in.
//

import Foundation

/// The sign-in pane's message for a failed `login()`.
///
/// `MarmotKitError.errorDescription` is `String(reflecting:)`, so a raw core error reaching
/// `lastError` printed `MarmotKit.MarmotKitError.Runtime(details: "invalid nsec or secret key")`
/// under the key field — in English, whatever the app's language. The core's errors are for
/// diagnostics, never copy, so every one of them reads as the same "Couldn't sign in".
///
/// One message rather than a mapping on purpose. Telling failures apart meant matching the core's
/// free-text details, and those overlap: "secret key" also appears in a *storage* fault ("stored
/// account id does not match stored secret key"), which a mapping read as a bad key — telling
/// someone with the right key to check it, when re-pasting it can never help. A key the field can
/// already tell is wrong is refused before it gets here, with its own message.
nonisolated enum SignInFailure {
    static var message: String {
        L10n.string("Couldn't sign in")
    }
}
