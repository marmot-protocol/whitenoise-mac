//
//  OnboardingMetrics.swift
//  whitenoise-mac
//
//  The numbers the onboarding screens share, in one place so a screen added
//  later lines up with the ones already there instead of re-inventing them.
//

import CoreGraphics

/// Shared geometry for the signed-out pane: the welcome screen, sign-in, sign-up, the splash,
/// and the account picker.
///
/// These are the mac translation of the iOS prototype's onboarding layout, and the translation
/// is the whole point of collecting them. The phone screens are built from
/// `safeAreaPadding(.horizontal)` and `containerRelativeFrame` — "as wide as the device" and
/// "half the device" — which on a 940pt-minimum window would produce a 470pt logo over
/// buttons the width of a desk. What carries over is the *proportion*: a mark with room around
/// it, one readable column, and the primary action pinned to the bottom of that column.
///
/// Not `nonisolated`: these are read from view bodies that already run on the main actor, and
/// nothing off-main has a use for them.
enum OnboardingMetrics {
    /// The welcome screen's action column. Narrow enough that two stacked capsules read as a
    /// pair of buttons rather than as two bands across the window.
    static let actionColumnWidth: CGFloat = 320

    /// Forms (sign-in, sign-up). Wider than the action column because it has to hold a
    /// `nsec1…` string and a multi-line bio without wrapping every few words.
    static let formColumnWidth: CGFloat = 420

    /// The brand mark on the welcome screen — the subject of the screen.
    static let welcomeMarkSize: CGFloat = 132

    /// The brand mark on the splash and on secondary signed-out screens, where it is an
    /// identifier rather than the subject.
    static let compactMarkSize: CGFloat = 88

    /// Between the elements of a single group (a field and its footnote, a title and its
    /// subtitle).
    static let stackSpacing: CGFloat = 8

    /// Between groups within a screen's content column.
    static let sectionSpacing: CGFloat = 20

    /// Around the content column, and between the bottom action and the window edge.
    static let screenPadding: CGFloat = 28
}
