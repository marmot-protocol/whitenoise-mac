//
//  OnboardingTests.swift
//  whitenoise-macTests
//

import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// Guards the three things about the onboarding panes that fail *silently*.
///
/// The panes themselves are layout, and layout is reviewed by looking at it. These are the parts
/// that look fine and are wrong: a mark that grows without limit on a big display, a pair of
/// buttons a few points apart, a template asset that stopped being a template, and a field that
/// quietly refuses a key the core would have accepted.
///
/// `.serialized` and `@MainActor` because several of these switch `NSAppearance` to rasterize:
/// `performAsCurrentDrawingAppearance` off the main thread takes the test host down with it, and
/// the failure lands on whichever suite happened to be running.
@Suite(.serialized) @MainActor struct OnboardingTests {

    // MARK: - The mark is sized proportionally, then clamped

    /// The prototype's `count: 2, span: 1` — half the container — held exactly through the phone
    /// widths it was designed at, and clamped past them. A regression here does not look broken at
    /// any one size; it looks broken only on somebody's 27" display.
    @Test func theMarkTakesHalfThePaneUntilItWouldGetSilly() {
        // Phone-ish widths: the prototype's proportion, untouched.
        #expect(OnboardingLayout.markWidth(forContainerWidth: 400) == 200)
        #expect(OnboardingLayout.markWidth(forContainerWidth: 440) == 220)

        // The window's own minimum and up: clamped, not proportional. Half of 940 is 470.
        #expect(OnboardingLayout.markWidth(forContainerWidth: 940) == OnboardingLayout.maximumMarkWidth)
        #expect(OnboardingLayout.markWidth(forContainerWidth: 1600) == OnboardingLayout.maximumMarkWidth)
        #expect(OnboardingLayout.markWidth(forContainerWidth: 2560) == OnboardingLayout.maximumMarkWidth)

        // A pane squeezed by the account rail and the chat drawer, and the first frame before
        // `onGeometryChange` has reported anything at all.
        #expect(OnboardingLayout.markWidth(forContainerWidth: 300) == OnboardingLayout.minimumMarkWidth)
        #expect(OnboardingLayout.markWidth(forContainerWidth: 0) == OnboardingLayout.minimumMarkWidth)
    }

    /// 171 × 132 is the source SVG's `viewBox`. Spelled out here rather than read from the view, so
    /// a mark squashed into a square frame fails against the artwork instead of agreeing with
    /// itself.
    @Test func theMarkKeepsTheArtworksProportions() {
        #expect(abs(WhiteNoiseMarkView.aspectRatio - 171.0 / 132.0) < 0.0001)
    }

    // MARK: - The mark is ink, not a tile

    /// The defect this replaced: `WhiteNoiseLogo` was an opaque `#2C2C2C` rounded tile with the
    /// mark knocked out of it, so it could not follow the appearance and the pane behind it had to
    /// be chosen to hide the seam.
    ///
    /// Two things are asserted per appearance, and the first is the one that matters: **every
    /// opaque pixel is the ink token and nothing else**. A tile would put a second opaque colour in
    /// the frame; a template asset that quietly stopped being a template would put `#0A0A0A` in
    /// the dark render, where white is expected.
    @Test(arguments: [
        (NSAppearance.Name.aqua, WNColorRamp.neutral950),
        (NSAppearance.Name.darkAqua, WNColorRamp.white),
    ])
    func theMarkDrawsAsInkWithNothingBehindIt(appearance: NSAppearance.Name, expected: NSColor) throws {
        let rep = try Self.rasterize(appearance: appearance) {
            WhiteNoiseMarkView(width: 120)
        }

        let target = try #require(expected.usingColorSpace(.sRGB))
        var opaque = 0
        var transparent = 0

        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }

