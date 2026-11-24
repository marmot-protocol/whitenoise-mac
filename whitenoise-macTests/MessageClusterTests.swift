//
//  MessageClusterTests.swift
//  whitenoise-macTests
//
//  Grouping consecutive messages from one person (whitenoise-ios#1366): which rows start and end a
//  run, which footers a run hides, and the header's compact disappearing-message timer.
//

import Foundation
import Testing

@testable import whitenoise_mac

struct MessageClusterProjectionTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func entry(
        _ author: MessageClusterProjection.Author,
        at seconds: TimeInterval,
        followsBoundary: Bool = false
    ) -> MessageClusterProjection.Entry {
        MessageClusterProjection.Entry(
            author: author, sentAt: start.addingTimeInterval(seconds), followsBoundary: followsBoundary)
    }

    private static func positions(_ entries: [MessageClusterProjection.Entry?]) -> [MessageClusterPosition] {
        MessageClusterProjection.positions(for: entries, calendar: utc)
    }

    private static let middle = MessageClusterPosition(startsCluster: false, endsCluster: false)
    private static let first = MessageClusterPosition(startsCluster: true, endsCluster: false)
    private static let last = MessageClusterPosition(startsCluster: false, endsCluster: true)

    @Test func consecutiveMessagesFromOnePersonFormOneRun() {
        let result = Self.positions([
            Self.entry(.peer("alice"), at: 0),
            Self.entry(.peer("alice"), at: 30),
            Self.entry(.peer("alice"), at: 60),
        ])
        #expect(result == [Self.first, Self.middle, Self.last])
    }

    @Test func aDifferentAuthorStartsANewRun() {
        let result = Self.positions([
            Self.entry(.peer("alice"), at: 0),
            Self.entry(.peer("bob"), at: 10),
            Self.entry(.me, at: 20),
            Self.entry(.me, at: 30),
        ])
        #expect(result == [.standalone, .standalone, Self.first, Self.last])
    }

    @Test func aPauseLongerThanFiveMinutesStartsANewRun() {
        let result = Self.positions([
            Self.entry(.me, at: 0),
            Self.entry(.me, at: 300),
            Self.entry(.me, at: 601),
        ])
        #expect(result == [Self.first, Self.last, .standalone])
    }

    @Test func aNewDayStartsANewRun() {
        // 23:59:30 and 00:00:10 UTC the next day, 40 seconds apart.
        let midnight = Self.utc.startOfDay(for: Self.start).addingTimeInterval(86_400)
        let offset = midnight.timeIntervalSince(Self.start)
        let result = Self.positions([
            Self.entry(.me, at: offset - 30),
            Self.entry(.me, at: offset + 10),
        ])
        #expect(result == [.standalone, .standalone])
    }

    @Test func aBoundaryStartsANewRunEvenFromTheSamePerson() {
        let result = Self.positions([
            Self.entry(.peer("alice"), at: 0),
            Self.entry(.peer("alice"), at: 10, followsBoundary: true),
            Self.entry(.peer("alice"), at: 20),
        ])
        #expect(result == [.standalone, Self.first, Self.last])
    }

    @Test func aRowThatDoesNotGroupBreaksTheRunOnBothSides() {
        let result = Self.positions([
            Self.entry(.peer("alice"), at: 0),
            nil,
            Self.entry(.peer("alice"), at: 20),
        ])
        #expect(result == [.standalone, .standalone, .standalone])
    }

    @Test func anOutOfOrderTimestampDoesNotContinueARun() {
        let result = Self.positions([
            Self.entry(.me, at: 60),
            Self.entry(.me, at: 0),
        ])
        #expect(result == [.standalone, .standalone])
    }

    @Test func notificationsAndMembershipRowsDoNotGroup() {
        let notice = MessageItem(
            id: "n", senderName: "Alice", body: "Alice was added", sentAt: Self.start, isOutgoing: false,
            presentation: .groupSystem)
        let malformedPoll = MessageItem(
            id: "p", senderName: "Alice", body: "Lunch?", sentAt: Self.start, isOutgoing: false,
            presentation: .poll)
        let chat = MessageItem(
            id: "c", senderAccountIdHex: "ALICE", senderName: "Alice", body: "Hi", sentAt: Self.start,
            isOutgoing: false)
        #expect(MessageClusterProjection.Entry(message: notice, followsBoundary: false) == nil)
        #expect(MessageClusterProjection.Entry(message: malformedPoll, followsBoundary: false) == nil)
        #expect(MessageClusterProjection.Entry(message: chat, followsBoundary: false)?.author == .peer("alice"))
    }
}

