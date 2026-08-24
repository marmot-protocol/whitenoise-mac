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
///
/// **The hero is the one part of the scaffold a pane may replace.** Both the prototype's sign-up
/// screen and Flutter's `SignupScreen` drop the logo there and put the avatar being created in its
/// place — the subject of that screen is the identity, not the app — and they can, because on a
/// phone it is a pushed screen with a nav bar to carry the way back. A window has neither, so the
/// swap happens inside the same scaffold: same header row, same two `Spacer`s, same action column,
/// and only the thing they are arranged around changes. `OnboardingMarkHero` is the default, so a
/// pane that says nothing gets the mark.
struct OnboardingScaffold<Hero: View, Content: View, Actions: View>: View {
    /// What this pane is called, drawn in the header row. `nil` on the panes that do not need one:
    /// a screen whose whole content is a mark over two buttons is not asking a question.
    ///
    /// The header row is where it goes because the header row is already there — 28pt reserved on
    /// every pane so the hero cannot jump — and a title inside it therefore costs the column below
    /// nothing. That matters on the sign-up pane, which is 13pt too tall for a 620pt window with
    /// its title in the content and comfortably inside it with the title up here. It is also where
    /// both phone clients put the same string: `wn-ios-prototype` as a `navigationTitle`, Flutter
    /// as its `WnSlateNavigationHeader` title, both beside the same back control.
    var title: String?
    /// Supplied only by a pane that has somewhere to go back to. The welcome pane is the root and
    /// passes `nil`, which removes the control while keeping the row it stood in.
    var backAction: (() -> Void)?
    /// What the pane is arranged around. Defaults to the mark.
    @ViewBuilder var hero: Hero
    /// Whatever sits between the hero and the actions — the sign-in pane's key field, the sign-up
    /// pane's form. Empty on the welcome pane, which contributes no subview and therefore no
    /// spacing.
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeaderRow(title: title, backAction: backAction)

            Spacer(minLength: OnboardingLayout.edgePadding)

            hero

            // Capped, unlike the `Spacer` above the hero, so the pane's spare height collects at
            // the top instead of being split evenly across the hero. See
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

            // Flexible, and the twin of the `Spacer` above the hero rather than a fixed inset.
            // A fixed one made every point of spare height land *above* the hero, so a tall
            // window pushed the whole group onto the bottom edge; two flexible ends split it and
            // the group sits centred with real air under the buttons. `edgePadding` is the floor,
            // for the short window where there is nothing to split.
            Spacer(minLength: OnboardingLayout.edgePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

extension OnboardingScaffold where Hero == OnboardingMarkHero {
    /// The scaffold as both existing panes use it: the mark as the hero.
    init(
        title: String? = nil,
        backAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            title: title,
            backAction: backAction,
            hero: { OnboardingMarkHero() },
            content: content,
            actions: actions
        )
    }
}

/// The scaffold's top row, present on **every** pane whether or not it has a control in it.
///
/// Reserving the height unconditionally is what keeps the hero from jumping when the pane swaps:
/// the scaffold's two `Spacer`s centre the hero in whatever is left below this row, so a row that
/// appeared only on sign-in would shift the hero down by its height on the way in and back up on
/// the way out.
private struct OnboardingHeaderRow: View {
    let title: String?
    let backAction: (() -> Void)?

    var body: some View {
        // Overlaid rather than a third `HStack` member, so the title is centred on the *pane* and
        // not on whatever is left of it beside the back control — which would move it sideways
        // between a pane that has a back control and one that does not.
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
        .overlay {
            if let title {
                Text(title)
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                    .lineLimit(1)
                    // Never under the back control, however narrow the pane gets.
                    .padding(.horizontal, MessagesLayout.circleControlSize + OnboardingLayout.actionSpacing)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("onboarding.title")
            }
        }
        .frame(height: MessagesLayout.circleControlSize)
        .padding(.horizontal, OnboardingLayout.edgePadding)
        // The pane starts at the window's top edge in a `.hiddenTitleBar` window, so this control
        // would otherwise land under the traffic lights — or under the offline band, when one is
        // up. See `WindowTitlebarClearance`.
        .sidebarTitlebarClearance()
    }
}
