import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

struct NostrEventPreviewTests {
    private static let author = String(repeating: "ab", count: 32)
    private static let note = "note1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
    private static let naddr =
        "naddr1qvzqqqr4gupzqmjxss3dld622uu8q25gywum9qtg4w4cv4064jmg20xsac2aam5nqqxnzd3cxqmrzv3exgmr2wfesqgnr8m"

    private static func eventJson(
        kind: Int, content: String = "", tags: [[String]] = [], createdAt: Int = 1_700_000_000
    )
        -> String
    {
        let object: [String: Any] = [
            "id": String(repeating: "cd", count: 32),
            "pubkey": author,
            "created_at": createdAt,
            "kind": kind,
            "tags": tags,
            "content": content,
            "sig": String(repeating: "ef", count: 64),
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func document(_ blocks: [MarkdownDisplayBlock]) -> MarkdownDisplayDocument {
        MarkdownDisplayDocument(
            blocks: blocks.enumerated().map { MarkdownDisplayBlockNode(id: $0.offset, block: $0.element) },
            truncated: false
        )
    }

    private func linked(_ text: String, _ url: String) -> AttributedString {
        var run = AttributedString(text)
        run.link = URL(string: url)
        return run
    }

    // MARK: - References and njump

    @Test func onlyWellFormedEventReferencesOpenOnNjump() {
        #expect(
            MarkdownLinkPolicy.eventViewerURL(for: "nostr:\(Self.note)")
                == URL(string: "https://njump.me/\(Self.note)"))
        #expect(
            MarkdownLinkPolicy.eventViewerURL(for: Self.naddr.uppercased())
                == URL(string: "https://njump.me/\(Self.naddr)"))
        // Profiles open in-app, relays have nothing to show, and nothing outside the bech32
        // alphabet may reach the URL path.
        for rejected in [
            "npub1qqqqqqqq", "nrelay1qqqqqqqq", "note1", "note1abc/../../evil", "note1abc?x=1", "nevent1abc@x.com",
            "note1bio",
        ] {
            #expect(MarkdownLinkPolicy.eventViewerURL(for: rejected) == nil, "\(rejected)")
        }
    }

    @Test func previewReferenceIsTheFirstLinkedEventOutsideCode() {
        var text = AttributedString("see ")
        text.append(linked("@bob", "nostr:npub1qqqqqqqq"))
        text.append(linked(" a site", "https://example.com"))
        text.append(linked(" a note", "nostr:\(Self.note)"))
        text.append(linked(" an article", "nostr:\(Self.naddr)"))

        #expect(NostrEventPreview.previewReference(in: document([.paragraph(text)])) == Self.note)
        #expect(NostrEventPreview.previewReference(in: document([.codeBlock("nostr:\(Self.note)")])) == nil)
        #expect(NostrEventPreview.previewReference(in: nil) == nil)
    }

    // MARK: - Parsing

    @Test func aTextNoteKeepsItsLinesAndShortensReferences() throws {
        let content = "gm\u{202E}\n\n\n\nhello nostr:npub1qqqqqqqqqqqqqqqqqqqqqqqqqqq\u{0007} world"
        let preview = try #require(NostrEventPreview.parse(eventJson: Self.eventJson(kind: 1, content: content)))

        #expect(preview.authorIdHex == Self.author)
        #expect(preview.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(preview.body == .note(text: "gm\n\nhello npub1qqqqq...qqqq world"))
    }

