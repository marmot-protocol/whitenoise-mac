import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Host-side changes MarmotKit 0.13.0 requires: Markdown timestamps and attachment roles.
@MainActor
struct MarmotKit013AdoptionTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let enUS = Locale(identifier: "en_US")
    /// 2026-10-12 14:30:05 UTC.
    private let instant: Int64 = 1_791_815_405

    @Test func timestampFormatterRendersEachStyleInTheGivenLocaleAndTimeZone() {
        func text(_ style: MarkdownTimestampStyleFfi) -> String {
            MarkdownTimestampFormatter.text(unixSeconds: instant, style: style, locale: enUS, timeZone: utc)
        }
        #expect(text(.shortTime) == "2:30\u{202F}PM")
        #expect(text(.longTime) == "2:30:05\u{202F}PM")
        #expect(text(.shortDate) == "10/12/2026")
        #expect(text(.longDate) == "October 12, 2026")
        #expect(text(.longDateTime).hasPrefix("Monday, October 12, 2026"))
        #expect(
            MarkdownTimestampFormatter.text(
                unixSeconds: instant, style: .shortTime, locale: enUS, timeZone: TimeZone(identifier: "Asia/Tokyo")!
            ) == "11:30\u{202F}PM"
        )
    }

    @Test func relativeTimestampReadsAgainstTheGivenNow() {
        let now = Date(timeIntervalSince1970: TimeInterval(instant + 3 * 3600))
        let text = MarkdownTimestampFormatter.text(
            unixSeconds: instant, style: .relative, now: now, locale: enUS, timeZone: utc)
        #expect(text == "3 hours ago")
    }

    @Test func timestampOutsideTheCalendarRangeStaysTheRawNumber() {
        let tooLarge = MarkdownTimestampFormatter.maxRenderableSeconds + 1
        #expect(
            MarkdownTimestampFormatter.text(unixSeconds: tooLarge, style: .longDate, locale: enUS, timeZone: utc)
                == String(tooLarge)
        )
    }

    @Test func markdownTimestampInlineRendersInsteadOfBeingDropped() throws {
        let document = MarkdownDisplayDocument(
            document: MarkdownDocumentFfi(
                blocks: [
                    .paragraph(inlines: [
                        .text(content: "Meet at "),
                        .timestamp(unixSeconds: instant, style: .longDate),
                    ])
                ],
                truncated: false
            )
        )
        let paragraph = try #require(document.inlineParagraph)
        let expected = MarkdownTimestampFormatter.text(unixSeconds: instant, style: .longDate)
        #expect(String(paragraph.characters) == "Meet at " + expected)
    }

    @Test func sharedMediaHistorySkipsInlineEmojiArtwork() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentHistoryPageResult = .page(
            page: page([entry("photo", role: .shared), entry("emoji", role: .inlineEmoji)], hasMore: false))
        let model = AttachmentViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)

        await model.refreshHistory()

        #expect(model.items.map(\.messageIdHex) == ["photo"])
    }

    @Test func sharedMediaHistoryPagesPastEmojiOnlyPages() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentHistoryPageQueue = [
            .page(page: page([entry("emoji-1", role: .inlineEmoji)], hasMore: true)),
            .page(page: page([entry("emoji-2", role: .inlineEmoji)], hasMore: true)),
            .page(page: page([entry("photo", role: .shared)], hasMore: false)),
        ]
        let model = AttachmentViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)

        await model.refreshHistory()

        #expect(runtime.attachmentHistoryPageReadCount == 3)
        #expect(model.items.map(\.messageIdHex) == ["photo"])
        #expect(!model.hasMore)
    }

    private func page(_ entries: [AttachmentEntryFfi], hasMore: Bool) -> AttachmentPageFfi {
        AttachmentPageFfi(
            entries: entries,
            version: AttachmentHistoryVersion(noPointer: .init()),
            nextCursor: hasMore ? AttachmentHistoryCursor(noPointer: .init()) : nil,
            hasMore: hasMore
        )
    }

    private func entry(_ messageIdHex: String, role: AttachmentRoleFfi) -> AttachmentEntryFfi {
        AttachmentEntryFfi(
            messageIdHex: messageIdHex,
            sourceMessageIdHex: messageIdHex,
            sender: "alice",
            timelineAt: 10,
            receivedAt: 10,
            sourceEpoch: 1,
            category: .image,
            role: role,
            attachment: .rejected(
                attachmentIndex: 0,
                rejection: MediaAttachmentRejectionFfi(kind: .unsupportedFormat, detail: "fixture")
            )
        )
    }
}
