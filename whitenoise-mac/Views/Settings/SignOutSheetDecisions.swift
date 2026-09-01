//
//  SignOutSheetDecisions.swift
//  whitenoise-mac
//

import Foundation

/// The rules the sign-out sheet runs on, held apart from the sheet so they can be driven.
///
/// The sheet is the whole confirmation task — a second alert stacked on top of it would ask the
/// same question twice and give the reader two places to look for what is about to happen — so
/// every one of these decisions is the *only* thing standing between a click and an account being
/// erased.
nonisolated enum SignOutSheetDecisions {
    /// Wiping is opt-in, unlike the prototype, which arms it on open.
    ///
    /// The prototype has no data to lose. Here the promise this app has always made for Sign Out is
    /// that "the account and its local data will stay on this Mac", and defaulting the toggle on
    /// would quietly invert it for everyone who signs out without reading.
    static let wipesLocalDataByDefault = false

    /// Which teardown a press runs. One button, one label, armed or not.
    static func teardown(wipesLocalData: Bool) -> SignOutTeardown {
        wipesLocalData ? .removeAccount : .signOut
    }

    /// Whether the button is live: nothing already running, and — when wiping is armed — the
    /// type-to-confirm gate cleared.
    static func canSignOut(isTearingDown: Bool, wipesLocalData: Bool, isConfirmed: Bool) -> Bool {
        !isTearingDown && (!wipesLocalData || isConfirmed)
    }

    /// Whether the sheet closes once the teardown returns.
    ///
    /// Only a clean run closes it. Both calls clear `lastError` on entry and set it from their
    /// `catch`, so an error here means nothing was torn down — dismissing would take the only place
    /// that error is shown away with it and leave the reader unsure whether they are still signed
    /// in.
    static func dismissesAfterTeardown(lastError: String?) -> Bool {
        lastError == nil
    }
}

/// The two exits the sheet owns. Both live here rather than in two surfaces: signing out and
/// erasing are one decision made with one toggle.
nonisolated enum SignOutTeardown: Hashable, Sendable {
    case signOut
    case removeAccount

    var progressLabelKey: String {
        switch self {
        case .signOut: "Signing out…"
        case .removeAccount: "Signing out and wiping data…"
        }
    }
}
