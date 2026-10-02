import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The link cursor hangs on the rects `MessageLinkRegionRecorder` reads out of the text layout,
/// so these draw a linked text for real and hit-test what it recorded. The cursor itself is not
/// asserted: the test host is never the frontmost app, so it owns no cursor to read back.
@Suite @MainActor struct MessageLinkTextTests {
    private static let link = URL(string: "https://marmot.build")!

    private static func text(_ parts: [(String, URL?)]) -> AttributedString {
        parts.reduce(into: AttributedString()) { result, part in
            var run = AttributedString(part.0)
            run.link = part.1
            result.append(run)
        }
    }

    /// Draws `text` the way `MessageLinkText` does, recording into `regions` under `layoutID`.
    @discardableResult
    private static func render(
        _ text: AttributedString,
        width: CGFloat = 400,
        layoutID: String = "text",
        into regions: MessageLinkRegions = MessageLinkRegions()
    ) -> MessageLinkRegions {
        let view = Text.markingLinks(text)
            .textRenderer(MessageLinkRegionRecorder(layoutID: layoutID, regions: regions))
            .font(.system(size: 16))
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.nsImage
        return regions
    }

    @Test func theLinkIsHitAndThePlainTextAroundItIsNot() throws {
        let text = Self.text([("Read the spec at ", nil), ("marmot.build", Self.link), (" before Friday", nil)])
        let regions = Self.render(text)
        let rects = regions.linkRects(layoutID: "text")
        try #require(rects.count == 1)
        let link = rects[0]

        // Plain text on both sides of the link, on its line: the prefix and the closing words
        // are each far wider than the 4pt step taken off the link's edge.
        #expect(link.minX > 8)
        #expect(regions.containsLink(at: CGPoint(x: link.midX, y: link.midY), layoutID: "text"))
        #expect(!regions.containsLink(at: CGPoint(x: link.minX - 4, y: link.midY), layoutID: "text"))
        #expect(!regions.containsLink(at: CGPoint(x: link.maxX + 4, y: link.midY), layoutID: "text"))
    }

    @Test func aLinkThatWrapsIsHitOnBothLines() throws {
        let text = Self.text([
            ("Look ", nil),
            ("https://marmot.build/a/rather/long/path/that/cannot/fit/on/one/line", Self.link),
        ])
        let regions = Self.render(text, width: 200)
        let rects = regions.linkRects(layoutID: "text")
        try #require(rects.count >= 2)

        // One rect per line, the second below the first, and each one hit.
        #expect(rects[1].minY >= rects[0].maxY - 1)
        for rect in rects {
            #expect(regions.containsLink(at: CGPoint(x: rect.midX, y: rect.midY), layoutID: "text"))
        }
        // "Look " ahead of the link on the first line is not.
        #expect(!regions.containsLink(at: CGPoint(x: rects[0].minX - 4, y: rects[0].midY), layoutID: "text"))
    }

    /// The same linked words laid out at two widths keep their own rects: a heading and a list
    /// item can say the same thing and still put the link in different places.
    @Test func equalTextsInDifferentLayoutsKeepTheirOwnRects() throws {
        let text = Self.text([("A fairly long lead-in before the ", nil), ("marmot.build", Self.link)])
        let regions = MessageLinkRegions()
        Self.render(text, width: 400, layoutID: "wide", into: regions)
        Self.render(text, width: 150, layoutID: "narrow", into: regions)
        let wide = try #require(regions.linkRects(layoutID: "wide").first)
        let narrow = try #require(regions.linkRects(layoutID: "narrow").first)

        #expect(wide != narrow)
        #expect(regions.containsLink(at: CGPoint(x: wide.midX, y: wide.midY), layoutID: "wide"))
        #expect(!regions.containsLink(at: CGPoint(x: wide.midX, y: wide.midY), layoutID: "narrow"))
    }

    @Test func aTextWithNothingRecordedHitsNothing() {
        #expect(!MessageLinkRegions().containsLink(at: .zero, layoutID: "text"))
    }

    private static func pixels(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(
            content: view.font(.system(size: 16)).frame(width: 400, alignment: .leading)
        )
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// The recorder only reads the layout; a bubble with a link draws the glyphs the plain `Text`
    /// it replaced drew, pixel for pixel. Not an underlined link: any `TextRenderer` at all — even
    /// one that draws each line untouched — puts SwiftUI's underline 1pt lower than the default
    /// path does, same thickness and color.
    @Test func theRecorderDrawsTheTextUnchanged() throws {
        let text = Self.text([("Read the spec at ", nil), ("marmot.build", Self.link), (" before Friday", nil)])
        #expect(try Self.pixels(MessageLinkText(text: text, layoutID: "text")) == Self.pixels(Text(text)))
    }

    /// The bubble's metadata spacer still follows the text, on both the linked and plain paths.
    @Test(arguments: [true, false])
    func theTrailingTextIsAppended(linked: Bool) throws {
        let text = Self.text([("Read the spec at ", nil), ("marmot.build", linked ? Self.link : nil)])
        let trailing = Text(verbatim: " 12:34")
        let drawn = try Self.pixels(MessageLinkText(text: text, layoutID: "text", trailing: trailing))

        #expect(try drawn == Self.pixels(Text(text) + trailing))
        #expect(try drawn != Self.pixels(Text(text)))
    }

    /// The real view records into the bubble's shared regions under its own `layoutID` — the
    /// store that outlives the bubble's selection gate — and not into a private one.
    @Test func theViewRecordsIntoTheBubblesSharedRegions() throws {
        let regions = MessageLinkRegions()
        _ = try Self.pixels(
            MessageLinkText(text: MessageLinkText.sample, layoutID: "0.l1.0")
                .environment(\.messageLinkRegions, regions)
        )
        let link = try #require(regions.linkRects(layoutID: "0.l1.0").first)

        #expect(regions.linkRects(layoutID: "0").isEmpty)
        #expect(
            MessageLinkText.isOverLink(
                .active(CGPoint(x: link.midX, y: link.midY)), in: regions, layoutID: "0.l1.0"))
        #expect(
            !MessageLinkText.isOverLink(
                .active(CGPoint(x: link.minX - 4, y: link.midY)), in: regions, layoutID: "0.l1.0"))
        #expect(!MessageLinkText.isOverLink(.ended, in: regions, layoutID: "0.l1.0"))
    }

    /// Entering a link pushes the hand once however many hover updates follow, leaving pops it
    /// once, and an update off a link never pops a cursor this view did not push.
    @Test func theCursorIsPushedAndPoppedInPairs() {
        var cursor = MessageLinkCursor()
        var pushes = 0
        var pops = 0
        func sync(_ isOverLink: Bool) {
            cursor.sync(isOverLink: isOverLink, push: { pushes += 1 }, pop: { pops += 1 })
        }

        sync(false)
        #expect(pushes == 0 && pops == 0)

        sync(true)
        sync(true)
        sync(true)
        #expect(pushes == 1 && pops == 0)
        #expect(cursor.hasPushed)

        sync(false)
        sync(false)
        #expect(pushes == 1 && pops == 1)
        #expect(!cursor.hasPushed)

        sync(true)
        #expect(pushes == 2 && pops == 1)
    }

    @Test func onlyTextWithALinkTakesTheTrackedPath() {
        #expect(Self.text([("hello ", nil), ("there", Self.link)]).containsLink)
        #expect(!Self.text([("hello there", nil)]).containsLink)
    }
}
