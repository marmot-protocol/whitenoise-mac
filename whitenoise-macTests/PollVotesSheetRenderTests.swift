import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The "View votes" entry point and sheet draw in every state the model can be in. Rasterized
/// rather than inspected, as `PollViewRenderTests` is: the test host builds no accessibility tree.
///
/// `.serialized` and `@MainActor` because rasterizing switches `NSAppearance`, which off the main
/// thread takes the test host down.
@Suite(.serialized) @MainActor struct PollVotesSheetRenderTests {
    private static let alice = String(repeating: "a", count: 64)
    private static let bob = String(repeating: "b", count: 64)
    private static let carol = String(repeating: "c", count: 64)

    private static let poll = MessagePoll(
        question: "Where should we have lunch on Friday?",
        options: [
            .init(id: "0", label: "Tacos", votes: 2),
            .init(id: "1", label: "Ramen", votes: 2),
            .init(id: "2", label: "Pizza", votes: 0),
        ],
        kind: .multipleChoice,
        participants: 3,
        localSelection: ["0"],
        endsAt: nil,
        isOpen: true
    )

    private static let page = PollVotePageFfi(
        votes: [
            PollVoteFfi(voterAccountIdHex: alice, optionIds: ["0"], votedAt: 1_760_000_000),
            PollVoteFfi(voterAccountIdHex: bob, optionIds: ["0", "1"], votedAt: 1_760_000_100),
            PollVoteFfi(voterAccountIdHex: carol, optionIds: ["1"], votedAt: 1_760_000_200),
        ],
        hasMoreAfter: true
    )

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func aPollWithVotesOffersTheVoterList(appearance: NSAppearance.Name) throws {
        let withVotes = try Self.rasterize(Self.card(onViewVotes: {}), in: appearance)
        let without = try Self.rasterize(Self.card(onViewVotes: nil), in: appearance)

        // The "View votes" row is extra height on the card, and only when there is somewhere to go.
        #expect(withVotes.pixelsHigh > without.pixelsHigh)
    }

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func loadedVotesDrawUnderTheirOptionsWithTheBlockedVoterMarked(appearance: NSAppearance.Name) async throws {
        let model = PollVotesViewModel(pollEventId: "poll", poll: Self.poll) { _, _ in Self.page }
        await model.reload().value
        let empty = PollVotesViewModel(pollEventId: "poll", poll: Self.poll) { _, _ in
            PollVotePageFfi(votes: [], hasMoreAfter: false)
        }
        await empty.reload().value
        #expect(model.hasMoreAfter)
        #expect(empty.showsNoVotes)

        // The whole sheet draws; its list is drawn on its own, since an offscreen render leaves a
        // `ScrollView` blank.
        let sheet = try Self.rasterize(Self.sheet(model), in: appearance)
        let loaded = try Self.rasterize(Self.list(model), in: appearance)
        let noVotes = try Self.rasterize(Self.list(empty), in: appearance)

        #expect(sheet.pixelsWide > 0)
        #expect(Self.inkedRows(loaded) > Self.inkedRows(noVotes) + 100)
    }

    @Test func aSheetStillReadingAndOneThatFailedBothDraw() async throws {
        // `reload` marks the read in flight before it yields, so this draws the loading state.
        let loading = PollVotesViewModel(pollEventId: "poll", poll: Self.poll) { _, _ in Self.page }
        let read = loading.reload()
        #expect(loading.isLoading)
        let loadingRep = try Self.rasterize(Self.list(loading), in: .aqua)
        await read.value

        let failing = PollVotesViewModel(pollEventId: "poll", poll: Self.poll) { _, _ in
            throw PollVotesRenderFailure()
        }
        await failing.reload().value
        #expect(failing.failed)
        let failedRep = try Self.rasterize(Self.list(failing), in: .aqua)

        #expect(loadingRep.pixelsHigh > 0)
        #expect(failedRep.pixelsHigh > 0)
    }

    // MARK: - Helpers

    private static func card(onViewVotes: (() -> Void)?) -> some View {
        PollMessageRow(
            poll: poll,
            isOutgoing: false,
            senderName: "Alice",
            timeLabel: "12:04",
            onVote: { _ in },
            onViewVotes: onViewVotes
        )
        .frame(width: 640)
        .background(WNColor.backgroundPrimary)
    }

    private static func sheet(_ model: PollVotesViewModel) -> some View {
        PollVotesSheet(model: model, blockedAccountIDs: [carol], voterDisplay: voterDisplay, onClose: {})
            .frame(height: 480)
            .background(WNColor.backgroundPrimary)
            .environment(WorkspaceState.preview())
    }

    private static func list(_ model: PollVotesViewModel) -> some View {
        PollVotesList(model: model, blockedAccountIDs: [carol], voterDisplay: voterDisplay)
            .frame(width: 380)
            .background(WNColor.backgroundPrimary)
            .environment(WorkspaceState.preview())
    }

    private static func voterDisplay(_ accountIdHex: String) -> WorkspaceState.ReactionReactorDisplay {
        WorkspaceState.ReactionReactorDisplay(
            accountIdHex: accountIdHex,
            name: [alice: "You", bob: "Bob", carol: "Carol"][accountIdHex] ?? "Someone",
            sanitizedPictureURL: nil,
            isSelf: accountIdHex == alice
        )
    }

    /// Pixel rows carrying anything besides the ground, a measure of how much the sheet drew.
    private static func inkedRows(_ rep: NSBitmapImageRep) -> Int {
        guard let ground = rep.colorAt(x: 1, y: rep.pixelsHigh - 2)?.usingColorSpace(.sRGB) else { return 0 }
        return (0..<rep.pixelsHigh).filter { y in
            stride(from: 0, to: rep.pixelsWide, by: 4).contains { x in
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return abs(pixel.brightnessComponent - ground.brightnessComponent) > 0.08
            }
        }.count
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

private struct PollVotesRenderFailure: Error {}
