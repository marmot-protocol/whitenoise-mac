import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// A reply carrying images draws as one bubble — the quote on top, the media under it — rather than
/// a detached media card above a bubble holding only the quote. Rasterized, since the test host
/// builds no accessibility tree.
///
/// `.serialized` and `@MainActor` because rasterizing switches `NSAppearance`, which off the main
/// thread takes the test host down.
@Suite(.serialized) @MainActor struct ReplyMediaBubbleRenderTests {
    @Test func onlyAReplyWithVisualMediaEmbedsIt() {
        #expect(MessageReplyMediaLayout.embedsVisualMedia(hasReply: true, visualMediaCount: 1))
        #expect(MessageReplyMediaLayout.embedsVisualMedia(hasReply: true, visualMediaCount: 4))
        #expect(!MessageReplyMediaLayout.embedsVisualMedia(hasReply: false, visualMediaCount: 1))
        #expect(!MessageReplyMediaLayout.embedsVisualMedia(hasReply: true, visualMediaCount: 0))
    }

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func aReplyWithAnImageWrapsTheImageInItsBubble(appearance: NSAppearance.Name) throws {
        let rep = try Self.rasterize(Self.row(Self.message(reply: true)), in: appearance)
        let swatch = try Self.rasterize(
            Rectangle().fill(MessagesPalette.bubbleFill(isOutgoing: true)).frame(width: 8, height: 8),
            in: appearance
        )
        let fill = try #require(swatch.colorAt(x: 8, y: 8)?.usingColorSpace(.sRGB))

        // The outgoing bubble's trailing edge sits at the row's trailing padding; this column is
        // inside the bubble's inset strip, beside the media. Detached, the media card fills it with
        // its own pixels and the bubble's fill covers only the short quote.
        let column = Int((Self.rowWidth - Self.rowPadding - MessageReplyMediaLayout.outerInset / 2) * Self.scale)
        let run = Self.longestRun(of: fill, inColumn: column, of: rep)
        let gridHeight = MessageMediaGridPresentation.gridHeight(
            totalCount: 1, maxWidth: MessageVisualMediaGrid.width, spacing: 3)

        #expect(CGFloat(run) > gridHeight * Self.scale)
    }

    @Test func aPlainImageStaysOutOfABubble() throws {
        let rep = try Self.rasterize(Self.row(Self.message(reply: false)), in: .aqua)
        let swatch = try Self.rasterize(
            Rectangle().fill(MessagesPalette.bubbleFill(isOutgoing: true)).frame(width: 8, height: 8),
            in: .aqua
        )
        let fill = try #require(swatch.colorAt(x: 8, y: 8)?.usingColorSpace(.sRGB))
        let column = Int((Self.rowWidth - Self.rowPadding - MessageReplyMediaLayout.outerInset / 2) * Self.scale)

        // The negative control: without a reply there is no bubble around the media to find.
        #expect(Self.longestRun(of: fill, inColumn: column, of: rep) < Int(40 * Self.scale))
    }

    // MARK: - Helpers

    private static let scale: CGFloat = 2
    private static let rowWidth: CGFloat = 760
    private static let rowPadding: CGFloat = 28

    private static func message(reply: Bool) -> MessageItem {
        MessageItem(
            id: "reply-with-image",
            senderName: "Me",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: true,
            replyContext: reply
                ? MessageReplyContext(targetMessageId: "parent", senderName: "Alice", body: "Hi")
                : nil,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "image",
                    reference: mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
                )
            ]
        )
    }

    private static func row(_ message: MessageItem) -> some View {
        TranscriptPerformanceRows(messages: [message])
            .background(WNColor.backgroundPrimary)
            .environment(WorkspaceState.preview())
    }

    /// The longest vertical run of pixels within a hair of `color` in one pixel column.
    private static func longestRun(of color: NSColor, inColumn x: Int, of rep: NSBitmapImageRep) -> Int {
        var longest = 0
        var current = 0
        for y in 0..<rep.pixelsHigh {
            guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let matches =
                abs(pixel.redComponent - color.redComponent) < 0.02
                && abs(pixel.greenComponent - color.greenComponent) < 0.02
                && abs(pixel.blueComponent - color.blueComponent) < 0.02
            current = matches ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
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
