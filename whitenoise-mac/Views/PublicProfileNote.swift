//
//  PublicProfileNote.swift
//  whitenoise-mac
//
//  The one thing both screens that publish a profile have to say about
//  publishing it.
//

import SwiftUI

/// What goes on the global Nostr network, said once for both screens that put it there.
///
/// Sign-up and Settings → Profile edit the same metadata and warn about it in the same two catalog
/// strings; a reader who sets a name on one and changes it on the other should not have to work
/// out twice that they are the same warning about the same thing. It was two `WNCallout` call
/// sites with the same arguments and two different emphases, which is how the profile page came to
/// draw the tinted box while the pane a user had just come from drew the gray one.
///
/// **The volume is `.quiet`, not the info tint.** The box keeps the glyph and the two-tier title
/// and detail, but takes the neutral surface and the gray the detail line was already drawn in. A
/// tinted box is the loudest thing on a screen whose loudest thing has to be the action that
/// publishes — `Create profile` on one, `Save` on the other. Flutter puts the same pair here as a
/// tap-to-expand `WnCallout`; the detail is short enough to simply show, and a disclosure arrow
/// only teaches the reader to leave it closed.
///
/// Internal rather than `private` so `OnboardingTests` can sample the ground it actually draws on,
/// instead of asserting against a `WNCallout` it built itself — which would go on passing with
/// either screen wearing the info tint.
struct PublicProfileNote: View {
    var body: some View {
        WNCallout(
            title: L10n.string("Your profile is public"),
            message: L10n.string(
                "Name, photo, and bio are visible on the global Nostr network. Use what you're comfortable sharing."
            ),
            intent: .info,
            emphasis: .quiet
        )
        .accessibilityElement(children: .combine)
    }
}
