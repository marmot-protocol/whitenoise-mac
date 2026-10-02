import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// A reply carrying an image draws the quote, the media and the caption on one bubble, as iOS does,
/// instead of floating the grid above a bubble holding only the quote. Rasterized rather than
/// inspected: the test host builds no accessibility tree.
///
/// `.serialized` and `@MainActor` because these switch `NSAppearance` to rasterize:
/// `performAsCurrentDrawingAppearance` off the main thread takes the test host down with it.
@Suite(.serialized) @MainActor struct ReplyMediaBubbleRenderTests {
    private static let scale: CGFloat = 2

    private static let reply = MessageReplyContext(
        targetMessageId: "parent",
        senderName: "Alice",
        body: "Look at the view from the hotel"
    )

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func aReplysImageSitsOnTheSameSurfaceAsItsQuote(appearance: NSAppearance.Name) throws {
        let rep = try Self.rasterize(Self.message(body: "", isOutgoing: false), in: appearance)

        // Stacked separately, the tallest unbroken surface was the 360pt grid itself, with the
        // row spacing showing through between it and the quote's bubble. On one surface the rim
        // runs on past the grid through the quote card and the footer.
        let tallest = Double(try Self.tallestSurfaceRun(in: rep)) / Self.scale
        #expect(tallest > MessageVisualMediaGrid.width + 40)
    }

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func aLongCaptionWrapsUnderTheImageInsteadOfWideningTheBubble(appearance: NSAppearance.Name) throws {
        let caption = "Here is mine, taken this morning before breakfast out on the balcony upstairs"
        let rep = try Self.rasterize(Self.message(body: caption, isOutgoing: true), in: appearance)

        // The grid plus the 6pt rim on each side; the caption wraps to fit inside it.
        let widest = Double(try Self.widestSurfaceRun(in: rep)) / Self.scale
        let bubbleWidth = MessageVisualMediaGrid.width + 2 * MessageReplyMediaBubbleLayout.outerInset
        #expect(widest > MessageVisualMediaGrid.width)
        #expect(widest <= bubbleWidth + 1)
    }

    // MARK: - Helpers

    private static func message(body: String, isOutgoing: Bool) -> some View {
        let image = MessageMediaAttachment(
            id: "image",
            reference: mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        )
        let message = MessageItem(
            id: "reply-with-image",
            senderName: isOutgoing ? "Me" : "Bob",
            body: body,
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: isOutgoing,
            replyContext: reply,
            mediaAttachments: [image]
        )
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        return TranscriptPerformanceRows(messages: [message])
            .environment(state)
            .background(WNColor.backgroundPrimary)
    }

    /// The longest vertical run of non-ground pixels in any column.
    private static func tallestSurfaceRun(in rep: NSBitmapImageRep) throws -> Int {
        let ground = try groundColor(of: rep)
        var tallest = 0
        for x in 0..<rep.pixelsWide {
            var run = 0
            for y in 0..<rep.pixelsHigh {
                run = isGround(rep, x: x, y: y, ground: ground) ? 0 : run + 1
                tallest = max(tallest, run)
            }
        }
        return tallest
    }

    /// The longest horizontal run of non-ground pixels in any row.
    private static func widestSurfaceRun(in rep: NSBitmapImageRep) throws -> Int {
        let ground = try groundColor(of: rep)
        var widest = 0
        for y in 0..<rep.pixelsHigh {
            var run = 0
            for x in 0..<rep.pixelsWide {
                run = isGround(rep, x: x, y: y, ground: ground) ? 0 : run + 1
                widest = max(widest, run)
            }
        }
        return widest
    }

    private static func groundColor(of rep: NSBitmapImageRep) throws -> NSColor {
        try #require(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
    }

    /// The incoming bubble is one ramp step off the ground in Light, so this compares channels
    /// rather than brightness against a coarse threshold.
    private static func isGround(_ rep: NSBitmapImageRep, x: Int, y: Int, ground: NSColor) -> Bool {
        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return true }
        let distance =
            abs(pixel.redComponent - ground.redComponent)
            + abs(pixel.greenComponent - ground.greenComponent)
            + abs(pixel.blueComponent - ground.blueComponent)
        return distance < 0.03
    }

    private static func rasterize(_ view: some View, in appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = scale

        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        let tiff = try #require(image?.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }
}
