//
//  SettingsProfileTests.swift
//  whitenoise-macTests
//
//  What Settings → Profile's Cancel/Save pair draws, measured rather than assumed.
//

import SwiftUI
import Testing

@testable import whitenoise_mac

@Suite(.serialized) @MainActor struct SettingsProfileTests {
    /// Cancel and Save are meant to be one button twice. They are drawn by two different styles,
    /// though, and a style ignores a proposed height — so the only way the pair stays matched is a
    /// per-tier minimum on the label, and the only way those numbers stay right is measuring them.
    ///
    /// This fails if either tier's interior padding moves under us, which is the whole point: the
    /// numbers live in `WNPrimaryButtonSize` and `WNSecondaryButtonStyle` and are free to change.
    @Test func bothProfileActionsDrawTheSameHeight() throws {
        let secondary = try Self.drawnSize(Self.cancelButton).height
        let primary = try Self.drawnSize(Self.saveButton).height

        #expect(
            abs(secondary - primary) <= 1,
            """
            the action pair drew two heights: .wnSecondary \(secondary)pt, \
            primary \(primary)pt. Move `ProfileActionMetrics.secondaryChromeHeight` or \
            `primaryChromeHeight` by the difference.
            """)
    }

    /// And the height they agree on is the one the page asks for. `ProfileActionMetrics.height` is
    /// `OnboardingLayout.actionHeight` by reference — the sign-up pane's CTA publishes the same
    /// record this page's Save republishes — so a chrome table that drifts has to show up here and
    /// not just as "the two still match each other".
    @Test func theActionsDrawTheHeightTheMetricsClaim() throws {
        // Measured one at a time rather than over a list: each `some View` above is its own
        // opaque type, so an array of them has no single `Element` to be.
        try expectClaimedHeight(of: Self.cancelButton, named: "Cancel")
        try expectClaimedHeight(of: Self.saveButton, named: "Save")
    }

    private func expectClaimedHeight(of button: some View, named name: String) throws {
        let drawn = try Self.drawnSize(button).height

        #expect(
            abs(drawn - ProfileActionMetrics.height) <= 1,
            "\(name) drew \(drawn)pt of the \(ProfileActionMetrics.height)pt claimed")
    }

    /// The actions fill the form column rather than hugging their words, which is what makes Cancel
    /// and Save read as one pair rather than as two buttons that happen to sit together.
    /// `.frame(maxWidth: .infinity)` fills whatever is proposed, so proposing a width is the way to
    /// ask.
    @Test func theActionsFillTheWidthTheyAreOffered() throws {
        let offered: CGFloat = 240
        let cancel = try Self.drawnSize(Self.cancelButton.frame(width: offered)).width
        let save = try Self.drawnSize(Self.saveButton.frame(width: offered)).width

        #expect(abs(cancel - offered) <= 1, "Cancel drew \(cancel)pt of the \(offered)pt offered")
        #expect(abs(save - offered) <= 1, "Save drew \(save)pt of the \(offered)pt offered")
    }

    private static var cancelButton: some View {
        Button {
        } label: {
            ProfileActionLabel(title: "Cancel", tier: .secondary)
        }
        .buttonStyle(.wnSecondary)
    }

    private static var saveButton: some View {
        Button {
        } label: {
            ProfileActionLabel(title: "Save", tier: .primary)
        }
        .wnPrimaryButtonStyle()
    }

    /// Rendered at the app's own tint and at the control size the page names, because both change
    /// what is drawn: `.glassProminent` carries no colour and falls back to the system accent
    /// without a tint — see `WNPrimaryButton` — and `wnPrimaryButtonStyle()` reads `\.controlSize`
    /// from outside itself, which is why `ProfileEditingActions` sets it on the stack.
    private static func drawnSize<Content: View>(_ content: Content) throws -> CGSize {
        let renderer = ImageRenderer(
            content:
                content
                .controlSize(.large)
                .wnButtonShape(.capsule)
                .tint(WNColor.fillPrimary)
        )
        renderer.scale = 2
        return try #require(renderer.nsImage?.size)
    }
}
