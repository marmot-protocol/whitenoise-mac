//
//  SplashScreen.swift
//  whitenoise-mac
//
//  What the window shows while the runtime comes up.
//

import SwiftUI

/// The launch screen: the mark, and what the app is doing behind it.
///
/// This is the first frame of the app and it used to be a bare `ProgressView` on an unpainted
/// pane, which made the moment before the workspace is ready look like a stall rather than a
/// launch. Drawing the mark here is what makes the splash and the welcome screen read as one
/// screen settling into the next — the mark is in the same place, and the buttons arrive under
/// it once bootstrap finishes.
struct SplashScreen: View {
    var body: some View {
        VStack(spacing: OnboardingMetrics.sectionSpacing) {
            OnboardingBrandMark(size: OnboardingMetrics.compactMarkSize)

            VStack(spacing: OnboardingMetrics.stackSpacing) {
                ProgressView()
                    .controlSize(.small)

                Text(L10n.string("Starting Marmot"))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            MessagesTranscriptBackground()
        }
    }
}

#Preview {
    SplashScreen()
        .frame(width: 940, height: 620)
}
