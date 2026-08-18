//
//  OnboardingErrorMessage.swift
//  whitenoise-mac
//
//  The failure line under a signed-out screen's actions.
//

import SwiftUI

/// The last user-facing failure on a signed-out screen, rendered under its actions.
///
/// Takes an optional and draws nothing for `nil` so a screen can place it unconditionally.
/// Every onboarding action reports into the same `lastError`, so this is the one place any of
/// them surfaces — the alternative, an error hung off whichever button produced it, moves the
/// buttons as it appears.
struct OnboardingErrorMessage: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentDestructive)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .transition(.opacity)
        }
    }
}
