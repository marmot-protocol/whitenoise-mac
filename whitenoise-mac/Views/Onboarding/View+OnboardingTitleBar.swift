//
//  View+OnboardingTitleBar.swift
//  whitenoise-mac
//
//  Putting an `OnboardingTitleBar` above a signed-out screen.
//

import SwiftUI

extension View {
    /// Inset an `OnboardingTitleBar` above this screen.
    ///
    /// A safe-area inset rather than a `VStack` row inside `OnboardingScaffold`, for two
    /// reasons. It keeps the scaffold's signature to its two view builders — a `title` and an
    /// `onBack` beside them would make every call site mix a closure argument with trailing
    /// closures. And it shrinks the area the scaffold centres its content in, so the body sits
    /// in the middle of the space *below* the bar rather than in the middle of the window with
    /// the bar overlapping it.
    func onboardingTitleBar(
        title: String,
        isBackEnabled: Bool = true,
        onBack: @escaping () -> Void
    ) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            OnboardingTitleBar(title: title, onBack: onBack, isBackEnabled: isBackEnabled)
        }
    }
}
