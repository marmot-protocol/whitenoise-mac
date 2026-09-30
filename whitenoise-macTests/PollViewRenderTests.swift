import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// A poll card lands on its author's side of the transcript, like a bubble does, and the composer
/// sheet draws. Rasterized rather than inspected: the test host builds no accessibility tree.
///
/// `.serialized` and `@MainActor` because these switch `NSAppearance` to rasterize:
/// `performAsCurrentDrawingAppearance` off the main thread takes the test host down with it.
@Suite(.serialized) @MainActor struct PollViewRenderTests {
    private static let rowWidth: CGFloat = 640

    private static let poll = MessagePoll(
        question: "Lunch on Friday?",
        options: [
            .init(id: "0", label: "Tacos", votes: 2),
            .init(id: "1", label: "Ramen", votes: 1),
        ],
        kind: .singleChoice,
        participants: 3,
        localSelection: ["0"],
        endsAt: 4_000_000_000,
        isOpen: true
    )

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func anOutgoingPollSitsRightAndAnIncomingOneLeft(appearance: NSAppearance.Name) throws {
        let outgoing = try Self.inkSpan(of: Self.row(isOutgoing: true), in: appearance)
        let incoming = try Self.inkSpan(of: Self.row(isOutgoing: false), in: appearance)

        // The 72pt gutter sits opposite the author, so each card starts or ends on its own edge.
        #expect(outgoing.lowerBound > 0.5)
        #expect(outgoing.upperBound > 0.95)
        #expect(incoming.lowerBound < 0.05)
        #expect(incoming.upperBound < 0.5)
    }

    @Test func theComposerSheetDraws() throws {
        let rep = try Self.rasterize(
            PollComposerSheet(onSend: { _ in }, onCancel: {}).background(WNColor.backgroundPrimary),
            in: .aqua
        )
        #expect(rep.pixelsWide > 0)
        #expect(rep.pixelsHigh > 0)
    }

    @Test func anOpenPollWithADeadlineSaysWhenItEnds() {
        let footer = PollFooter.text(poll: Self.poll, isOpen: true)
        #expect(footer.hasPrefix(L10n.plural("%lld votes", Int64(3))))
        #expect(footer != L10n.plural("%lld votes", Int64(3)))
        #expect(PollFooter.text(poll: Self.poll, isOpen: false).contains(L10n.string("Final results")))
    }

    // MARK: - Helpers

    private static func row(isOutgoing: Bool) -> some View {
        PollMessageRow(
            poll: poll,
            isOutgoing: isOutgoing,
            senderName: isOutgoing ? nil : "Alice",
            timeLabel: "12:04",
            onVote: { _ in }
        )
        .frame(width: rowWidth)
        .background(WNColor.backgroundPrimary)
    }

    /// The horizontal extent of everything that is not the ground, as fractions of the width.
    private static func inkSpan(of view: some View, in appearance: NSAppearance.Name) throws -> ClosedRange<Double> {
        let rep = try rasterize(view, in: appearance)
        let ground = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: 1)?.usingColorSpace(.sRGB))
        var columns: [Int] = []
        for x in 0..<rep.pixelsWide {
            let inked = (0..<rep.pixelsHigh).contains { y in
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return abs(pixel.brightnessComponent - ground.brightnessComponent) > 0.08
            }
            if inked { columns.append(x) }
        }
        let first = try #require(columns.first)
        let last = try #require(columns.last)
        let width = Double(rep.pixelsWide)
        return Double(first) / width...Double(last + 1) / width
    }

    private static func rasterize(_ view: some View, in appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2

        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        let tiff = try #require(image?.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }
}
