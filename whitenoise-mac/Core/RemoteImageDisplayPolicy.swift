//
//  RemoteImageDisplayPolicy.swift
//  whitenoise-mac
//
//  Whether an avatar that lives at a remote URL may be fetched and drawn at all.
//  The URL-safety half of this decision is `RemoteImageURLPolicy`; this is the
//  consent half.
//

import Foundation

/// Decides whether a *sanitized* remote avatar URL may actually be loaded, given the viewer's
/// "Load Remote Profile Images" preference.
///
/// `WorkspaceState.loadRemoteImages` is off by default, and Privacy & Security states exactly why:
/// "Profile pictures come from URLs **other people** control, so loading them reveals your IP
/// address and when you're online to whoever sent them." That reasoning covers every avatar the
/// viewer did not choose — and none of the one they did.
///
/// The account's own picture is the case the preference was never written for. The viewer picked it
/// in the profile editor, the app uploaded it to the Blossom server *the app* chose, and the URL is
/// what that upload returned. Fetching it discloses the viewer's address to a host they have just
/// handed the image to, so drawing it leaks nothing the upload did not already leak.
///
/// Gating it made the profile editor look broken rather than private: the upload succeeded, the
/// draft took the new URL, `saveProfile()` published it — and the 96pt avatar at the top of the form
/// kept drawing initials, with no error to explain why. From the outside that is indistinguishable
/// from "I can't set a profile image."
///
/// So: your own avatar always draws, everyone else's waits for the preference. Pass
/// `isOwnAccountImage: true` only where the URL provably belongs to an account **signed in** on
/// this Mac — the profile editor, its picker, Identity & Keys, Settings' profile card, the account
/// rail, and the public-identity QR sheet those last two open. Peer avatars (chat rows, message
/// senders, member lists, search results) must keep the default.
///
/// "Signed in" is load-bearing rather than decorative, and each of those sites earns its literal
/// `true` differently. The first four render `activeAccount`, which `restoreOrSelectFirstAccount()`
/// guarantees is never a signed-out account, and so does the QR sheet: every call site that opens
/// it reads `activeAccount`. The rail renders several accounts at once, but it is fed
/// `signedInAccounts`, so a deactivated identity never reaches an avatar there to begin with.
///
/// No site passes a computed value any more. Two used to pass `!account.signedOut`, for the
/// deactivated rows they drew: sign-out drops an identity's relay key packages, so the app should
/// not then fetch its avatar and put traffic on the wire on its behalf. Filtering the rail's list
/// subsumed that argument, and deleting the Settings switcher popover removed the other site
/// outright. No surface draws a deactivated identity's avatar at all now — the pane that used to
/// list them when nothing was signed in is gone too, so getting back into one is Sign In with its
/// key and the avatar is fetched only once it is signed in again.
nonisolated enum RemoteImageDisplayPolicy {
    static func loadsRemoteImage(isOwnAccountImage: Bool, preferenceEnabled: Bool) -> Bool {
        isOwnAccountImage || preferenceEnabled
    }
}
