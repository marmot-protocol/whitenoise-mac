//
//  OnboardingLayout.swift
//  whitenoise-mac
//
//  The numbers that make the onboarding pane read like the phone design on a
//  window that can be 2560pt wide. Pure values, so they can be asserted at
//  several window widths without standing a view up.
//

import SwiftUI

/// Metrics for the onboarding pane.
///
/// `wn-ios-prototype`'s `WelcomeView` sizes its mark with
/// `containerRelativeFrame(.horizontal, count: 2, span: 1)` — half the container — and lets its
/// buttons run the full width under `.buttonSizing(.flexible)`. Both are right on a phone and
/// both fall apart in a resizable window: half of a 2560pt window is a 1280pt mark, and a
/// full-width button is a 2496pt slab with two words in the middle of it.
///
/// So the *proportion* is kept and then clamped. Below roughly a phone's width the mark still
/// takes half the pane, exactly as the prototype draws it; past that it stops growing and the
/// pane simply gets more air around a mark that stays the size it wants to be. The actions get
/// the same treatment via a fixed column, which is also what makes the welcome screen's buttons
/// and the sign-in screen's key field line up as one column rather than two widths.
///
/// Not `nonisolated`: `ControlSize` and friends inherit the module's MainActor default. Asserting
/// these values still needs nothing but the main actor.
enum OnboardingLayout {
    /// The action column — buttons on the welcome pane, the key field and its CTA on sign-in.
    ///
    /// 360 is the width the sign-in field already used before this pane was rebuilt, and it is
    /// close to a phone's content width, so a button drawn at it has the prototype's proportions
    /// rather than a desktop form's.
    static let contentWidth: CGFloat = 360

    /// Between the block above the actions — the sign-in pane's key field — and the actions
    /// themselves. Wider than `actionSpacing` so a field and the button that submits it do not
    /// read as two members of one stack.
    static let contentToActionsSpacing: CGFloat = 24

    /// Between stacked actions. Flutter's `WnAuthButtonsContainer` puts `Gap(12.h)` between its
    /// two auth buttons; this is that gap.
    static let actionSpacing: CGFloat = 12

    /// Between the mark and the actions below it, and from the actions to the bottom edge. The
    /// prototype gets both from `Spacer()` plus `safeAreaPadding`; a window has no safe area to
    /// pad against, so the pane names them.
    static let edgePadding: CGFloat = 40

    /// The sign-up pane's floor for the same three margins, which is lower because that pane is
    /// the one with a form in it.
    ///
    /// The scaffold spends `3 × edgePadding` — 120pt — on air: above the hero, below it, and
    /// under the actions. On the welcome and sign-in panes that is most of what is on the screen
    /// and it should stay generous. The sign-up pane has an avatar, a public-profile callout, two
    /// labelled fields, a reserved error line and a button, and at a 620pt window it does not fit
    /// with 120pt of margin. Something has to give, and a margin is the only thing here that can:
    /// every other candidate is content — a shorter About field, a one-line error slot, a folded
    /// callout — and shrinking content to make room for a window edge is the wrong way round.
    ///
    /// This is a **floor**, not a fixed inset, so it only bites at the smallest window. The
    /// scaffold's `Spacer`s take back every point of spare height the moment the window has any,
    /// which on a default-sized window is well past `edgePadding` again — so the pane a person
    /// normally sees is unchanged, and the pane at the size a person can drag it to keeps its
    /// button on screen.
    static let signUpEdgePadding: CGFloat = 16

    /// The most air there is between the mark and the column of actions under it.
    ///
    /// A ceiling rather than a fixed gap, because the pane still wants to breathe on a short
    /// window and still wants its actions along the bottom edge. What it does not want is the
    /// gap growing without limit: the scaffold puts a `Spacer` above the mark and another below
    /// it, and two bare `Spacer`s split whatever is left over **evenly** — so on an 800pt-tall
    /// window the mark and the buttons end up 260pt apart, with the mark marooned in the middle
    /// of the pane and the actions stranded at the bottom. The prototype has the same even split
    /// and gets away with it on a phone, where there is a third less height to give away.
    ///
    /// Capping the lower `Spacer` sends the slack upward instead, which pulls the mark down
    /// toward the actions rather than pushing the actions up off the edge they belong on. 96 is
    /// four times `actionSpacing`: far enough that the mark is not sitting on the buttons, close
    /// enough that the two read as one group.
    static let markToActionsMaximumSpacing: CGFloat = 96

    /// How tall every onboarding push button draws, both tiers.
    ///
    /// 44 rather than whatever each style comes out at on its own, because on their own they come
    /// out at **different** heights: at `.large`, `WNElevatedButtonStyle` draws 32pt and the glass
    /// primary draws 28pt around the same label. Stacked, that is a visible 4pt step between two
    /// buttons that are meant to be a pair — and it cannot be fixed with `.frame(height:)`, which
    /// a button style ignores. The only knob is the label, so the label carries the difference.
    ///
    /// 44 is also the number the pane wants: it is the comfortable hit height for the one action a
    /// screen exists to perform, and it sits a step above the 40pt key field it submits.
    static let actionHeight: CGFloat = 44

