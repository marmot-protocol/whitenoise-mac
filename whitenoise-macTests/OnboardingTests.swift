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
    /// elevated tier at `.large`.
    @Test func bothActionTiersDrawTheSameHeight() throws {
        for tier in [OnboardingActionTier.primary, .elevated] {
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

    /// Both onboarding panes set the shape, and they set it on the *pane*. A pane that set it on
    /// one of two stacked buttons would ship a pill above a rounded rectangle.
    @Test func bothOnboardingPanesCutTheirButtonsToAPill() throws {
        let onboardingDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-mac/Views/Onboarding")

        for fileName in [
            "OnboardingWelcomeView.swift", "OnboardingSignInView.swift", "OnboardingSignUpView.swift",
        ] {
            let source = try String(
                contentsOf: onboardingDirectory.appendingPathComponent(fileName), encoding: .utf8)
            #expect(
                source.contains(".wnButtonShape(.capsule)"),
                "\(fileName) no longer asks for the prototype's pill")
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

    // MARK: - The elevated tier is lifted, not ringed

    /// The onboarding secondary is shadowed and has no outline. Both halves of that are asserted,
    /// and `WNSecondaryButtonStyle` stands in as the positive control — without it a test that
    /// merely finds no ring would pass just as happily against a button that drew nothing.
    @Test func theElevatedTierIsShadowedAndTheRingedTierIsNot() throws {
        let elevated = try Self.edgeScanline(WNElevatedButtonStyle())
        let ringed = try Self.edgeScanline(WNSecondaryButtonStyle())

        // `borderSecondary` is `neutral500`, ~0.45 luminance, against the elevated tier's resting
        // `backgroundSlate` ground at ~0.98, the ringed tier's `fillSecondary` at ~0.96, and a
        // `backgroundPrimary` pane at 1.0. Anything below 0.75 on this scanline is a stroke;
        // nothing else on it comes close.
        #expect(
            ringed.contains(where: { $0 < 0.75 }),
            "the ringed control drew no outline — this test can no longer tell the two apart")
        #expect(
            !elevated.contains(where: { $0 < 0.75 }),
            "the elevated tier drew an outline")

        // The shadow: pixels in the pane's margin, outside the button's fill, that are darker than
        // the bare pane. The ringed tier casts none, so its margin is flat.
        let paneLuminance = try #require(
            NSColor(WNColor.backgroundPrimary).usingColorSpace(.sRGB)?.brightnessComponent)
        #expect(
            elevated.contains(where: { $0 < paneLuminance - 0.02 && $0 > 0.75 }),
            "the elevated tier cast no shadow")
        #expect(
            !ringed.prefix(3).contains(where: { $0 < paneLuminance - 0.02 }),
            "the ringed tier is casting a shadow it should not have")
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

    // MARK: - The sign-up pane fits the window it has to fit

    /// The one thing about this pane that fails invisibly.
    ///
    /// It is the tallest of the three — an avatar, a title, two labelled fields (one of them three
    /// lines), a reserved error line and a button, where the other two have a field or nothing —
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
        let workspace = Self.signUpWorkspace()
        let pane = OnboardingSignUpView()
            .environment(workspace)
            .frame(width: Self.minimumWindowWidth)

        let height = try #require(ImageRenderer(content: pane).nsImage?.size.height)
        #expect(
            height <= Self.minimumWindowHeight,
            "the sign-up pane needs \(height)pt in a window that can be \(Self.minimumWindowHeight)pt tall")
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
            let field = OnboardingFormField(
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
    /// rather than on pixels because the metric is the whole mechanism: `OnboardingFormField`
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
    private static func edgeScanline<Style: ButtonStyle>(_ style: Style) throws -> [CGFloat] {
        let pane = Button {
        } label: {
            OnboardingActionLabel(title: "Sign In", isLoading: false)
                .frame(minHeight: OnboardingLayout.actionLabelHeight(for: .elevated))
        }
        .buttonStyle(style)
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
    /// The elevated tier is the one probed because it draws its own background and therefore its
    /// own outline — the glass primary's ground is the platform's, and `ImageRenderer` will not
    /// give it back. Rendered on nothing, so `alphaComponent` reads the shape directly; the
    /// half-alpha threshold steps over the shadow, which is faint and offset downward anyway.
    private static func leftEdgeOnset(shape: WNButtonShape) throws -> CGFloat {
        let button = OnboardingActionButton(title: "Sign In", tier: .elevated) {}
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
