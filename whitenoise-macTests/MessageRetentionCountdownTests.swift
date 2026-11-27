import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import whitenoise_mac

/// A message's own disappearing countdown (#1040): twelve discrete steps from its actual
/// duration and expiry, redrawn only at step boundaries, clamped to `0...12`, and absent when
/// the core gives no finite expiry.
@Suite struct MessageRetentionCountdownTests {
    /// One hour, expiring at a round instant, so each step is exactly five minutes.
    private static let expiry: UInt64 = 1_800_000_000
    private static let hour: UInt64 = 3_600

    private static func countdown(
        seconds: UInt64 = hour,
        expiresAt: UInt64 = expiry
    ) throws -> MessageRetentionCountdown {
        try #require(MessageRetentionCountdown(retentionSeconds: seconds, retentionExpiresAt: expiresAt))
    }

    private static func date(_ unixSeconds: UInt64, plus offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: TimeInterval(unixSeconds) + offset)
    }

    // MARK: - Invalid or missing data

    @Test(arguments: [
        (seconds: UInt64?.none, expiresAt: UInt64?.some(expiry)),
        (seconds: UInt64?.some(hour), expiresAt: UInt64?.none),
        (seconds: UInt64?.some(0), expiresAt: UInt64?.some(expiry)),
        (seconds: UInt64?.some(hour), expiresAt: UInt64?.some(0)),
        (seconds: UInt64?.none, expiresAt: UInt64?.none),
    ])
    func missingOrNonpositiveRetentionShowsNoCountdown(seconds: UInt64?, expiresAt: UInt64?) {
        #expect(MessageRetentionCountdown(retentionSeconds: seconds, retentionExpiresAt: expiresAt) == nil)
    }

    /// The bubble reads the countdown straight off the message the core projected.
    @Test func aMessageCarriesItsOwnCountdownOnlyWithAFiniteExpiry() {
        let expiring = MessageItem(
            id: "a", retentionSeconds: Self.hour, retentionExpiresAt: Self.expiry,
            senderName: "Avery", body: "hi", sentAt: Self.date(Self.expiry, plus: -60), isOutgoing: false)
        let kept = MessageItem(id: "b", senderName: "Avery", body: "hi", sentAt: .now, isOutgoing: false)

        #expect(MessageRetentionCountdown(message: expiring)?.durationSeconds == Self.hour)
        #expect(MessageRetentionCountdown(message: expiring)?.expiresAt == Self.date(Self.expiry))
        #expect(MessageRetentionCountdown(message: kept) == nil)
    }

    // MARK: - Step calculation

    @Test func aNewMessageShowsEveryStep() throws {
        let countdown = try Self.countdown()
        #expect(countdown.startsAt == Self.date(Self.expiry, plus: -3_600))
        #expect(countdown.remainingSteps(at: countdown.startsAt) == 12)
        #expect(countdown.remainingSteps(at: Self.date(Self.expiry, plus: -3_599)) == 12)
    }

    /// A step runs out on its boundary, not a moment after it: halfway through the hour, six of
    /// twelve steps are left, and one second earlier seven still are.
    @Test func eachStepRunsOutOnItsBoundary() throws {
        let countdown = try Self.countdown()
        #expect(countdown.remainingSteps(at: Self.date(Self.expiry, plus: -1_801)) == 7)
        #expect(countdown.remainingSteps(at: Self.date(Self.expiry, plus: -1_800)) == 6)
        #expect(countdown.remainingSteps(at: Self.date(Self.expiry, plus: -1)) == 1)
    }

    /// An old or restored message shows the step it has actually reached.
    @Test func anOlderMessageShowsTheStepItHasReached() throws {
        let week = try Self.countdown(seconds: 604_800)
        // Five days into a seven-day window: 5/7 of 12 = 8.57 steps gone, so 4 remain.
        #expect(week.remainingSteps(at: Self.date(Self.expiry, plus: -2 * 86_400)) == 4)
    }

    /// A clock that reads earlier than the message's start (another device's skew) cannot show
    /// more than a full pie.
    @Test func aClockBeforeTheStartClampsToTwelve() throws {
        let countdown = try Self.countdown()
        #expect(countdown.remainingSteps(at: Self.date(Self.expiry, plus: -86_400)) == 12)
    }

    // MARK: - Past expiry

    /// The core may still expose a message after the local clock passes its expiry. It stays
    /// at the empty final step, never negative, and asks for no further redraws.
    @Test func pastExpiryStaysAtTheEmptyStepAndSchedulesNothing() throws {
        let countdown = try Self.countdown()
        for offset: TimeInterval in [0, 1, 3_600, 86_400 * 365] {
            let date = Self.date(Self.expiry, plus: offset)
            #expect(countdown.remainingSteps(at: date) == 0)
            #expect(countdown.upcomingBoundaries(after: date).isEmpty)
        }
    }

    // MARK: - Boundary scheduling

    @Test func thereAreTwelveBoundariesEndingAtTheExpiry() throws {
        let countdown = try Self.countdown()
        let boundaries = countdown.stepBoundaries

        #expect(boundaries.count == 12)
        #expect(boundaries.last == countdown.expiresAt)
        #expect(zip(boundaries, boundaries.dropFirst()).allSatisfy { $0 < $1 })
        #expect(boundaries.first == Self.date(Self.expiry, plus: -3_300))
    }

    /// Only the boundaries still ahead are scheduled, each one drops the step by exactly one,
    /// and the step never changes between them. Twelve redraws at most for the message's whole
    /// life, rather than a per-second timer.
    @Test func redrawsAreScheduledOnlyAtTheBoundariesStillAhead() throws {
        let countdown = try Self.countdown()
        let now = Self.date(Self.expiry, plus: -1_750)
        let upcoming = countdown.upcomingBoundaries(after: now)

        #expect(upcoming.count == 6)
        #expect(upcoming.allSatisfy { $0 > now })

        var step = countdown.remainingSteps(at: now)
        #expect(step == 6)
        for boundary in upcoming {
            #expect(countdown.remainingSteps(at: boundary.addingTimeInterval(-0.001)) == step)
            #expect(countdown.remainingSteps(at: boundary) == step - 1)
            step -= 1
        }
        #expect(step == 0)
    }

    /// A boundary is excluded once reached, so a redraw firing exactly on it schedules the next
    /// one rather than itself again.
    @Test func aBoundaryReachedIsNotScheduledAgain() throws {
        let countdown = try Self.countdown()
        let boundary = countdown.stepBoundaries[3]

        #expect(countdown.upcomingBoundaries(after: boundary).first == countdown.stepBoundaries[4])
    }

    /// A duration too short to divide evenly still yields twelve distinct, ordered boundaries.
    @Test func aOneSecondTimerStillHasOrderedBoundaries() throws {
        let countdown = try Self.countdown(seconds: 1)
        let boundaries = countdown.stepBoundaries

        #expect(zip(boundaries, boundaries.dropFirst()).allSatisfy { $0 < $1 })
        #expect(countdown.remainingSteps(at: countdown.startsAt) == 12)
        #expect(countdown.remainingSteps(at: countdown.expiresAt) == 0)
    }

    // MARK: - Drawing

    @Test func theSectorIsBoundedToAFullDisc() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)

        #expect(MessageRetentionSector(fraction: 0).path(in: rect).isEmpty)
        #expect(MessageRetentionSector(fraction: -1).path(in: rect).isEmpty)
        #expect(MessageRetentionSector(fraction: 1).path(in: rect).boundingRect == rect)
        #expect(MessageRetentionSector(fraction: 4).path(in: rect).boundingRect == rect)
        // Half the pie, clockwise from twelve o'clock, is the right half of the disc.
        let half = MessageRetentionSector(fraction: 0.5).path(in: rect).boundingRect
        #expect(abs(half.minX - 5) < 0.01)
        #expect(abs(half.maxX - 10) < 0.01)
    }

    // MARK: - Grouped run visibility

    /// Earlier messages in a two-message grouped run keep their own disappearing countdown while
    /// routine timestamps stay grouped on the last row, and non-disappearing rows keep no footer.
    @MainActor
    @Test func groupedDisappearingRunShowsCountdownOnBothRowsWhileGroupingTimestampOnLast() throws {
        let first = MessageItem(
            id: "msg-1",
            retentionSeconds: Self.hour,
            retentionExpiresAt: Self.expiry,
            senderName: "Alice",
            body: "First disappearing message",
            sentAt: Self.date(Self.expiry, plus: -3_600),
            isOutgoing: false
        )
        let second = MessageItem(
            id: "msg-2",
            retentionSeconds: Self.hour,
            retentionExpiresAt: Self.expiry + 30,
            senderName: "Alice",
            body: "Second disappearing message",
            sentAt: Self.date(Self.expiry, plus: -3_570),
            isOutgoing: false
        )
        let plain = MessageItem(
            id: "msg-3",
            senderName: "Alice",
            body: "Ordinary message",
            sentAt: Self.date(Self.expiry, plus: -3_600),
            isOutgoing: false
        )

        let runStart = MessageClusterPosition(startsCluster: true, endsCluster: false)
        let runEnd = MessageClusterPosition(startsCluster: false, endsCluster: true)
        let firstVisibility = MessageBubble.footerVisibility(cluster: runStart, message: first, indicator: .none)
        let secondVisibility = MessageBubble.footerVisibility(cluster: runEnd, message: second, indicator: .none)
        let plainFirstVisibility = MessageBubble.footerVisibility(cluster: runStart, message: plain, indicator: .none)

        #expect(firstVisibility.showsRetentionCountdown)
        #expect(!firstVisibility.showsClusterFooter)
        #expect(firstVisibility.showsAnyMetadata)

        #expect(secondVisibility.showsRetentionCountdown)
        #expect(secondVisibility.showsClusterFooter)
        #expect(secondVisibility.showsAnyMetadata)

        #expect(!plainFirstVisibility.showsRetentionCountdown)
        #expect(!plainFirstVisibility.showsClusterFooter)
        #expect(!plainFirstVisibility.showsAnyMetadata)

        // And the two messages retain distinct countdown expiries.
        let firstCountdown = try #require(MessageRetentionCountdown(message: first))
        let secondCountdown = try #require(MessageRetentionCountdown(message: second))
        #expect(firstCountdown.expiresAt < secondCountdown.expiresAt)
    }
}