    @Test func aLongNoteIsCut() throws {
        let preview = try #require(
            NostrEventPreview.parse(eventJson: Self.eventJson(kind: 1, content: String(repeating: "a", count: 2_000))))
        guard case .note(let text) = preview.body else {
            Issue.record("not a note")
            return
        }
        #expect(text.count == NostrEventPreview.maximumNoteLength + 1)
        #expect(text.hasSuffix("…"))
    }

    @Test func anArticleReadsItsTagsAndRejectsAnUnsafeImage() throws {
        let tags = [
            ["d", "intro"], ["title", "  Hello\n  Marmot "], ["summary", "Short\u{202E} summary"],
            ["image", "https://cdn.example.com/cover.png"], ["published_at", "1600000000"],
        ]
        let preview = try #require(
            NostrEventPreview.parse(eventJson: Self.eventJson(kind: 30023, content: "# Body", tags: tags)))
        #expect(
            preview.body
                == .article(
                    title: "Hello Marmot", summary: "Short summary",
                    imageURL: URL(string: "https://cdn.example.com/cover.png")))
        #expect(preview.createdAt == Date(timeIntervalSince1970: 1_600_000_000))

        let local = try #require(
            NostrEventPreview.parse(
                eventJson: Self.eventJson(kind: 30023, tags: [["image", "https://127.0.0.1/cover.png"]])))
        #expect(local.body == .article(title: nil, summary: nil, imageURL: nil))
    }

    @Test func anyOtherKindOnlyPointsAtTheEvent() throws {
        let list = try #require(NostrEventPreview.parse(eventJson: Self.eventJson(kind: 30000)))
        #expect(list.body == .other(kind: 30000))
        #expect(NostrEventPreview.parse(eventJson: "not json") == nil)
        #expect(
            NostrEventPreview.parse(eventJson: #"{"pubkey":"x","created_at":1,"kind":1,"tags":[],"content":""}"#) == nil
        )
    }

    // MARK: - Store

    private static func present(_ reference: String, content: String) -> PublicEventPreviewFfi {
        PublicEventPreviewFfi(
            reference: reference, state: .present, eventJson: eventJson(kind: 1, content: content), fetchedAt: 1)
    }

    @MainActor
    private static func noteText(_ store: NostrEventPreviewStore, _ reference: String) -> String? {
        guard case .loaded(let preview) = store.entry(for: reference), case .note(let text) = preview.body else {
            return nil
        }
        return text
    }

    @MainActor
    @Test func theStoreDrawsTheCachedEventThenTheRefreshedOneAndItsLocalAuthor() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.cachedPublicEvents[Self.note] = Self.present(Self.note, content: "old")
        runtime.resolvablePublicEvents[Self.note] = Self.present(Self.note, content: "new")
        runtime.installProfile(
            accountIdHex: Self.author,
            profile: UserProfileMetadataFfi(
                name: "alice", displayName: "Alice", about: nil, picture: "https://cdn.example.com/a.png", nip05: nil,
                lud16: nil))
        let store = NostrEventPreviewStore(accountRef: "account", runtime: runtime, mayFetch: { true })

        store.load(Self.note)
        store.load(Self.note)

        #expect(await waitFor { Self.noteText(store, Self.note) == "new" })
        #expect(runtime.resolvedPublicEventReferences == [Self.note])
        #expect(await waitFor { store.author(Self.author) != nil })
        #expect(
            store.author(Self.author)
                == .init(name: "Alice", pictureURL: URL(string: "https://cdn.example.com/a.png")))
    }

    /// Asking relays for an author's profile would tell them whose post the viewer opened.
    @MainActor
    @Test func anUnknownAuthorIsNeverLookedUpOnRelays() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountIdsMissingProfiles.insert(Self.author)
        runtime.resolvablePublicEvents[Self.note] = Self.present(Self.note, content: "hi")
        let store = NostrEventPreviewStore(accountRef: "account", runtime: runtime, mayFetch: { true })

        store.load(Self.note)

        #expect(await waitFor { Self.noteText(store, Self.note) == "hi" })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(store.author(Self.author) == nil)
        #expect(runtime.refreshedProfileIds.isEmpty)
    }

    @MainActor
    @Test func aDeletionRetractsTheCardForGood() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.cachedPublicEvents[Self.note] = Self.present(Self.note, content: "gone soon")
        runtime.resolvablePublicEvents[Self.note] = PublicEventPreviewFfi(
            reference: Self.note, state: .deleted, eventJson: nil, fetchedAt: nil)
        let store = NostrEventPreviewStore(accountRef: "account", runtime: runtime, mayFetch: { true })

        store.load(Self.note)
        #expect(await waitFor { store.entry(for: Self.note) == .unavailable })
        store.load(Self.note)

        #expect(runtime.resolvedPublicEventReferences == [Self.note])
    }

    /// A relay that timed out the first time the row was shown must not hide the card for the rest
    /// of the conversation, and a shown card is refreshed again when it comes back on screen.
    @MainActor
    @Test func aMissOrAShownCardIsAskedForAgainNextTime() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let store = NostrEventPreviewStore(accountRef: "account", runtime: runtime, mayFetch: { true })

        store.load(Self.note)
        #expect(await waitFor { runtime.resolvedPublicEventReferences.count == 1 })
        #expect(await waitFor { store.entry(for: Self.note) == nil })

        runtime.resolvablePublicEvents[Self.note] = Self.present(Self.note, content: "found")
        store.load(Self.note)
        #expect(await waitFor { Self.noteText(store, Self.note) == "found" })

        // The card coming back on screen, once the load that found it has finished.
        runtime.resolvablePublicEvents[Self.note] = Self.present(Self.note, content: "edited")
        #expect(
            await waitFor {
                store.load(Self.note)
                return runtime.resolvedPublicEventReferences.count >= 3
            })
        #expect(await waitFor { Self.noteText(store, Self.note) == "edited" })
    }

    @MainActor
    @Test func aFailedRefreshKeepsTheCachedEvent() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.cachedPublicEvents[Self.note] = Self.present(Self.note, content: "kept")
        runtime.resolvePublicEventError = MarmotKitError.StorageClosed(details: "closed")
        let store = NostrEventPreviewStore(accountRef: "account", runtime: runtime, mayFetch: { true })

        store.load(Self.note)

        #expect(await waitFor { !runtime.resolvedPublicEventReferences.isEmpty })
        #expect(await waitFor { Self.noteText(store, Self.note) == "kept" })
    }

    /// Previews switched off while a load was waiting on the cache: the relays are not asked.
    @MainActor
    @Test func noRelayIsAskedOnceThePreviewsAreOff() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.cachedPublicEvents[Self.note] = Self.present(Self.note, content: "cached")
        let store = NostrEventPreviewStore(accountRef: "account", runtime: runtime, mayFetch: { false })

        store.load(Self.note)

        #expect(await waitFor { Self.noteText(store, Self.note) == "cached" })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(runtime.resolvedPublicEventReferences.isEmpty)
    }
}