                if pixel.alphaComponent > 0.99 {
                    opaque += 1
                    #expect(
                        Self.channelDistance(pixel, target) < 0.04,
                        "opaque pixel at (\(x), \(y)) is not the ink token"
                    )
                } else if pixel.alphaComponent < 0.01 {
                    transparent += 1
                }
            }
        }

        // A blank render would satisfy the loop above by drawing nothing at all, and a tile would
        // leave no transparent pixels. Both halves have to hold.
        #expect(opaque > 0, "the mark drew nothing")
        #expect(transparent > opaque / 4, "too little of the frame is empty — is there a tile behind the mark?")
    }

    // MARK: - The two action tiers are the same height

    /// `.frame(height:)` on a `Button` is silently ignored by every button style, so the only way
    /// two tiers can agree on a height is for their labels to carry the difference — which means
    /// the difference has to be *measured*, and re-measured whenever either style's padding moves.
    /// That is what this does. Left alone, the glass primary comes out 4pt shorter than the
    /// secondary tier at `.large`.
    @Test func bothActionTiersDrawTheSameHeight() throws {
        for tier in [OnboardingActionTier.primary, .secondary] {
            let button = OnboardingActionButton(title: "Sign Up", tier: tier) {}
                .controlSize(.large)
                .frame(width: OnboardingLayout.contentWidth)

            let height = try #require(ImageRenderer(content: button).nsImage?.size.height)
            #expect(
                height == OnboardingLayout.actionHeight,
                "\(tier) drew \(height)pt, not \(OnboardingLayout.actionHeight)pt"
            )
        }
    }

    // MARK: - The onboarding buttons are pills

    /// The mismatch this fixes. `wn-ios-prototype`'s `WelcomeView` puts its two actions on
    /// `.glass` and `.glassProminent` and names **no** `buttonBorderShape`, so Liquid Glass draws
    /// its own default — a capsule. The mac pane overrode that back to a 12pt rounded rectangle.
    ///
    /// Asserted on the drawn pixels rather than on the metric, because the metric being right is
    /// not the part that broke: a tier that forgot to *read* it would still pass a value check.
    ///
    /// The probe is how far in the ground starts 6pt below the button's top edge. That row is
    /// chosen because it is where the two shapes are furthest apart while both are still well
    /// inside the button: a 12pt corner has almost finished turning by then and begins at 1.5pt,
    /// while a pill's 22pt corner is only a quarter of the way round and begins at 6.5pt. The
    /// bounds below leave a 2pt margin on each side of those two measurements.
    @Test func theOnboardingTiersDrawAPillAndTheAppsOwnTiersDoNot() throws {
        let capsule = try Self.leftEdgeOnset(shape: .capsule)
        let rounded = try Self.leftEdgeOnset(shape: .rounded)

        #expect(capsule >= 4.5, "the onboarding button's edge starts at \(capsule)pt — that is not a pill")
        #expect(
            rounded <= 3.5,
            "the rounded tier's edge starts at \(rounded)pt — this test can no longer tell the two apart")
    }

    /// Onboarding's buttons are pills, and the shape is one decision rather than three.
    ///
    /// It is set on the *pane*: a pane that set it on one of two stacked buttons would ship a pill
    /// above a rounded rectangle. `wn-ios-prototype` names no border shape on these at all, which
    /// under Liquid Glass *is* the spec — the platform default for a prominent button is a capsule,
    /// so the prototype's silence is a choice rather than an omission.
    @MainActor
    @Test func onboardingButtonsAreCutToAPillByOneSharedDecision() {
        #expect(OnboardingLayout.buttonShape == .capsule)

        // …and a capsule really is what the shape table hands a button, at every size: a pill has
        // no radius of its own, it is always half its own height, which is what keeps it a pill as
        // the control grows.
        let rect = CGRect(x: 0, y: 0, width: OnboardingLayout.contentWidth, height: 44)
        for controlSize in [ControlSize.regular, .large] {
            #expect(
                WNButtonMetrics.borderShape(OnboardingLayout.buttonShape, for: controlSize) == .capsule
            )
            #expect(
                WNButtonMetrics.backgroundShape(OnboardingLayout.buttonShape, for: controlSize)
                    .path(in: rect) == Capsule(style: .continuous).path(in: rect)
            )
        }
    }

    // MARK: - The mark cannot drift half a pane above the actions

    /// Two bare `Spacer`s split a pane's spare height evenly, which on a tall window puts the mark
    /// in the middle and the actions on the bottom edge with a void between them. The lower one is
    /// capped so the slack collects above the mark instead. A regression here looks fine on a short
    /// window and only opens up as the window grows, which is why the bound is asserted rather than
    /// looked at.
    @Test func theGapUnderTheMarkIsBounded() {
        #expect(OnboardingLayout.markToActionsMaximumSpacing > OnboardingLayout.actionSpacing)
        // Bounded well under what an even split would hand it. A 800pt pane has roughly 520pt to
        // give away, so an uncapped lower spacer takes ~260.
        #expect(OnboardingLayout.markToActionsMaximumSpacing <= 120)

        // The cap has to survive the `minLength` the scaffold also asks for, or the frame clamps
        // below the minimum and the two fight.
        #expect(OnboardingLayout.markToActionsMaximumSpacing > OnboardingLayout.edgePadding)
    }

    // MARK: - The one secondary tier is raised, not ringed

    /// The app's secondary push button is shadowed and has no outline — the whole of what was
    /// decided when the ringed tier was folded into this one. Both halves are asserted, because a
    /// regression could come from either end: a ring is what the app's other ground-drawing
    /// components still stroke (`WNInput`, `MessagesCircleControlBackground`), and the shadow is
    /// the only thing lifting a `backgroundSlate` ground off the pane it sits on.
    ///
    /// A ringed copy of the same button stands in as the positive control — without one, a test
    /// that merely finds no outline would pass just as happily against a button that drew nothing
    /// at all. The copy is the real style with a stroke laid over it rather than a second style
    /// written out here, so the control cannot disagree with the button under test about where its
    /// edge is or how tall it stands.
    @Test func theSecondaryTierIsRaisedRatherThanRinged() throws {
        let raised = try Self.edgeScanline(ringed: false)
        let ringed = try Self.edgeScanline(ringed: true)

        // `borderSecondary` is `neutral500`, ~0.45 luminance, against the tier's resting
        // `backgroundSlate` ground at ~0.98 and a `backgroundPrimary` pane at 1.0. Anything below
        // 0.75 on this scanline is a stroke; nothing else on it comes close.
        #expect(
            ringed.contains(where: { $0 < 0.75 }),
            "the ringed control drew no outline — this test can no longer see a ring at all")
        #expect(
            !raised.contains(where: { $0 < 0.75 }),
            "the secondary tier drew an outline")

        // The shadow: pixels in the pane's margin, outside the button's fill, that are darker than
        // the bare pane.
        // Resolved *inside* `.aqua`, because that is the appearance `edgeScanline` rasterizes in
        // and `NSColor(SwiftUI.Color)` resolves a dynamic token against whatever appearance is
        // current when it is called — the **system's**, here, since nothing else has set one. Read
        // bare, this comparison silently swaps in `backgroundPrimary`'s dark value (~0.04) and asks
        // a light render to find a pixel darker than that, which nothing on it can be. It fails
        // only on a Mac whose appearance is dark at the moment the suite runs, which on the default
        // "Auto" setting means it fails after sunset and passes in the morning.
        var paneColor: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            paneColor = NSColor(WNColor.backgroundPrimary).usingColorSpace(.sRGB)
        }
        let paneLuminance = try #require(paneColor?.brightnessComponent)
        #expect(
            raised.contains(where: { $0 < paneLuminance - 0.02 && $0 > 0.75 }),
            "the secondary tier cast no shadow")
    }

    // MARK: - What the sign-in field makes of what is in it

    /// The regression this exists to prevent. `wn-ios-prototype` validates with
    /// `hasPrefix("nsec")`; ported literally, the sign-in button would never enable for an
    /// `npub1…`, and adding a watch-only account through the UI would become impossible with no
    /// error to explain why.
    @Test func anNpubIsAValidIdentityJustLikeAnNsec() {
        #expect(LoginIdentityDraft("nsec1" + String(repeating: "q", count: 58)) == .valid)
        #expect(LoginIdentityDraft("npub1" + String(repeating: "q", count: 58)) == .valid)
        #expect(LoginIdentityDraft("npub1abc").isSubmittable)
    }

    @Test func aDraftIsEmptyBeforeItIsWrong() {
        #expect(LoginIdentityDraft("") == .empty)
        #expect(LoginIdentityDraft("   \n ") == .empty)
        #expect(LoginIdentityDraft("").isSubmittable == false)
    }

    @Test func aDraftIgnoresSurroundingWhitespaceAndCase() {
        #expect(LoginIdentityDraft("  nsec1abc  ") == .valid)
        #expect(LoginIdentityDraft("NSEC1ABC") == .valid)
        #expect(LoginIdentityDraft("\nNpub1AbC\t") == .valid)
    }

    @Test func aDraftRejectsAnythingThatIsNotOneOfTheTwoPrefixes() {
        // No separator: `nsec` alone is not a bech32 string.
        #expect(LoginIdentityDraft("nsec") == .invalid)
        #expect(LoginIdentityDraft("hello") == .invalid)
        // A hex private key, which the core does not take through this door.
        #expect(LoginIdentityDraft(String(repeating: "a", count: 64)) == .invalid)
        #expect(LoginIdentityDraft("note1abc") == .invalid)
    }

    /// The core's complaint about the last attempt belongs to the field that attempt was made
    /// from, and `login()` empties that field on failure (issue #32). Anything in the field
    /// afterwards is a different identity, so the draft stops standing behind the complaint —
    /// without this a replacement key sits under the rejected key's error, and the pane reads as
    /// having refused a key it has not been given yet.
    @Test func onlyAnEmptyDraftStandsBehindTheLastAttemptsError() {
        #expect(LoginIdentityDraft("").showsLastAttemptError)
        #expect(LoginIdentityDraft("   \n ").showsLastAttemptError)

        #expect(LoginIdentityDraft("nsec1" + String(repeating: "q", count: 58)).showsLastAttemptError == false)
        #expect(LoginIdentityDraft("npub1" + String(repeating: "q", count: 58)).showsLastAttemptError == false)
        #expect(LoginIdentityDraft("hello").showsLastAttemptError == false)
    }

    // MARK: - The sign-up hero

    /// The draft's face is the *inverted* disc, in both appearances.
    ///
    /// This one is invisible in exactly one appearance, which is how it shipped: the draft used to
    /// be drawn through `AvatarPalette`, and that ramp's light step is `50` — a pale wash that read
    /// as an empty placeholder rather than as the subject of the pane, while the dark step (`950`)
    /// looked perfectly deliberate. `wn-ios-prototype`'s `ProfileEditorAvatarView` fills the same
    /// disc with `AccentColor`, black on light and white on dark, which is `fillPrimary` here.
    ///
    /// Sampled off-centre so the probe reads the ground rather than the initials sitting on it, and
    /// asserted against the ramp step rather than against "is it dark", because the failure this
    /// guards against is a *different* token that happens to be dark in one appearance.
    ///
    /// Both of the disc's states are asserted, and the empty one is the half that shipped wrong:
    /// it used to take `fillSecondary` — the prototype's `.secondarySystemFill` — so in light the
    /// pane opened on a near-white circle and turned black the moment a name was typed under it.
    /// The prototype's `SignUpView` passes no `emptySystemImage`, so its disc is `AccentColor`
    /// from the first frame; this is that.
    @Test(arguments: [
        (NSAppearance.Name.aqua, WNColorRamp.neutral950),
        (NSAppearance.Name.darkAqua, WNColorRamp.white),
    ])
    func theSignUpAvatarIsTheInvertedDisc(appearance: NSAppearance.Name, expected: NSColor) throws {
        let named = Self.signUpWorkspace()
        // One word, so `DisplayText.initials` yields a single letter and the probe band below
        // stays clear of it.
        named.signUpDraft.displayName = "Pepi"

        try Self.expectDiscGround(
            of: named,
            appearance: appearance,
            is: expected,
            "the sign-up avatar's ground is not `fillPrimary`")

        try Self.expectDiscGround(
            of: Self.signUpWorkspace(),
            appearance: appearance,
            is: expected,
            "the *empty* sign-up avatar's ground is not `fillPrimary`")
    }

    /// And what is *on* the ground runs the other way: light content on a dark disc in light mode,
    /// dark content on a light one in dark mode.
    ///
    /// The inversion is the whole point of the pairing, and it is the half a token swap breaks
    /// without breaking the other: `fillSecondary` under `fillContentSecondary` is a perfectly
    /// self-consistent pair that happens to run in the opposite direction, which is what the empty
    /// frame used to draw. Asserted as a *direction* rather than against two ramp steps, so the
    /// glyph's antialiasing and `ImageRenderer`'s own colour shifts cannot decide the outcome — a
    /// pair that inverts clears half a luminance unit; a pair that does not cannot.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theSignUpAvatarsMarkInvertsItsGround(appearance: NSAppearance.Name) throws {
        // Both marks the disc can carry: the person glyph of the empty first frame, and the
        // initials that replace it.
        let named = Self.signUpWorkspace()
        named.signUpDraft.displayName = "Pepi"

        for (workspace, mark) in [(Self.signUpWorkspace(), "person glyph"), (named, "initials")] {
            let (ground, ink) = try Self.discGroundAndMarkLuminance(of: workspace, appearance: appearance)
            // In light the ground is `neutral950` (~0.04) under white ink; in dark it is white
            // under `neutral950`. Either way the two are nearly a full unit apart, so half a unit
            // is a threshold no same-direction pair can reach.
            let inverts = appearance == .aqua ? ink - ground > 0.5 : ground - ink > 0.5
            #expect(
                inverts,
                "the \(mark) is \(ink) on a \(ground) ground in \(appearance.rawValue) — no inversion")
        }
    }

    /// The picture-picking affordance is a control *under* the avatar, not a badge on it.
    ///
    /// `wn-ios-prototype`'s `SignUpView` hangs its source menu off an `Add Photo` / `Change Photo`
    /// pill and leaves the face inert; the badge this replaced sat inside the avatar's own frame,
    /// so the hero was exactly `signUpAvatarSize` tall. Measuring the hero is what tells the two
    /// apart: a regression to an overlaid badge cannot make the group taller than the avatar.
    @Test func theSignUpHeroCarriesAPillUnderTheAvatar() throws {
        let hero = OnboardingSignUpAvatar()
            .environment(Self.signUpWorkspace())
            .frame(width: OnboardingLayout.contentWidth)

        let height = try #require(ImageRenderer(content: hero).nsImage?.size.height)
        let floor = OnboardingLayout.signUpAvatarSize + OnboardingLayout.signUpAvatarToPickerSpacing
        #expect(
            height > floor,
            "the hero is \(height)pt — nothing is drawn below the \(OnboardingLayout.signUpAvatarSize)pt avatar")
    }

    /// The pill's two labels have to be two different strings in every language, since the whole
    /// reason it is a label rather than a camera glyph is that it carries the state.
    @Test func thePickerPillSaysWhetherThereIsAlreadyAPhoto() {
        #expect(L10n.string("Add photo") != L10n.string("Change photo"))
    }

    /// And it is the pane's own secondary tier — the raised one `Sign In` wears — rather than a
    /// bordered style of its own.
    ///
    /// `ProfileImageSourceMenu.Appearance.pushButton` names no `buttonStyle`, so what this pill
    /// wears is whatever the pane hands down; the probe checks what actually arrived. A ring is
    /// what any other push style would bring with it (`.bordered`, and the ringed secondary this
    /// app used to ship), so the ring is what is looked for, with a ringed copy of the same
    /// control standing in as the positive control: without it a probe that merely finds no
    /// outline would pass just as happily against a pill that drew nothing, or against a row the
    /// probe was reading in the wrong place.
    ///
    /// This is the regression that cannot be seen by looking at the pane on its own — a ringed
    /// pill under the avatar looks perfectly deliberate until it is put next to the `Sign In`
    /// button one pane back.
    @Test func thePhotoPillWearsThePanesSecondaryTier() throws {
        let hero = try Self.pickerEdgeColumns(of: OnboardingSignUpAvatar())
        let ringed = try Self.pickerEdgeColumns(of: Self.ringedPickerStandIn)

        // `borderSecondary` is `neutral500`, ~0.45, against the tier's resting ground at ~0.96 and
        // up. The same 0.75 the tier test uses.
        #expect(
            ringed.contains(where: { $0 < 0.75 }),
            "the ringed stand-in drew no outline — this probe can no longer see a ring at all")
        #expect(
            !hero.contains(where: { $0 < 0.75 }),
            "the sign-up hero's photo control is ringed, so it is not the pane's secondary tier")
    }

    /// The hero's picker with a ring laid over it and nothing else changed.
    ///
    /// A deliberate copy of `OnboardingSignUpAvatar`'s stack rather than the view itself, because
    /// the view hands its own tier over from the inside and an outer `.buttonStyle` cannot reach
    /// past that — which is the property being relied on. Geometry has to match the real one point
    /// for point, since the probe finds the control by walking a row of the render, which is why
    /// the ring is an overlay on the same tier rather than a second style with a padding table of
    /// its own.
    private static var ringedPickerStandIn: some View {
        VStack(spacing: OnboardingLayout.signUpAvatarToPickerSpacing) {
            SignUpAvatarView(size: OnboardingLayout.signUpAvatarSize)

            ProfileImageSourceMenu(
                destination: .signUpDraft, appearance: .pushButton, isEnabled: true
            ) {
                Text(L10n.string("Add photo"))
                    .wnFont(.medium12)
            }
            .onboardingActionTier(.secondary)
            // `.capsule` because `pickerEdgeColumns` sets that on the container, the way the pane
            // does; the shape decides where the edge the probe reads is.
            .overlay { ringOverlay(.capsule, for: .small) }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }

    /// The ring the app no longer draws on a push button, for use as a positive control.
    ///
    /// `borderSecondary` at 1pt on the shared shape table: what the ringed secondary tier stroked
    /// before it was folded into the raised one. It lives here, in the tests, because that is the
    /// only thing it is still for — a probe looking for the absence of an outline needs one
    /// outline to prove it can see one.
    private static func ringOverlay(_ shape: WNButtonShape, for controlSize: ControlSize) -> some View {
        WNButtonMetrics.backgroundShape(shape, for: controlSize)
            .stroke(WNColor.borderSecondary, lineWidth: 1)
    }

    /// The luminance of the avatar's ground, and of the pixel on it that is furthest from it.
    ///
    /// The second number is the mark — the initials or the person glyph — found rather than
    /// sampled at a fixed point, because neither one fills a predictable pixel: a `P` is mostly
    /// counter and the glyph's shoulders are antialiased. Searching the middle of the disc for the
    /// pixel that departs furthest from the ground is what a reader's eye does with it, and it
    /// cannot be fooled by a mark that happens to miss the centre.
    ///
    /// The search box is the middle 40% of the frame, which is inside the disc on every row and
    /// well clear of `AvatarChromeModifier`'s ring.
    private static func discGroundAndMarkLuminance(
        of workspace: WorkspaceState,
        appearance: NSAppearance.Name
    ) throws -> (ground: CGFloat, mark: CGFloat) {
        let rep = try rasterize(appearance: appearance) {
            SignUpAvatarView(size: OnboardingLayout.signUpAvatarSize)
                .environment(workspace)
        }

        // The same band `expectDiscGround` reads: on the centre row the disc spans the full width,
        // and 18% in is past the ring and short of either mark.
        let ground = try #require(
            rep.colorAt(x: rep.pixelsWide * 18 / 100, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        ).brightnessComponent

        var mark = ground
        for y in stride(from: rep.pixelsHigh * 30 / 100, to: rep.pixelsHigh * 70 / 100, by: 1) {
            for x in stride(from: rep.pixelsWide * 30 / 100, to: rep.pixelsWide * 70 / 100, by: 1) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(pixel.brightnessComponent - ground) > abs(mark - ground) {
                    mark = pixel.brightnessComponent
                }
            }
        }

        return (ground, mark)
    }

    /// Luminances of the six columns at the left edge of the control under the sign-up avatar.
    ///
    /// The edge is *found* rather than computed: the control hugs its own label, so where it starts
    /// depends on which of the two words is in it and on the language the suite is running in. The
    /// probe walks in from the pane's margin along the control's centre row and stops at the first
    /// pixel that is not the pane, then reads 3pt inward from there — far enough to be inside the
    /// ground whichever tier is drawing it, and nowhere near the label's own ink, which starts a
    /// further 10pt in at `.small`.
    ///
    /// The pane's colour is read off the render rather than resolved from the token, so a shift
    /// `ImageRenderer` applies to the background applies to the comparison too.
    private static func pickerEdgeColumns<Hero: View>(of hero: Hero) throws -> [CGFloat] {
        let rep = try rasterize(appearance: .aqua) {
            hero
                .environment(signUpWorkspace())
                .frame(width: OnboardingLayout.contentWidth)
                .padding(.horizontal, 20)
                // What the pane it stands on sets, since the shape decides where the edge is.
                .wnButtonShape(.capsule)
                .background(WNColor.backgroundPrimary)
        }

        // The control is the lowest thing in the hero and draws about 21pt tall at `.small`, so
        // 10pt up from the bottom edge is its vertical centre — the one row where a capsule's edge
        // is a straight column of pixels rather than an antialiased curve.
        let row = rep.pixelsHigh - Int(10 * renderScale)
        let paneLuminance = try #require(rep.colorAt(x: 0, y: row)?.usingColorSpace(.sRGB))
            .brightnessComponent

        for x in 0..<(rep.pixelsWide - 6) {
            let pixel = try #require(rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB))
            guard abs(pixel.brightnessComponent - paneLuminance) > 0.02 else { continue }
            return try (x..<(x + 6)).map {
                try #require(rep.colorAt(x: $0, y: row)?.usingColorSpace(.sRGB)).brightnessComponent
            }
        }

        Issue.record("the picker control drew no edge on the row the probe reads")
        return []
    }

    /// Rasterize `SignUpAvatarView` for `workspace` and assert its ground is `expected`.
    ///
    /// The probe walks a band along the vertical centre between 12% and 25% of the width. Every
    /// point of it is inside the circle — on the centre row the disc spans the full width, so the
    /// only thing near the edge there is the chrome's 1pt ring — and the band stops short of both
    /// glyphs the disc can carry: at `signUpAvatarSize` the initial starts around 40% of the width
    /// and `person.fill`, the wider of the two, around 30%.
    private static func expectDiscGround(
        of workspace: WorkspaceState,
        appearance: NSAppearance.Name,
        is expected: NSColor,
        _ message: @autoclosure () -> String
    ) throws {
        let rep = try rasterize(appearance: appearance) {
            SignUpAvatarView(size: OnboardingLayout.signUpAvatarSize)
                .environment(workspace)
        }

        let target = try #require(expected.usingColorSpace(.sRGB))
        let row = rep.pixelsHigh / 2
        var sampled = 0

        for x in stride(from: rep.pixelsWide * 12 / 100, to: rep.pixelsWide * 25 / 100, by: 2) {
            let pixel = try #require(rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB))
            sampled += 1
            #expect(
                channelDistance(pixel, target) < 0.04,
                "\(message()) — pixel at (\(x), \(row)) is \(pixel)")
        }

        #expect(sampled > 0, "the avatar drew nothing")
    }

    // MARK: - The sign-up pane fits the window it has to fit

    /// The one thing about this pane that fails invisibly.
    ///
    /// It is the tallest of the three — an avatar, a public-profile notice, two labelled fields
    /// (one of them three lines), a reserved error line and a button, where the other two have a
    /// field or nothing —
    /// and the window it lives in can be as short as `ContentView`'s `minHeight`. The scaffold's
    /// `Spacer`s have a `minLength` floor and its `VStack` does not scroll, so a pane that grows
    /// past that height does not compress or clip: it pushes its own button off the bottom edge,
    /// on a small window, in a state nobody testing on a large one will ever see.
    ///
    /// Measured rather than added up from `OnboardingLayout`, because every number that could
    /// drift here — what a `medium14` line actually measures, what the glass button's chrome
    /// adds, how tall `.semiBold20` draws — is one the arithmetic would be guessing at.
    /// `ImageRenderer` proposes the ideal size, and the scaffold's `maxHeight: .infinity` under an
    /// ideal proposal resolves to exactly this: both `Spacer`s at their floor, which is the
    /// shortest the pane can be drawn.
    @Test func theSignUpPaneFitsTheSmallestWindow() throws {
        let height = try Self.signUpPaneHeight()
        #expect(
            height <= Self.minimumWindowHeight,
            "the sign-up pane needs \(height)pt in a window that can be \(Self.minimumWindowHeight)pt tall")
    }

    /// The same fit, in the language that makes the pane tallest rather than the one the test host
    /// happens to be running in.
    ///
    /// The public-profile notice is the pane's only multi-line block, and it is the one string here
    /// whose length is a translator's decision: its message wraps to two lines in English and to
    /// three in six of the nine languages this app ships, which is 15pt the pane does not have
    /// spare. The test above measures the host's language and would therefore pass in English while
    /// shipping a pane whose Create profile button is off the bottom edge in German.
    ///
    /// So the pane is measured once, its own notice is subtracted, and the tallest translation of
    /// that notice is put back. Nothing else on the pane can take a line it did not take before:
    /// both field labels are one line, and the error slot is reserved at a fixed height.
    ///
    /// This is the test that prices `OnboardingLayout.signUpAvatarSize`. German draws the notice
    /// on three lines and puts the pane at 614pt of the 620pt there is, so the 6pt left over is
    /// the entire budget for anything the pane grows by next.
    @Test func theSignUpPaneFitsTheSmallestWindowInEveryLanguage() throws {
        let paneHeight = try Self.signUpPaneHeight()
        let hostNotice = try Self.publicProfileNoticeHeight(
            title: L10n.string(Self.publicProfileTitleKey),
            message: L10n.string(Self.publicProfileMessageKey)
        )

        var tallest = hostNotice
        var tallestLanguage = "the host language"
        for code in Bundle.main.localizations {
            guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                let bundle = Bundle(path: path)
            else { continue }
            let height = try Self.publicProfileNoticeHeight(
                title: bundle.localizedString(
                    forKey: Self.publicProfileTitleKey, value: Self.publicProfileTitleKey, table: nil),
                message: bundle.localizedString(
                    forKey: Self.publicProfileMessageKey, value: Self.publicProfileMessageKey, table: nil)
            )
            if height > tallest {
                tallest = height
                tallestLanguage = code
            }
        }

        let worstCase = paneHeight - hostNotice + tallest
        #expect(
            worstCase <= Self.minimumWindowHeight,
            """
            the sign-up pane needs \(worstCase)pt in \(tallestLanguage), \
            in a window that can be \(Self.minimumWindowHeight)pt tall
            """)
    }

    /// The shortest the sign-up pane can be drawn — both margin `Spacer`s at their floor. See
    /// `OnboardingLayout.signUpEdgePadding`, which is what buys the notice its box.
    private static func signUpPaneHeight() throws -> CGFloat {
        let workspace = Self.signUpWorkspace()
        let pane = OnboardingSignUpView()
            .environment(workspace)
            .frame(width: Self.minimumWindowWidth)
        return try #require(ImageRenderer(content: pane).nsImage?.size.height)
    }

    /// The notice as the pane draws it, at the width the pane draws it in.
    private static func publicProfileNoticeHeight(title: String, message: String) throws -> CGFloat {
        let notice = WNCallout(title: title, message: message, intent: .info, emphasis: .quiet)
            .frame(width: OnboardingLayout.contentWidth)
        return try #require(ImageRenderer(content: notice).nsImage?.size.height)
    }

    /// The two catalog keys Settings → Profile and the sign-up pane both draw. Shared literals
    /// rather than a copy each, because the point of the notice is that they are the same strings.
    private static let publicProfileTitleKey = "Your profile is public"
    private static let publicProfileMessageKey =
        "Name, photo, and bio are visible on the global Nostr network. Use what you're comfortable sharing."

    /// The notice is gray, and stays gray.
    ///
    /// It is the same `WNCallout` Settings → Profile draws, and it would be one word — `.info`
    /// instead of `.quiet` — from arriving in this pane wearing the info tint. That would make a
    /// standing sentence about privacy the most colorful thing on a pane whose most colorful thing
    /// is meant to be Create profile, so the neutral ground is asserted rather than assumed.
    ///
    /// Sampled against a swatch rendered the same way rather than against the ramp constant:
    /// `ImageRenderer` does not always hand back the exact token it was given.
    @Test func theSignUpNoticeIsDrawnOnNeutralGround() throws {
        let quiet = try Self.noticeGround { PublicProfileNote() }
        let tinted = try Self.noticeGround {
            WNCallout(
                title: Self.publicProfileTitleKey,
                message: Self.publicProfileMessageKey,
                intent: .info
            )
        }

        let swatchRep = try Self.rasterize(appearance: .aqua) {
            WNColor.backgroundSecondary.frame(width: 40, height: 40)
        }
        let neutral = try #require(swatchRep.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))

        #expect(
            Self.channelDistance(quiet, neutral) < 0.02,
            "the notice drew its box on \(quiet) where the neutral surface is \(neutral)")
        #expect(
            Self.channelDistance(quiet, tinted) > 0.02,
            "the quiet notice and the tinted one drew the same ground, so the emphasis did nothing")
    }

    /// The color the notice's box is drawn on, sampled in the padding strip left of the glyph —
    /// the one place inside the box that no glyph or line of text can reach.
    private static func noticeGround<Notice: View>(@ViewBuilder _ notice: () -> Notice) throws -> NSColor {
        let rep = try Self.rasterize(appearance: .aqua) {
            notice().frame(width: OnboardingLayout.contentWidth)
        }
        return try #require(
            rep.colorAt(x: Int(7 * Self.renderScale), y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    /// `ContentView`'s window floor, restated so a pane measured against it fails when the pane
    /// grows rather than when someone quietly shrinks the window.
    private static let minimumWindowWidth: CGFloat = 940
    private static let minimumWindowHeight: CGFloat = 620

    /// The multi-line field's height comes out of `fieldHeight(forLineLimit:)`, which multiplies a
    /// *named* line height — a number that is right until the type ramp moves under it. Measured
    /// against what three lines of `medium14` actually draw, with the single-line case as the
    /// control: that one is pinned to `OnboardingKeyField`'s 40pt and must not be computed at all.
    @Test func aFieldIsAsTallAsTheLayoutSaysItIs() throws {
        for lineLimit in [1, OnboardingLayout.aboutFieldLineLimit] {
            let field = WNInput(
                label: "About",
                prompt: "Introduce yourself",
                text: .constant(""),
                lineLimit: lineLimit
            )
            .wnButtonShape(.capsule)
            .frame(width: OnboardingLayout.contentWidth)

            let drawn = try #require(ImageRenderer(content: field).nsImage?.size.height)
            // The label and the gap above the field are the view's, not the metric's.
            let box = drawn - Self.measuredFieldLabelBlockHeight
            let expected = OnboardingLayout.fieldHeight(forLineLimit: lineLimit)
            #expect(
                abs(box - expected) <= 1,
                "a \(lineLimit)-line field drew a \(box)pt box; the layout says \(expected)pt")
        }
    }

    /// The label plus `fieldLabelSpacing`, measured once so the field test can subtract it.
    private static var measuredFieldLabelBlockHeight: CGFloat {
        let label = Text("About")
            .wnFont(.semiBold14)
            .frame(width: OnboardingLayout.contentWidth, alignment: .leading)
        let height = ImageRenderer(content: label).nsImage?.size.height ?? 0
        return height + OnboardingLayout.fieldLabelSpacing
    }

    /// A capsule field and the rounded box under it agree on their corner. Asserted on the metric
    /// rather than on pixels because the metric is the whole mechanism: `WNInput`
    /// reads the capsule's radius from the single-line height, and the two only look like one
    /// family while that stays true.
    @Test func bothSignUpFieldsShareOneCorner() {
        #expect(
            OnboardingLayout.multilineFieldCornerRadius == OnboardingLayout.singleLineFieldHeight / 2)
    }

    // MARK: - What the sign-up draft makes of what is in it

    /// A name is the bar, and it is the same bar Flutter's `signup_create_profile_button` sets.
    /// Whitespace is not a name: without the trim, a space bar press would enable a button that
    /// publishes a profile with a blank `display_name`.
    @Test func aNameIsTheOnlyThingSignUpInsistsOn() {
        #expect(SignUpDraft().isSubmittable == false)
        #expect(SignUpDraft(displayName: "   \n\t ").isSubmittable == false)
        #expect(SignUpDraft(displayName: "Marmota").isSubmittable)
        // Everything else is optional — a name alone is enough.
        #expect(SignUpDraft(displayName: " Marmota ").trimmedDisplayName == "Marmota")
        #expect(SignUpDraft(displayName: "Marmota", about: "  ").trimmedAbout.isEmpty)
    }

    /// `SignUpProfileImage` sits in observable state that SwiftUI diffs on every keystroke in the
    /// name field, and it carries the whole image. The synthesized `Equatable` would compare those
    /// bytes; this one compares the digest. A regression is invisible — the pane still works — and
    /// costs a multi-megabyte `memcmp` per character typed.
    @Test func aStagedPhotoComparesByDigestNotByBytes() {
        let bytes = Data(repeating: 0xAB, count: 4096)
        let first = SignUpProfileImage(attachment: Self.imageAttachment(bytes))
        let second = SignUpProfileImage(attachment: Self.imageAttachment(bytes))
        let other = SignUpProfileImage(attachment: Self.imageAttachment(Data(repeating: 0xCD, count: 4096)))

        // Same bytes, different `PendingMediaAttachment` ids: equal, because the digest is equal.
        #expect(first == second)
        #expect(first != other)
        #expect(first.preview.id == second.preview.id)
    }

    private static func imageAttachment(_ data: Data) -> PendingMediaAttachment {
        PendingMediaAttachment(fileName: "avatar.png", mediaType: "image/png", data: data, dim: nil)
    }

    /// A workspace on the sign-up pane, with the fields empty — the state the pane is in when it
    /// opens, and its shortest: a name long enough to wrap would make the pane taller, and the
    /// field it wraps in is one line either way.
    @MainActor
    private static func signUpWorkspace() -> WorkspaceState {
        let workspace = WorkspaceState(
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )
        workspace.authenticationMode = .signUp
        return workspace
    }

    // MARK: - Rendering helpers

    /// Rasterize `content` in `appearance`.
    ///
    /// **Both** halves of the appearance have to be set, and this is the part that is easy to get
    /// wrong: `performAsCurrentDrawingAppearance` switches what `NSColor` dynamic providers
    /// resolve to, but a `Color(nsColor:)` inside a SwiftUI body is resolved by SwiftUI against
    /// `\.colorScheme` instead. Setting only the `NSAppearance` renders the whole palette in its
    /// light values under a dark appearance — which is exactly the "mark is invisible in dark
    /// mode" defect this suite is here to catch, so a helper that reproduced it would report the
    /// bug against every render including the correct ones.
    private static func rasterize<Content: View>(
        appearance: NSAppearance.Name,
        @ViewBuilder content: () -> Content
    ) throws -> NSBitmapImageRep {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(content: content().environment(\.colorScheme, scheme))
        renderer.scale = renderScale

        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }

        let tiff = try #require(image?.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }

    /// Luminances along a horizontal line through the vertical centre of a button drawn in the
    /// middle of a `backgroundPrimary` pane, walking from the pane's margin inwards across the
    /// button's left edge.
    ///
    /// The vertical centre is the one row where a rounded rectangle's edge is a straight vertical
    /// line, so a stroke there is a solid column of pixels rather than an antialiased curve.
    private static func edgeScanline(ringed: Bool) throws -> [CGFloat] {
        let pane = Button {
        } label: {
            OnboardingActionLabel(title: "Sign In", isLoading: false)
                .frame(minHeight: OnboardingLayout.actionLabelHeight(for: .secondary))
        }
        .buttonStyle(.wnSecondary)
        .overlay {
            if ringed { Self.ringOverlay(.rounded, for: .large) }
        }
        .controlSize(.large)
        .frame(width: 360)
        .frame(width: 400, height: 84)
        .background { MessagesTranscriptBackground() }

        let rep = try rasterize(appearance: .aqua) { pane }
        let midY = rep.pixelsHigh / 2

        // 20pt of margin each side at scale 2: the button's left edge is at pixel 40. Sample the
        // four pixels before it and the four after.
        return try (36...44).map { x in
            let pixel = try #require(rep.colorAt(x: x, y: midY)?.usingColorSpace(.sRGB))
            return pixel.brightnessComponent
        }
    }

    /// How far in from the left edge, in points, a button's ground starts 6pt below its top edge.
    ///
    /// The secondary tier is the one probed because it draws its own background and therefore its
    /// own outline — the glass primary's ground is the platform's, and `ImageRenderer` will not
    /// give it back. Rendered on nothing, so `alphaComponent` reads the shape directly; the
    /// half-alpha threshold steps over the shadow, which is faint and offset downward anyway.
    private static func leftEdgeOnset(shape: WNButtonShape) throws -> CGFloat {
        let button = OnboardingActionButton(title: "Sign In", tier: .secondary) {}
            .controlSize(.large)
            .wnButtonShape(shape)
            .frame(width: OnboardingLayout.contentWidth)

        let rep = try rasterize(appearance: .aqua) { button }
        let row = Int(6 * Self.renderScale)

        for x in 0..<rep.pixelsWide {
            guard let pixel = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { continue }
            if pixel.alphaComponent > 0.5 { return CGFloat(x) / Self.renderScale }
        }

        Issue.record("the button drew nothing on the row the probe reads")
        return .infinity
    }

    /// Everything here rasterizes at 2×, so a probe can convert pixels back to points.
    private static let renderScale: CGFloat = 2

    private static func channelDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        max(
            abs(lhs.redComponent - rhs.redComponent),
            max(
                abs(lhs.greenComponent - rhs.greenComponent),
                abs(lhs.blueComponent - rhs.blueComponent)))
    }
}
