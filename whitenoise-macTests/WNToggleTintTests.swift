//
//  WNToggleTintTests.swift
//  whitenoise-macTests
//

import AppKit
import ObjectiveC
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The switch draws its own track, with no ambient tint to lean on.
///
/// A bare `Toggle` takes its "on" track from the environment, and the app's only source of that
/// tint is `ContentView`'s `.tint(WNColor.fillPrimary)`. Settings sits under that root and drew
/// correctly; the "Help Improve White Noise" sheet is a separate presentation that inherits none
/// of it — same trap as `\.locale` — so its two switches fell back to the system accent and drew
/// **blue**, the one hue the palette reserves for links and search hits.
///
/// Every case below is deliberately given **no** tint, because that is the condition a sheet
/// actually presents under. A harness that helpfully supplied one is how the defect shipped
/// looking correct — the same note `WNPrimaryButtonTintTests` carries, for the same reason.
///
/// **Why this reads a property instead of pixels.** The obvious test — rasterize and sample the
/// track — cannot work here, and failed in three different ways before this one: `ImageRenderer`
/// does not draw a macOS switch at all (it paints a flat yellow placeholder and ignores `.tint`
/// entirely, so it can distinguish neither tinted from untinted nor Light from Dark), and
/// `NSHostingView.cacheDisplay` does draw one but only ever in its *inactive* appearance, because
/// a window in the test host never becomes key — and an inactive control deliberately drops its
/// accent for grey. Both harnesses therefore render an untinted switch and a correctly tinted one
/// as the same pixels. `NSSwitch.trackColor` is what the tint actually lands on, so it is what
/// these read.
///
/// `.serialized` and `@MainActor` because these switch `NSAppearance` to resolve colours:
/// `performAsCurrentDrawingAppearance` off the main thread takes the test host down with it.
@Suite(.serialized) @MainActor struct WNToggleTintTests {

    /// The track is `fillPrimary` — the value, resolved for the same appearance the switch was
    /// laid out in, not merely "some neutral". Near-black in Light, white in Dark.
    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func theSwitchNamesFillPrimaryWithNoAmbientTint(appearance: NSAppearance.Name) throws {
        let track = try #require(
            Self.trackColor(of: WNToggle("Anonymous Telemetry", isOn: .constant(true)), in: appearance),
            "The switch left its track to the environment — the blue-in-a-sheet defect."
        )
        let expected = try #require(Self.resolve(WNNSColor.fillPrimary, in: appearance))

        #expect(Self.distance(track, expected) < 0.01)

        // …and specifically not the system accent, which is the value an untinted switch takes
        // and is blue on a default install.
        let accent = try #require(Self.resolve(.controlAccentColor, in: appearance))
        #expect(Self.distance(track, accent) > 0.3)
    }

    /// The negative control, and the reason the test above means anything.
    ///
    /// An untinted switch reports `trackColor == nil` — it has nothing of its own and takes the
    /// accent. Without this case a `trackColor` that had quietly stopped being populated at all
    /// would read as a passing `nil` everywhere, and both tests would agree on nothing.
    @Test func anUntintedSwitchHasNoTrackColourOfItsOwn() throws {
        let bare = Self.trackColor(
            of: Toggle("Anonymous Telemetry", isOn: .constant(true)).toggleStyle(.switch),
            in: .aqua
        )
        #expect(bare == nil)
    }

    /// The glyph init is the shape settings uses, and the one the improvements sheet's pair of
    /// switches reaches the component through, so it has to be tinted identically.
    @Test func theGlyphLabelledSwitchIsTintedIdentically() throws {
        let plain = try #require(
            Self.trackColor(of: WNToggle("Audit Logging", isOn: .constant(true)), in: .aqua))
        let withGlyph = try #require(
            Self.trackColor(
                of: WNToggle("Audit Logging", systemImage: "doc.text.magnifyingglass", isOn: .constant(true)),
                in: .aqua))

        #expect(Self.distance(plain, withGlyph) < 0.01)
    }

    /// `.switch` is named by the component rather than inherited, and this is what that buys.
    ///
    /// Inside a grouped `Form` macOS already resolves the default toggle style to a switch, which
    /// is why settings looked right either way. Outside one it resolves to a **checkbox** — so
    /// without the named style a `WNToggle` would silently change shape depending on what happened
    /// to enclose it. The bare control is asserted alongside so this records the actual default
    /// rather than assuming it.
    @Test func theComponentIsASwitchEvenOutsideAForm() throws {
        let component = try #require(Self.platformView(of: WNToggle("Audit Logging", isOn: .constant(true))))
        let bare = try #require(Self.platformView(of: Toggle("Audit Logging", isOn: .constant(true))))

        #expect(String(describing: type(of: component)).contains("Switch"))
        #expect(
            String(describing: type(of: bare)).contains("Checkbox")
                || String(describing: type(of: bare)).contains("Button"))
    }

    // MARK: - Helpers

    /// Hosts `content` in `appearance`, finds the AppKit switch SwiftUI made for it, and reads the
    /// track colour the tint landed on.
    ///
    /// `trackColor` is read by key rather than by property because `NSSwitch` does not expose it
    /// in its public interface. The key's existence is checked first: `value(forKey:)` on a
    /// missing key raises an Objective-C exception, which Swift cannot catch and which would take
    /// the whole host down instead of failing one test.
    private static func trackColor(of content: some View, in appearance: NSAppearance.Name) -> NSColor? {
        guard let view = platformView(of: content, in: appearance) else { return nil }
        guard class_getProperty(type(of: view), "trackColor") != nil else {
            Issue.record("NSSwitch no longer has a `trackColor` property — this suite needs a new observable.")
            return nil
        }
        var color: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            color = (view.value(forKey: "trackColor") as? NSColor)?.usingColorSpace(.sRGB)
        }
        return color
    }

    /// The AppKit view SwiftUI backs the toggle with — a `PlatformSwitch` for a switch, a button
    /// for a checkbox. `labelsHidden` so the control is the whole frame and the walk cannot land
    /// on the label's own backing view.
    private static func platformView(
        of content: some View,
        in appearance: NSAppearance.Name = .aqua
    ) -> NSView? {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let host = NSHostingView(
            rootView: AnyView(content.labelsHidden().environment(\.colorScheme, scheme)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return leaf(of: host)
    }

    /// The deepest AppKit control under the host — SwiftUI wraps its platform views a couple of
    /// layers down, and the wrapper's own type name says nothing about which control it is.
    private static func leaf(of view: NSView) -> NSView? {
        for sub in view.subviews {
            let name = String(describing: type(of: sub))
            if name.contains("PlatformSwitch") || name.contains("Checkbox") || name.contains("NSButton") {
                return sub
            }
            if let found = leaf(of: sub) { return found }
        }
        return nil
    }

    private static func resolve(_ color: NSColor, in appearance: NSAppearance.Name) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return resolved
    }

    private static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let dr = lhs.redComponent - rhs.redComponent
        let dg = lhs.greenComponent - rhs.greenComponent
        let db = lhs.blueComponent - rhs.blueComponent
        return sqrt(dr * dr + dg * dg + db * db)
    }
}
