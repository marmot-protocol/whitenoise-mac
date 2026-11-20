import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Events of a kind White Noise can't draw arrive as a card that names the kind, shows what the
/// event says about itself, and expands to the event as JSON.
struct UnsupportedEventTests {
    private static let id = String(repeating: "a", count: 64)
    private static let pubkey = String(repeating: "b", count: 64)

    private static func event(tags: [[String]] = [], content: String = "", kind: UInt64 = 4242) -> UnsupportedEvent {
        UnsupportedEvent(id: id, pubkey: pubkey, createdAt: 1_763_635_860, kind: kind, tags: tags, content: content)
    }

    private static func decoded(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: Card text

    @Test func theCardUsesTheTitleAndTheAltTextTheEventCarries() {
        let event = Self.event(
            tags: [["subject", "Signal box log"], ["alt", "The evening crew logged\na delay."]],
            content: #"{"status":"Delayed"}"#)

        #expect(event.kind == 4242)
        #expect(event.title == "Signal box log")
        #expect(event.summary == "The evening crew logged a delay.")
    }

    @Test func plainTextContentStandsInForMissingAltTextButDataDoesNot() {
        #expect(Self.event(content: "Running late, start without me").summary == "Running late, start without me")
        #expect(Self.event(content: #"  {"status":"Delayed"}"#).summary == nil)
        #expect(Self.event(content: "[1, 2]").summary == nil)
        #expect(Self.event(tags: [["alt", "  "]], content: "").summary == nil)
    }

    @Test func peerTextIsSanitizedAndBoundedOnTheCard() throws {
        let event = Self.event(
            tags: [["title", "inno\u{202E}cent"], ["alt", String(repeating: "x", count: 1_000)]])

        #expect(event.title == "innocent")
        let summary = try #require(event.summary)
        #expect(summary.count == UnsupportedEvent.summaryLimit + 1)
        #expect(summary.hasSuffix("…"))
    }

    // MARK: JSON

    @Test func theJSONIsTheWholeEventInNIP01Order() throws {
        let tags = [["subject", "Signal box log"], ["imeta", "url https://video.invalid/a.mp4", "m video/mp4"]]
        let content = "{\"status\":\"Delayed\"}\n\tquote \" and \\ backslash"
        let json = Self.event(tags: tags, content: content).json

        let object = try Self.decoded(json)
        #expect(object["id"] as? String == Self.id)
        #expect(object["pubkey"] as? String == Self.pubkey)
        #expect(object["created_at"] as? Int == 1_763_635_860)
        #expect(object["kind"] as? Int == 4242)
        #expect(object["tags"] as? [[String]] == tags)
        #expect(object["content"] as? String == content)
        let positions = ["\"id\"", "\"pubkey\"", "\"created_at\"", "\"kind\"", "\"tags\"", "\"content\""]
            .compactMap { json.range(of: $0)?.lowerBound }
        #expect(positions.count == 6)
        #expect(positions == positions.sorted())
        #expect(json.contains("\n    [\"subject\", \"Signal box log\"],\n"))
    }

    @Test func invisibleAndReorderingCharactersAreEscapedButSurvive() throws {
        // A bidi override, a zero-width space, a line separator and a tag character past the BMP.
        let content = "a\u{202E}b\u{200B}c\u{2028}d\u{E0041}e 👍"
        let json = Self.event(content: content).json

        #expect(json.contains("\\u202e"))
        #expect(json.contains("\\u200b"))
        #expect(json.contains("\\u2028"))
        #expect(json.contains("\\udb40\\udc41"))
        #expect(json.contains("👍"))
        #expect(!json.unicodeScalars.contains { $0.properties.generalCategory == .format })
        #expect(try Self.decoded(json)["content"] as? String == content)
    }

    @Test func aHugeEventIsCutShortOnScreenButCopiedWhole() {
        let event = Self.event(content: String(repeating: "x", count: 50_000))

        let shown = event.displayedJSON
        #expect(shown.isTruncated)
        #expect(
            shown.text.filter { $0 != "\n" }
                == String(event.json.prefix(UnsupportedEvent.displayLimit)).filter { $0 != "\n" })
        // The content is one JSON line; on screen it's broken up so the block stays narrow.
        #expect(shown.text.split(separator: "\n").allSatisfy { $0.count <= UnsupportedEvent.displayLineLimit })
        #expect(event.json.contains(String(repeating: "x", count: 50_000)))
        #expect(event.json.count > 50_000)
        #expect(!Self.event(content: "short").displayedJSON.isTruncated)
    }

    // MARK: Mapping

    @Test func onlyAnUndeletedRowOfAnUnknownKindBecomesACard() throws {
        let unknown = timelineMessage(
            id: Self.id, groupIdHex: "group", sender: "self", plaintext: "hello", kind: 4242,
            tags: [MessageTagFfi(values: ["alt", "A thing"])], recordedAt: 7)
        let deleted = timelineMessage(
            id: "deleted", groupIdHex: "group", sender: "bob", plaintext: "", kind: 4242, recordedAt: 8,
            deleted: true)
        let chat = timelineMessage(id: "chat", groupIdHex: "group", sender: "bob", plaintext: "hi", recordedAt: 9)
        let page = TimelinePageFfi(messages: [unknown, deleted, chat], hasMoreBefore: false, hasMoreAfter: false)

        let items = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        let card = try #require(items[0].unsupportedEvent)
        #expect(card.kind == 4242)
        #expect(card.summary == "A thing")
        #expect(try Self.decoded(card.json)["created_at"] as? Int == 7)
        // Your own event from another client sits on your side, like a bubble.
        #expect(items[0].isOutgoing)
        #expect(items[1].presentation == .unsupported)
        #expect(items[1].unsupportedEvent == nil)
        #expect(items[2].unsupportedEvent == nil)
    }
}
