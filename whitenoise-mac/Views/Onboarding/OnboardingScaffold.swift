//
//  OnboardingScaffold.swift
//  whitenoise-mac
//
//  The shape both onboarding panes take, so the mark cannot move between them.
//

import SwiftUI

/// The onboarding pane: mark in the middle, a column of actions along the bottom.
///
/// This is `wn-ios-prototype`'s `WelcomeView` skeleton — `Spacer()`, mark, `Spacer()`, actions —
/// generalised so the sign-in pane can reuse it, with two changes that only a resizable window
/// needs. The `Spacer` under the mark is **capped**, so a tall pane cannot maroon the mark half a
/// screen above the buttons; and the pane's bottom inset is a **flexible** `Spacer` rather than the
/// prototype's `safeAreaPadding(.bottom)`, so the mark-and-actions group stays centred instead of
/// riding the bottom edge. On the phone those are two screens and sign-in is pushed onto a
/// `NavigationStack`, which is why the prototype's sign-in screen has no mark: a push replaces the
/// view, and the nav bar carries the way back.
///
/// A window is not a stack. Swapping one pane for another inside the same window and dropping the
/// mark on the way would read as the window having navigated somewhere else, and it would leave
/// the top two-thirds of a 620pt-tall pane empty. So the mark is part of the scaffold, both panes
/// keep it, and what changes between them is the column underneath — which is also what makes the
/// transition between them a small local one rather than a whole-pane replacement.
///
/// The mark's width is measured rather than proportional; see `OnboardingLayout.markWidth`.
struct OnboardingScaffold<Content: View, Actions: View>: View {
    /// Supplied only by a pane that has somewhere to go back to. The welcome pane is the root and
    /// passes `nil`, which removes the control while keeping the row it stood in.
    var backAction: (() -> Void)?
    /// Whatever sits between the mark and the actions — the sign-in pane's key field. Empty on
    /// the welcome pane, which contributes no subview and therefore no spacing.
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    /// The pane's own width, not the window's: the account rail and the chat drawer are siblings,
    /// so on the signed-in "add another account" path this pane is narrower than the window.
    @State private var paneWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeaderRow(backAction: backAction)

            Spacer(minLength: OnboardingLayout.edgePadding)

            WhiteNoiseMarkView(
                width: OnboardingLayout.markWidth(forContainerWidth: paneWidth)
            )

            // Capped, unlike the `Spacer` above the mark, so the pane's spare height collects at
            // the top instead of being split evenly across the mark. See
            // `OnboardingLayout.markToActionsMaximumSpacing`.
            Spacer(minLength: OnboardingLayout.edgePadding)
                .frame(maxHeight: OnboardingLayout.markToActionsMaximumSpacing)

            VStack(spacing: OnboardingLayout.contentToActionsSpacing) {
                content

                VStack(spacing: OnboardingLayout.actionSpacing) {
                    actions
                }
            }
            .frame(width: OnboardingLayout.contentWidth)

            // Flexible, and the twin of the `Spacer` above the mark rather than a fixed inset.
            // A fixed one made every point of spare height land *above* the mark, so a tall
            // window pushed the whole group onto the bottom edge; two flexible ends split it and
            // the group sits centred with real air under the buttons. `edgePadding` is the floor,
            // for the short window where there is nothing to split.
            Spacer(minLength: OnboardingLayout.edgePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            paneWidth = width
        }
        .background {
            // `backgroundPrimary`, the app's reading surface — the same ground the transcript and
            // the settings pages stand on, and what the other clients' sign-in screen uses. The
            // pane this replaced painted itself the same way; what it could not do was carry a
            // logo that agreed with it, because the logo was a baked dark tile. See
            // `WhiteNoiseMarkView`.
            MessagesTranscriptBackground()
        }
    }
}

/// The scaffold's top row, present on **both** panes whether or not it has a control in it.
///
/// Reserving the height unconditionally is what keeps the mark from jumping when the pane swaps:
/// the scaffold's two `Spacer`s centre the mark in whatever is left below this row, so a row that
/// appeared only on sign-in would shift the mark down by its height on the way in and back up on
/// the way out.
private struct OnboardingHeaderRow: View {
    let backAction: (() -> Void)?

    var body: some View {
        HStack {
            if let backAction {
                GlassCircleCloseButton(
                    symbol: "chevron.left",
                    help: "Back",
                    appearance: .outline,
                    action: backAction
                )
                .accessibilityLabel(L10n.string("Back"))
                .accessibilityIdentifier("onboarding.back")
            }

            Spacer(minLength: 0)
        }
        .frame(height: MessagesLayout.circleControlSize)
        .padding(.horizontal, OnboardingLayout.edgePadding)
        // The pane starts at the window's top edge in a `.hiddenTitleBar` window, so this control
        // would otherwise land under the traffic lights — or under the offline band, when one is
        // up. See `WindowTitlebarClearance`.
        .sidebarTitlebarClearance()
    }
}
