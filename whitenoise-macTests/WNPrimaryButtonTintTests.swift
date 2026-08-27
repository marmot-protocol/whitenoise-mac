//
//  WNPrimaryButtonTintTests.swift
//  whitenoise-macTests
//

import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The primary tier draws its own ground, with no ambient tint to lean on.
///
/// `.glassProminent` carries no colour and tints from the environment. The app's only source of
/// that tint is `ContentView`'s `.tint(WNColor.fillPrimary)`, and a sheet is a separate
/// presentation that inherits none of it — so a primary button inside one used to fall back to the
/// system accent and draw **blue**, the one hue the palette reserves for links and search hits.
///
/// Every render below is deliberately given **no** tint, because that is the condition a sheet
/// actually presents under. A harness that helpfully supplied one is how the defect shipped
/// looking correct.
///
/// `.serialized` and `@MainActor` because these switch `NSAppearance` to rasterize:
/// `performAsCurrentDrawingAppearance` off the main thread takes the test host down with it.
@Suite(.serialized) @MainActor struct WNPrimaryButtonTintTests {

    /// Asserted as **neutral, not a hue** rather than against a colour constant. Glass composites
    /// over its backing, so the Light pill lands on charcoal rather than `neutral950` and an
    /// equality check against either the ramp or an opaque swatch fails for reasons that have
    /// nothing to do with the tint. What actually separates right from wrong here is chroma:
    /// every value `fillPrimary` resolves to is a neutral, and the accent it used to fall back to
    /// is saturated blue.
    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func theGlassPrimaryDrawsFillPrimaryWithNoAmbientTint(appearance: NSAppearance.Name) throws {
        let fill = try Self.fillOfButton(appearance: appearance) {
            WNPrimaryButton(size: .large) {
                // Nothing to do: these tests measure the chrome, never the action.
            } label: {
                Text("Done").frame(minWidth: 96)
            }
            .wnButtonShape(.capsule)
        }

        #expect(Self.chroma(fill) < 0.06)

        // The specific regression: an untinted `.glassProminent` falls back to the control accent,
        // which on a default install is blue — the one hue this palette reserves for links.
        let accent = try #require(NSColor.controlAccentColor.usingColorSpace(.sRGB))
        #expect(Self.chroma(accent) > 0.2)
        #expect(Self.distance(fill, accent) > 0.3)

        // …and on the correct side of the ramp for the appearance: near-black in Light, white in
        // Dark. A neutral alone would still pass if the tier inverted.
        if appearance == .darkAqua {
            #expect(fill.brightnessComponent > 0.7)
        } else {
            #expect(fill.brightnessComponent < 0.4)
        }
    }

    /// `.wnPrimaryButtonStyle()` is the other route to the same tier — it is what
    /// `OnboardingActionButton` and the invite actions use — so it has to be tinted too.
    @Test func theStyleModifierRouteAlsoDrawsFillPrimary() throws {
        let fill = try Self.fillOfButton(appearance: .aqua) {
            Button {
            } label: {
                Text("Done").frame(minWidth: 96).padding(8)
            }
            .wnPrimaryButtonStyle()
            .controlSize(.large)
        }

        #expect(Self.chroma(fill) < 0.06)
        #expect(fill.brightnessComponent < 0.4)
    }

    // MARK: - Helpers

    /// Rasterizes `content` on a `backgroundPrimary` ground and samples its *fill*.
    ///
    /// Two things this gets right that the obvious version does not. The ground matters: with
    /// nothing behind it the glass composites to transparent and every sample reads
    /// `rgba(0,0,0,0)`, which looks like a passing black. And the sample is taken at 18% of the
    /// width, not the centre — a centred label puts its own glyph under the middle pixel, so
    /// sampling there measures the *text* colour and reports the fill as its near-opposite.
    private static func fillOfButton<Content: View>(
        appearance: NSAppearance.Name,
        @ViewBuilder content: () -> Content
    ) throws -> NSColor {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(
            content: content()
                .padding(8)
                .background(WNColor.backgroundPrimary)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2

        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        let tiff = try #require(image?.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let pixel = try #require(
            rep.colorAt(x: Int(Double(rep.pixelsWide) * 0.18), y: rep.pixelsHigh / 2)?
                .usingColorSpace(.sRGB)
        )
        // A transparent sample means the glass never drew; assert rather than compare against it.
        #expect(pixel.alphaComponent > 0.99)
        return pixel
    }

    /// How far the three channels spread — 0 for any neutral, large for a saturated hue.
    private static func chroma(_ color: NSColor) -> CGFloat {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        guard let low = channels.min(), let high = channels.max() else { return 0 }
        return high - low
    }

    private static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let dr = lhs.redComponent - rhs.redComponent
        let dg = lhs.greenComponent - rhs.greenComponent
        let db = lhs.blueComponent - rhs.blueComponent
        return sqrt(dr * dr + dg * dg + db * db)
    }
}