    /// What each style adds around its label at `.large`, measured rather than assumed —
    /// `OnboardingTests.bothActionTiersDrawTheSameHeight` re-measures both through `ImageRenderer`
    /// and fails if either style's padding moves under us.
    static let elevatedActionChromeHeight: CGFloat = 16
    /// The glass primary's chrome, which is 4pt tighter than the elevated tier's.
    static let primaryActionChromeHeight: CGFloat = 12

    /// The minimum height an action's *label* must claim for its button to come out
    /// `actionHeight` tall.
    static func actionLabelHeight(for tier: OnboardingActionTier) -> CGFloat {
        switch tier {
        case .primary: actionHeight - primaryActionChromeHeight
        case .elevated: actionHeight - elevatedActionChromeHeight
        }
    }

    // MARK: - The sign-up pane

    /// The avatar that stands where the mark stands on the other two panes.
    ///
    /// Sized against the mark rather than against the settings page's 96pt avatar: it is the same
    /// slot, and a hero that changed height between panes would move the whole column under it.
    /// At 88 the avatar plus its badge comes out within a few points of `minimumMarkWidth`'s
    /// 136pt-tall mark, which is as close as two different shapes get.
    static let signUpAvatarSize: CGFloat = 88

    /// The camera badge in the avatar's bottom-trailing corner. 30, the same size Settings →
    /// Profile draws it: this avatar is 8pt smaller than that page's, so a badge scaled to match
    /// would only be heavier than the one the app already has.
    static let signUpAvatarBadgeSize: CGFloat = 30

    /// Between a field's label and the field itself.
    static let fieldLabelSpacing: CGFloat = 6

    /// Between one labelled field and the next.
    static let fieldSpacing: CGFloat = 16

    /// Between the sign-up pane's title block and the first field.
    static let titleToFieldsSpacing: CGFloat = 20

    /// `OnboardingKeyField`'s inset, so a name field and a key field line their text up.
    static let fieldHorizontalPadding: CGFloat = 12
    static let fieldVerticalPadding: CGFloat = 8

    /// A single-line field's height — `OnboardingKeyField.Metrics.height`, restated here because
    /// that one is `private` to a view that owns an accessory this field does not have.
    static let singleLineFieldHeight: CGFloat = 40

    /// How tall a field with `lineLimit` lines of `medium14` draws, chrome included.
    ///
    /// The one-line case is pinned to `singleLineFieldHeight` rather than computed, because a
    /// field that submits the same form as the key field beside it has to be exactly as tall as
    /// that field, not approximately.
    static func fieldHeight(forLineLimit lineLimit: Int) -> CGFloat {
        guard lineLimit > 1 else { return singleLineFieldHeight }
        return CGFloat(lineLimit) * multilineFieldLineHeight + 2 * fieldVerticalPadding
    }

    /// One line of `medium14`, rounded up.
    static let multilineFieldLineHeight: CGFloat = 18

    /// The corner a multi-line field takes: the radius a `singleLineFieldHeight` capsule has, so
    /// the two fields in the sign-up column share a corner without the taller one becoming a
    /// lozenge. See `OnboardingFormField`.
    static let multilineFieldCornerRadius: CGFloat = singleLineFieldHeight / 2

    /// How many lines the About field shows before it scrolls. Three, the same as the prototype's
    /// `lineLimit(3...6)` floor — a bio is a sentence or two, and every extra line here is a line
    /// the pane has to find inside a 620pt window.
    static let aboutFieldLineLimit = 3

    /// The narrowest the mark is allowed to draw, so it survives a pane squeezed by a wide
    /// account rail. Slightly above the source SVG's own 171pt width.
    static let minimumMarkWidth: CGFloat = 176

    /// The widest. Past this the mark stops being a logo and starts being wallpaper: at 240pt
    /// wide it stands 185pt tall, which is already the tallest single element on the pane.
    static let maximumMarkWidth: CGFloat = 240

    /// The prototype's `count: 2, span: 1` — half the container.
    static let markWidthFraction: CGFloat = 0.5

    /// How wide to draw the mark in a pane of `containerWidth`.
    ///
    /// Half the pane, clamped. The clamp is the whole point: it is what keeps a maximised window
    /// from drawing a mark ten times the size the design intends, while leaving the phone-width
    /// case pixel-identical to `wn-ios-prototype`.
    static func markWidth(forContainerWidth containerWidth: CGFloat) -> CGFloat {
        let proportional = containerWidth * markWidthFraction
        return min(max(proportional, minimumMarkWidth), maximumMarkWidth)
    }
}
