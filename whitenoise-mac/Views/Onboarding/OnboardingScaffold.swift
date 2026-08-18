//
//  OnboardingScaffold.swift
//  whitenoise-mac
//
//  The frame every signed-out screen is built in.
//

import SwiftUI

/// The shared shape of a signed-out screen: one centred content column, with the screen's
/// actions pinned to the bottom of that column.
///
/// This is the prototype's onboarding layout — `safeAreaInset(edge: .bottom)` under a centred
/// body — expressed once so the screens cannot drift apart in column width, padding or where
/// the primary action sits.
///
/// A screen that needs a titled back strip adds one with `onboardingTitleBar(title:onBack:)`,
/// which insets it above this frame. Keeping it out here is not only tidiness: a `title` and an
/// `onBack` alongside two view builders is a call with both a closure argument and trailing
/// closures, which the formatter rejects and which reads badly besides.
///
/// **There is deliberately no `ScrollView`.** The window has a 620pt minimum height and the
/// tallest screen here is the sign-up form; wrapping the body in a scroll view would buy
/// nothing and would cost the vertical centring, which is the layout's whole character. A
/// screen that outgrows the window belongs in `SettingsScaffold`, which does scroll.
struct OnboardingScaffold<Content: View, Actions: View>: View {
    var columnWidth: CGFloat = OnboardingMetrics.formColumnWidth
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            column { content }
                .frame(maxHeight: .infinity)

            column { actions }
                .padding(.bottom, OnboardingMetrics.screenPadding)
        }
        .padding(.top, OnboardingMetrics.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // `backgroundPrimary`, the app's own reading surface — the same ground the
            // transcript and the settings pages sit on. The signed-out pane used to carry a
            // fixed #202020 that belonged to no palette and ignored the appearance entirely.
            MessagesTranscriptBackground()
        }
    }

    /// The centred column both halves share. `maxWidth` fills the proposal up to the cap and
    /// the outer `frame` re-centres it, so the column is the same width whatever the window is.
    private func column<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        inner()
            .frame(maxWidth: columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, OnboardingMetrics.screenPadding)
    }
}
