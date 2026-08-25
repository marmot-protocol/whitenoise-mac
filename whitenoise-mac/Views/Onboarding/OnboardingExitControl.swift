//
//  OnboardingExitControl.swift
//  whitenoise-mac
//
//  The two different ways off an onboarding pane, and what each one looks like.
//

import Foundation

/// The control in `OnboardingScaffold`'s header row: what it does, and therefore how it draws.
///
/// The two are not the same gesture, and `wn-ios-prototype` draws them differently for that
/// reason. `AddProfileFlow` pushes `LoginView` and `SignUpView` onto a `NavigationStack`, so those
/// get the nav bar's **back** chevron — the pane behind them is still there. Its root
/// `WelcomeView` gets a **`Cancel`** toolbar item instead, because there is no pane behind it: the
/// gesture leaves the flow altogether and returns to the app the flow was opened from.
///
/// One value rather than a `backAction` plus a style flag, so the symbol and the action cannot
/// disagree about which of the two a pane is offering — the same reason the panes set
/// `controlSize` and `wnButtonShape` once on the pane instead of per button.
enum OnboardingExitControl {
    /// Return to the pane behind this one, within the flow. The prototype's nav-bar back.
    case back(() -> Void)
    /// Leave the flow for the app it was opened from. The prototype's `Cancel` toolbar item.
    case cancel(() -> Void)

    var symbol: String {
        switch self {
        case .back: "chevron.left"
        case .cancel: "xmark"
        }
    }

    /// A catalog key, not display text: `GlassCircleCloseButton` localizes `help` itself.
    var helpKey: String {
        switch self {
        case .back: "Back"
        case .cancel: "Cancel"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .back: "onboarding.back"
        case .cancel: "onboarding.cancel"
        }
    }

    var action: () -> Void {
        switch self {
        case .back(let action), .cancel(let action): action
        }
    }
}
