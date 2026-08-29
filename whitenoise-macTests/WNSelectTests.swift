//
//  WNSelectTests.swift
//  whitenoise-macTests
//

import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The chosen option is the one that stays dark, and the only one wearing a checkmark.
///
/// This is the whole reason `WNSelect` exists rather than a `Picker(.inline)`: the same picker
/// that draws checkmark rows on iOS draws a column of radio buttons on macOS, so the shape
/// `wn-ios-prototype` specifies had to be written out. These read the two halves of that shape —
/// the contrast between chosen and unchosen, and the mark itself — because either one alone can
/// regress without the other noticing. A row that lost its checkmark still has the right colours;
/// a row that lost the colour split still has a checkmark.
///
/// Rendered without a `Form` around them. A grouped `Form` is what settings puts these in, but
/// `cacheDisplay` draws one empty and `ImageRenderer` draws nothing at all for it, so the row is
/// rasterized on its own — which is also the honest unit here, since the colours are the row's
/// and not the form's.
///
/// `.serialized` and `@MainActor` because these switch `NSAppearance` to rasterize:
/// `performAsCurrentDrawingAppearance` off the main thread takes the test host down with it.
@Suite(.serialized) @MainActor struct WNSelectTests {

    /// The unchosen options are set back. Not "a different colour" — *lighter*, in both
    /// appearances, which is what makes the chosen line findable by scanning.
    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func theUnchosenOptionsAreSetBackFromTheChosenOne(appearance: NSAppearance.Name) throws {
        let chosen = try Self.titleContrast(isSelected: true, in: appearance)
        let unchosen = try Self.titleContrast(isSelected: false, in: appearance)

        // Contrast against the row's own ground, so this reads the same way in both appearances:
        // near-black on white in Light, white on near-black in Dark.
        #expect(chosen > unchosen + 0.15)
    }

    /// The mark, and the negative control that gives it meaning: an unchosen row's trailing edge
    /// is empty. Without the second half a checkmark drawn on *every* row would pass.
    @Test func onlyTheChosenOptionDrawsACheckmark() throws {
        #expect(try Self.trailingInk(isSelected: true, in: .aqua) > 0.3)
        #expect(try Self.trailingInk(isSelected: false, in: .aqua) < 0.02)
    }

    /// A disabled group takes the selection down with it. The row names its own colours, which
    /// costs the dimming a `.plain` button would otherwise inherit — so it has to reproduce it,
    /// or a switched-off group would go on advertising its choice at full strength.
    @Test func aDisabledRowSetsItsChosenOptionBackToo() throws {
        let enabled = try Self.titleContrast(isSelected: true, in: .aqua)
        let disabled = try Self.titleContrast(isSelected: true, in: .aqua, isEnabled: false)

        #expect(disabled < enabled - 0.15)
    }

    // MARK: - Helpers

    /// How far the darkest pixel of the label sits from the row's ground, 0 (invisible) to 1.
    private static func titleContrast(
        isSelected: Bool,
        in appearance: NSAppearance.Name,
        isEnabled: Bool = true
    ) throws -> CGFloat {
        let rep = try rasterize(isSelected: isSelected, in: appearance, isEnabled: isEnabled)
        let ground = try #require(rep.colorAt(x: rep.pixelsWide - 2, y: 2)?.usingColorSpace(.sRGB))
        return try extreme(in: rep, ground: ground, columns: 0..<(rep.pixelsWide / 2))
    }

    /// The same measure taken over the trailing quarter, which holds the checkmark or nothing.
    private static func trailingInk(isSelected: Bool, in appearance: NSAppearance.Name) throws -> CGFloat {
        let rep = try rasterize(isSelected: isSelected, in: appearance, isEnabled: true)
        let ground = try #require(rep.colorAt(x: rep.pixelsWide - 2, y: 2)?.usingColorSpace(.sRGB))
        let start = rep.pixelsWide - rep.pixelsWide / 4
        return try extreme(in: rep, ground: ground, columns: start..<rep.pixelsWide)
    }

    private static func extreme(
        in rep: NSBitmapImageRep,
        ground: NSColor,
        columns: Range<Int>
    ) throws -> CGFloat {
        var furthest: CGFloat = 0
        for x in columns {
            for y in 0..<rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                furthest = max(furthest, abs(pixel.brightnessComponent - ground.brightnessComponent))
            }
        }
        return furthest
    }

    private static func rasterize(
        isSelected: Bool,
        in appearance: NSAppearance.Name,
        isEnabled: Bool
    ) throws -> NSBitmapImageRep {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(
            content: WNSelectRow(title: "Sender only", isSelected: isSelected) {}
                .disabled(!isEnabled)
                .padding(8)
                .frame(width: 240)
                .background(WNColor.backgroundPrimary)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2

        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        let tiff = try #require(image?.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }
}
