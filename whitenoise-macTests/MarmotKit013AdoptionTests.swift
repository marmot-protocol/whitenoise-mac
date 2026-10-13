import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Host-side changes for MarmotKit 0.13.0: Markdown timestamps (rendered and refreshed at draw
/// time) and attachment roles.
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

    @Test func timestampDocumentsReportWhichKindOfRefreshTheyNeed() {
        #expect(document([.text(content: "plain")]).timestamps == .none)
        #expect(document([.timestamp(unixSeconds: instant, style: .longDate)]).timestamps == .absolute)
        #expect(
            document([
                .timestamp(unixSeconds: instant, style: .longDate),
                .timestamp(unixSeconds: instant, style: .relative),
            ]).timestamps == .relative)
    }

    @Test func relativeTimestampRefreshesForTheMomentItIsDrawn() throws {
        let doc = document([.text(content: "Sent "), .timestamp(unixSeconds: instant, style: .relative)])
        let threeHoursLater = Date(timeIntervalSince1970: TimeInterval(instant + 3 * 3600))
        let oneDayLater = Date(timeIntervalSince1970: TimeInterval(instant + 26 * 3600))

        let first = doc.refreshingTimestamps(now: threeHoursLater, locale: enUS, timeZone: utc)
        #expect(try text(of: first) == "Sent 3 hours ago")
        // The tag survives a refresh, so the next draw can re-format the refreshed copy too.
        let second = first.refreshingTimestamps(now: oneDayLater, locale: enUS, timeZone: utc)
        #expect(try text(of: second) == "Sent yesterday")
        #expect(doc.relativeTimestampDates == [Date(timeIntervalSince1970: TimeInterval(instant))])
    }

    @Test func absoluteTimestampFollowsTheLocaleAndTimeZoneItIsDrawnIn() throws {
        let doc = document([.timestamp(unixSeconds: instant, style: .longDate)])
        let spanish = doc.refreshingTimestamps(now: Date(), locale: Locale(identifier: "es_ES"), timeZone: utc)
        #expect(try text(of: spanish) == "12 de octubre de 2026")
        let tokyoTime = document([.timestamp(unixSeconds: instant, style: .shortTime)])
            .refreshingTimestamps(now: Date(), locale: enUS, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(try text(of: tokyoTime) == "11:30\u{202F}PM")
    }

    @Test func timestampsNestedInQuotesAndListsRefreshToo() throws {
        let nested = MarkdownDisplayDocument(
            document: MarkdownDocumentFfi(
                blocks: [
                    .blockQuote(
                        blocks: [.paragraph(inlines: [.timestamp(unixSeconds: instant, style: .longDate)])],
                        blankLinesBefore: Data([0])
                    )
                ],
                truncated: false
            )
        )
        #expect(nested.timestamps == .absolute)
        let refreshed = nested.refreshingTimestamps(now: Date(), locale: Locale(identifier: "es_ES"), timeZone: utc)
        guard case .blockQuote(let inner) = try #require(refreshed.blocks.first).block,
            case .paragraph(let quoted) = try #require(inner.first).block
        else {
            Issue.record("expected a quoted paragraph")
            return
        }
        #expect(String(quoted.characters) == "12 de octubre de 2026")
    }

    @Test func relativeScheduleTicksFasterNearTheInstant() {
        let anchor = Date(timeIntervalSince1970: TimeInterval(instant))
        let dates = [anchor]
        #expect(RelativeTimestampSchedule.interval(at: anchor.addingTimeInterval(30), dates: dates) == 10)
        #expect(RelativeTimestampSchedule.interval(at: anchor.addingTimeInterval(600), dates: dates) == 60)
        #expect(RelativeTimestampSchedule.interval(at: anchor.addingTimeInterval(7200), dates: dates) == 3600)
    }

    /// An hourly step from exactly an hour out used to land on the instant itself, holding
    /// "in 1 hour" for the whole last hour; the minute band has to start inside that hour.
    @Test func relativeScheduleTicksEveryMinuteThroughAFutureInstantsLastHour() {
        let anchor = Date(timeIntervalSince1970: TimeInterval(instant))
        let ticks = ticks(of: [anchor], from: anchor.addingTimeInterval(-7200), until: anchor)

        let lastHour = ticks.filter { $0 > anchor.addingTimeInterval(-3600) && $0 < anchor.addingTimeInterval(-60) }
        #expect(lastHour.count >= 58)
        #expect(zip(lastHour, lastHour.dropFirst()).allSatisfy { $1.timeIntervalSince($0) <= 60 })
        // Likewise the 10-second band has to start inside the last minute, not on the instant.
        let lastMinute = ticks.filter { $0 > anchor.addingTimeInterval(-60) && $0 < anchor }
        #expect(lastMinute.count >= 5)
    }

    /// The nearest instant alone cannot pace the schedule: a farther future one still has to
    /// enter its minute band on time while a nearer past one sets an hourly step.
    @Test func relativeScheduleRespectsEveryFutureInstantNotOnlyTheNearest() {
        let anchor = Date(timeIntervalSince1970: TimeInterval(instant))
        let past = anchor.addingTimeInterval(-7200)
        let future = anchor.addingTimeInterval(9000)
        let ticks = ticks(of: [past, future], from: anchor, until: future)

        let lastHour = ticks.filter { $0 > future.addingTimeInterval(-3600) && $0 < future.addingTimeInterval(-60) }
        #expect(lastHour.count >= 58)
    }

    private func ticks(of dates: [Date], from start: Date, until end: Date) -> [Date] {
        var entries = RelativeTimestampSchedule.Entries(upcoming: start, dates: dates)
        var ticks: [Date] = []
        while let tick = entries.next(), tick < end, ticks.count < 10_000 {
            ticks.append(tick)
        }
        return ticks
    }

    private func document(_ inlines: [MarkdownInlineFfi]) -> MarkdownDisplayDocument {
        MarkdownDisplayDocument(
            document: MarkdownDocumentFfi(blocks: [.paragraph(inlines: inlines)], truncated: false))
    }

    private func text(of document: MarkdownDisplayDocument) throws -> String {
        String(try #require(document.inlineParagraph).characters)
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
