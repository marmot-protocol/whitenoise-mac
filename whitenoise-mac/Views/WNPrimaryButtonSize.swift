//
//  WNPrimaryButtonSize.swift
//  whitenoise-mac
//
//  The metrics half of `WNPrimaryButton`, kept apart from the view so the three
//  numbers a size controls can be asserted without standing one up.
//

import SwiftUI

/// How large a `WNPrimaryButton` draws.
///
/// A pure value so the metrics can be asserted without standing up a view. `WnButton`
/// (`lib/widgets/wn_button.dart`) keys the same three numbers off `WnButtonSize`, and this is that
/// idea at mac scale: the phone's `large` is 18pt of vertical padding on a thumb-sized full-width
/// CTA, which would tower over anything beside it here.
/// Not `nonisolated`: `font` reads the `WNTextStyle` ladder, whose rungs inherit the module's
/// MainActor default. Asserting these values still needs nothing but the main actor — no view, no
/// window, no environment.
enum WNPrimaryButtonSize: CaseIterable {
    /// A button standing beside other controls — a sheet's confirm, a row's action.
    case medium
    /// The one action a screen exists to perform, with nothing competing for the same row.
    /// `Save profile` is this: the form above it is the whole page.
    case large

    /// The label's rung of the type ramp.
    var font: WNTextStyle {
        switch self {
        case .medium: .medium14
        case .large: .medium16
        }
    }

    /// Padding added *inside* the label, on top of whatever the native style draws for
    /// `controlSize`. This is the knob that actually makes the button taller — a `.padding` applied
    /// to the `Button` itself would push the glass away rather than grow it.
    var verticalPadding: CGFloat {
        switch self {
        case .medium: 2
        case .large: 8
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .medium: 6
        case .large: 14
        }
    }

    /// A size names no shape of its own. `WNPrimaryButton` asks `WNButtonMetrics` for one using
    /// `controlSize` below, which is the only way a primary button and the `.wnSecondary` one
    /// beside it can be promised the same outline — a radius stored here would be a second copy of
    /// the table, and a second copy is what let the two tiers disagree in the first place.
    var controlSize: ControlSize {
        switch self {
        case .medium: .regular
        case .large: .large
        }
    }
}