struct MessageClusterFooterTests {
    private static let middle = MessageClusterPosition(startsCluster: false, endsCluster: false)

    @Test func onlyTheRunsLastRowShowsARoutineTimestamp() {
        #expect(
            MessageClusterPosition.standalone.showsFooter(
                isDeleted: false, isEdited: false, hasReports: false, indicator: .delivered))
        #expect(!Self.middle.showsFooter(isDeleted: false, isEdited: false, hasReports: false, indicator: .delivered))
        #expect(!Self.middle.showsFooter(isDeleted: false, isEdited: false, hasReports: false, indicator: .none))
    }

    @Test func aRowWithSomethingOfItsOwnToSayKeepsItsFooterMidRun() {
        #expect(Self.middle.showsFooter(isDeleted: true, isEdited: false, hasReports: false, indicator: .none))
        #expect(Self.middle.showsFooter(isDeleted: false, isEdited: true, hasReports: false, indicator: .delivered))
        #expect(Self.middle.showsFooter(isDeleted: false, isEdited: false, hasReports: true, indicator: .none))
        #expect(Self.middle.showsFooter(isDeleted: false, isEdited: false, hasReports: false, indicator: .sending))
        #expect(Self.middle.showsFooter(isDeleted: false, isEdited: false, hasReports: false, indicator: .failed))
        #expect(Self.middle.showsFooter(isDeleted: false, isEdited: false, hasReports: false, indicator: .warning))
    }

    @Test func deliveryMarkersMatchIOS() {
        #expect(MessageDeliveryMarker.systemImage(for: .sending) == "ellipsis.message")
        #expect(MessageDeliveryMarker.systemImage(for: .delivered) == "checkmark.circle.fill")
        #expect(MessageDeliveryMarker.systemImage(for: .none) == nil)
    }
}

@MainActor
struct TranscriptClusterRowTests {
    private static let start = Date()
    private static let context = TranscriptRowContext(
        canVoteInPolls: true, showsDebugMetadata: false, isSelectionMode: false, localeIdentifier: "en",
        referenceDay: 0)

    private static func item(
        _ id: String, from sender: String?, at seconds: TimeInterval, importSource: MessageImportSource? = nil
    ) -> TimelineMessageDisplayItem {
        TimelineMessageDisplayItem(
            message: MessageItem(
                id: id, importSource: importSource, senderAccountIdHex: sender ?? "me", senderName: sender ?? "Me",
                body: id, sentAt: start.addingTimeInterval(seconds), isOutgoing: sender == nil),
            dayLabel: nil)
    }

    private static func clusters(_ rows: [TranscriptRow]) -> [String: MessageClusterPosition] {
        var result: [String: MessageClusterPosition] = [:]
        for row in rows {
            switch row {
            case .message(let item, _, _, _, _, let cluster): result[item.message.id] = cluster
            case .pending(_, let cluster): result["pending"] = cluster
            default: break
            }
        }
        return result
    }

    @Test func theUnreadDividerSplitsARun() {
        let rows = TranscriptRow.rows(
            displayItems: [
                Self.item("a", from: "alice", at: 0), Self.item("b", from: "alice", at: 10),
                Self.item("c", from: "alice", at: 20),
            ],
            paging: .empty, pendingOutgoingRows: [], unreadDividerMessageId: "b", context: Self.context)
        let clusters = Self.clusters(rows)
        #expect(clusters["a"] == .standalone)
        #expect(clusters["b"] == MessageClusterPosition(startsCluster: true, endsCluster: false))
        #expect(clusters["c"] == MessageClusterPosition(startsCluster: false, endsCluster: true))
    }

