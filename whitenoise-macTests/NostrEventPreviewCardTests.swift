import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The card as the transcript hosts it: it asks for its event only once its row is on screen, and
/// draws nothing until there is an event to draw.
@MainActor
struct NostrEventPreviewCardTests {
    nonisolated private static let author = String(repeating: "ab", count: 32)
    nonisolated private static let note = "note1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

    nonisolated private static func event(
        kind: Int, content: String = "", tags: [[String]] = []
    ) -> PublicEventPreviewFfi {
        let object: [String: Any] = [
            "id": String(repeating: "cd", count: 32), "pubkey": author, "created_at": 1_700_000_000,
            "kind": kind, "tags": tags, "content": content, "sig": String(repeating: "ef", count: 64),
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return PublicEventPreviewFfi(reference: note, state: .present, eventJson: json, fetchedAt: 1)
    }

    private static func host(
        _ store: NostrEventPreviewStore, visibility: TranscriptCellVisibility
    ) -> HostedViewWindow {
        HostedViewWindow(
            NostrEventPreviewCard(reference: note, store: store)
                .environment(\.transcriptCellVisibility, visibility)
                .frame(width: LinkPreviewCard.maximumWidth),
            size: CGSize(width: LinkPreviewCard.maximumWidth, height: 400))
    }

    @Test func anOffScreenCardAsksForNothingAndDrawsNothing() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.resolvablePublicEvents[Self.note] = Self.event(kind: 1, content: "hello")
        let store = NostrEventPreviewStore(accountRef: "account", runtime: runtime, mayFetch: { true })
        let visibility = TranscriptCellVisibility()
        let window = Self.host(store, visibility: visibility)
        defer { window.close() }

        _ = await window.settle(timeout: .milliseconds(200)) { false }

        #expect(runtime.resolvedPublicEventReferences.isEmpty)
        #expect(store.preview(for: Self.note) == nil)
        #expect(window.window.contentView?.fittingSize.height ?? 0 < 1)
    }

    @Test(arguments: [
        event(kind: 1, content: "Just shipped encrypted group chats.\n\nFeedback welcome!"),
        event(kind: 30023, tags: [["title", "How Marmot works"], ["summary", "A walk through MLS."]]),
        event(kind: 30000),
    ])
    func aVisibleCardLoadsItsEventAndDrawsIt(_ event: PublicEventPreviewFfi) async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.resolvablePublicEvents[Self.note] = event
        let store = NostrEventPreviewStore(accountRef: "account", runtime: runtime, mayFetch: { true })
        let visibility = TranscriptCellVisibility()
        let window = Self.host(store, visibility: visibility)
        defer { window.close() }

        visibility.isVisible = true

        #expect(await window.settle { store.author(Self.author) != nil })
        #expect(
            await window.settle { (window.window.contentView?.fittingSize.height ?? 0) > 20 },
            "a loaded event draws a card")
        #expect(runtime.resolvedPublicEventReferences == [Self.note])
    }

    @Test func aBlockedAuthorsCardStaysEmpty() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.resolvablePublicEvents[Self.note] = Self.event(kind: 1, content: "hidden")
        let store = NostrEventPreviewStore(
            accountRef: "account", runtime: runtime, mayFetch: { true }, isBlocked: { $0 == Self.author })
        let visibility = TranscriptCellVisibility()
        let window = Self.host(store, visibility: visibility)
        defer { window.close() }

        visibility.isVisible = true

        #expect(await window.settle { !runtime.resolvedPublicEventReferences.isEmpty })
        _ = await window.settle(timeout: .milliseconds(200)) { false }
        #expect(window.window.contentView?.fittingSize.height ?? 0 < 1)
    }
}
