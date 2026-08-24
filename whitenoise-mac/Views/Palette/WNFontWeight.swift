//
//  WNFontWeight.swift
//  whitenoise-mac
//
//  The weights the type ramp is set in. The app typesets in the system face — the
//  same choice `wn-ios-prototype` makes, where no face is registered and every run
//  is `systemFont` — so a weight here is a point on San Francisco's weight axis
//  rather than a separate file in the bundle.
//
//  The vocabulary stays three deep because the ramp is the Flutter client's ladder
//  and that ladder names three. The mac client typesets its medium rung one step
//  lighter than the Flutter source, though: where Flutter draws body copy at Medium
//  (500), San Francisco reads heavy at that point on a desktop display, so this
//  app's `.medium` resolves to Regular (400). Each case carries both frameworks'
//  spelling of the same weight, so `WNTextStyle` and `WNNSFont` cannot drift apart
//  on what "semiBold" means.
//

import AppKit
import SwiftUI

nonisolated enum WNFontWeight: String, CaseIterable, Sendable {
    /// Body copy and every non-emphasised run. Named for the Flutter rung it
    /// descends from (Medium), resolved one step lighter — Regular (400).
    case medium
    /// SemiBold (600) — titles, row headings, and emphasised labels.
    case semiBold
    /// Bold (700) — badges, counters, and the loudest emphasis only.
    case bold

    /// The SwiftUI spelling of the weight.
    var swiftUI: Font.Weight {
        switch self {
        case .medium: .regular
        case .semiBold: .semibold
        case .bold: .bold
        }
    }

    /// The AppKit spelling of the same weight, for the TextKit-backed composer.
    var appKit: NSFont.Weight {
        switch self {
        case .medium: .regular
        case .semiBold: .semibold
        case .bold: .bold
        }
    }
}