    @Test func theFirstLiveMessageAfterImportedHistoryStartsAFreshRun() {
        let phone = MessageImportSource.device(slotIdHex: "a", label: "iPhone")
        let rows = TranscriptRow.rows(
            displayItems: [
                Self.item("old", from: nil, at: 0, importSource: phone), Self.item("live", from: nil, at: 10),
            ],
            paging: .empty, pendingOutgoingRows: [], unreadDividerMessageId: nil, context: Self.context)
        let clusters = Self.clusters(rows)
        #expect(clusters["old"] == .standalone)
        #expect(clusters["live"] == .standalone)
    }

    @Test func aPendingSendContinuesTheOwnRunBeforeIt() {
        let pending = PendingOutgoingTextMessage(text: "on its way", createdAt: Self.start.addingTimeInterval(20))
        let rows = TranscriptRow.rows(
            displayItems: [Self.item("mine", from: nil, at: 0)],
            paging: .empty, pendingOutgoingRows: [.text(pending)], unreadDividerMessageId: nil,
            context: Self.context)
        let clusters = Self.clusters(rows)
        #expect(clusters["mine"] == MessageClusterPosition(startsCluster: true, endsCluster: false))
        #expect(clusters["pending"] == MessageClusterPosition(startsCluster: false, endsCluster: true))
    }

    @Test func rowsInARunSitCloserThanRuns() {
        let rows = TranscriptRow.rows(
            displayItems: [
                Self.item("a", from: "alice", at: 0), Self.item("b", from: "alice", at: 10),
                Self.item("c", from: "bob", at: 20),
            ],
            paging: .empty, pendingOutgoingRows: [], unreadDividerMessageId: nil, context: Self.context)
        let messages = rows.filter { if case .message = $0 { true } else { false } }
        let gapAB = messages[0].verticalInsets.bottom + messages[1].verticalInsets.top
        let gapBC = messages[1].verticalInsets.bottom + messages[2].verticalInsets.top
        #expect(gapAB == 3)
        #expect(gapBC == 16)
    }
}

struct ConversationHeaderTimerTests {
    private static let english = Locale(identifier: "en_US")

    @Test func exactWeeksReadAsWeeks() {
        #expect(DisappearingMessageDuration.compactLabel(seconds: 604_800, locale: Self.english) == "1w")
        #expect(DisappearingMessageDuration.compactLabel(seconds: 1_209_600, locale: Self.english) == "2w")
    }

    @Test func otherDurationsUseAtMostTwoUnits() {
        #expect(DisappearingMessageDuration.compactLabel(seconds: 3_600, locale: Self.english) == "1h")
        #expect(DisappearingMessageDuration.compactLabel(seconds: 86_400, locale: Self.english) == "1d")
        #expect(DisappearingMessageDuration.compactLabel(seconds: 2_592_000, locale: Self.english) == "30d")
        #expect(DisappearingMessageDuration.compactLabel(seconds: 5_400, locale: Self.english) == "1h 30m")
    }

    @MainActor
    @Test func theSpokenLabelNamesTheMembersAndTheTimer() {
        let label = DisappearingMessageHeaderSubtitle.accessibilityLabel(subtitle: "3 members", durationSeconds: 86_400)
        let expected = String(
            format: L10n.string("%@, Disappearing messages: %@"), "3 members", L10n.plural("%llu days", UInt64(1)))
        #expect(label == expected)
        #expect(label.contains("3 members"))
        let alone = DisappearingMessageHeaderSubtitle.accessibilityLabel(subtitle: "", durationSeconds: 86_400)
        #expect(!alone.hasPrefix(","))
    }
}
