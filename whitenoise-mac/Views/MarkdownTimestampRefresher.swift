//
//  MarkdownTimestampRefresher.swift
//  whitenoise-mac
//
//  Draws a Markdown document with its `<t:…>` timestamps (MarmotKit 0.13) formatted for this
//  moment: the environment's locale, the current time zone and, for `relative` styles, the clock.
//  A time zone or clock change re-formats at once, and a document with a relative timestamp ticks
//  through a `TimelineView`, which only runs while the bubble is on screen.
//

import AppKit
import MarmotKit
import SwiftUI

struct MarkdownTimestampRefresher<Content: View>: View {
    @Environment(\.locale) private var locale
    /// Bumped on time zone and clock changes, which re-format without changing anything SwiftUI
    /// already observes. Not a staleness token: nothing is cancelled or compared against it; it
    /// only forces a re-format after a system clock or time zone notification.
    @State private var systemClockChangeCount = 0
    let document: MarkdownDisplayDocument
    @ViewBuilder let content: (MarkdownDisplayDocument) -> Content

    var body: some View {
        Group {
            if document.timestamps == .relative {
                TimelineView(RelativeTimestampSchedule(dates: document.relativeTimestampDates)) { context in
                    content(refreshed(at: context.date))
                }
            } else {
                content(refreshed(at: Date()))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            systemClockChangeCount &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
            systemClockChangeCount &+= 1
        }
    }

    private func refreshed(at now: Date) -> MarkdownDisplayDocument {
        // Read only to subscribe this body to clock changes; the value itself is unused.
        _ = systemClockChangeCount
        return document.refreshingTimestamps(now: now, locale: locale, timeZone: .autoupdatingCurrent)
    }
}

/// Ticks often only while a relative timestamp is changing quickly: every 10 seconds within a
/// minute of the nearest instant, every minute within an hour, and hourly beyond that.
struct RelativeTimestampSchedule: TimelineSchedule {
    let dates: [Date]

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, dates: dates)
    }

    /// The step from `date` to the next tick: the smallest any instant asks for. An instant still
    /// ahead also caps the step so the tick lands just inside its next, faster band — stepping a
    /// whole band from exactly an hour out would land on the instant itself and hold "in 1 hour"
    /// for that entire last hour.
    static func interval(at date: Date, dates: [Date]) -> TimeInterval {
        dates.map { interval(toward: $0.timeIntervalSince(date)) }.min() ?? 3600
    }

    /// `offset` is how far the instant is ahead of the tick (negative once it has passed).
    private static func interval(toward offset: TimeInterval) -> TimeInterval {
        let distance = abs(offset)
        let (step, bandEdge): (TimeInterval, TimeInterval) =
            distance < 60 ? (10, 0) : distance < 3600 ? (60, 60) : (3600, 3600)
        // A passed instant only moves away, into slower bands, so a whole step never skips one.
        guard offset > 0 else { return step }
        return min(step, max(1, distance - bandEdge + 1))
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date
        let dates: [Date]

        mutating func next() -> Date? {
            let current = upcoming
            upcoming = current.addingTimeInterval(RelativeTimestampSchedule.interval(at: current, dates: dates))
            return current
        }
    }
}

#Preview {
    let now = Int64(Date().timeIntervalSince1970)
    let document = MarkdownDisplayDocument(
        document: MarkdownDocumentFfi(
            blocks: [
                .paragraph(inlines: [
                    .text(content: "Posted "),
                    .timestamp(unixSeconds: now - 30, style: .relative),
                    .text(content: ", meeting on "),
                    .timestamp(unixSeconds: now + 86_400, style: .longDateTime),
                ])
            ],
            truncated: false,
            blankLinesBefore: Data([0])
        )
    )
    MarkdownTimestampRefresher(document: document) { refreshed in
        Text(refreshed.inlineParagraph ?? AttributedString())
    }
    .padding()
}
