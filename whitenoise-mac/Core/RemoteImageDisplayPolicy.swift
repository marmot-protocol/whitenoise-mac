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
/// this Mac — the profile editor, its picker, Identity & Keys, and the account switcher. Peer
/// avatars (chat rows, message senders, member lists, search results) must keep the default.
///
/// "Signed in" is load-bearing rather than decorative. The first three of those sites render
/// `activeAccount`, which `restoreOrSelectFirstAccount()` guarantees is never a signed-out account,
/// so they can pass a literal `true`. The switcher's row list is the one site that also shows
/// signed-out identities, and it passes `!account.signedOut`: sign-out deactivates an identity and
/// drops its relay key packages, so the app should not then fetch its avatar and put traffic on the
/// wire on its behalf. That is a narrower argument than the preference's own — a signed-out account
/// is still yours, not a peer's — but the exemption should stay as small as the bug it exists to
/// fix.
nonisolated enum RemoteImageDisplayPolicy {
    static func loadsRemoteImage(isOwnAccountImage: Bool, preferenceEnabled: Bool) -> Bool {
        isOwnAccountImage || preferenceEnabled
    }
}
