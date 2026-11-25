//
//  DisappearingMessageViews.swift
//  whitenoise-mac
//
//  Shared disappearing-message presentation and duration decomposition.
//

import SwiftUI

/// Units supported by the custom disappearing-timer editor. `seconds` keeps every exact core
/// value round-trippable, while `largestWholeUnit(for:)` gives display and editing one canonical
/// seconds-to-components conversion.
nonisolated enum DisappearingMessageDurationUnit: String, CaseIterable, Identifiable, Sendable {
    case seconds
    case minutes
    case hours
    case days
    case weeks

    var id: String { rawValue }

    var seconds: UInt64 {
        switch self {
        case .seconds: return 1
        case .minutes: return 60
        case .hours: return 3_600
        case .days: return 86_400
        case .weeks: return 604_800
        }
    }

    var label: String {
        switch self {
        case .seconds: return L10n.string("Seconds")
        case .minutes: return L10n.string("Minutes")
        case .hours: return L10n.string("Hours")
        case .days: return L10n.string("Days")
        case .weeks: return L10n.string("Weeks")
        }
    }

    func localizedDuration(_ count: UInt64) -> String {
        switch self {
        case .seconds: return L10n.plural("%llu seconds", count)
        case .minutes: return L10n.plural("%llu minutes", count)
        case .hours: return L10n.plural("%llu hours", count)
        case .days: return L10n.plural("%llu days", count)
        case .weeks: return L10n.plural("%llu weeks", count)
        }
    }

    static func largestWholeUnit(for seconds: UInt64) -> (unit: Self, count: UInt64)? {
        guard seconds > 0 else { return nil }
        let unit = allCases.reversed().first { seconds.isMultiple(of: $0.seconds) } ?? .seconds
        return (unit, seconds / unit.seconds)
    }
}

/// Selectable disappearing-message timer presets for a group. `custom` carries a
/// non-preset value returned by the core so the picker can still display it.
nonisolated enum DisappearingMessageOption: Hashable, Identifiable, Sendable {
    case off
    case oneHour
    case oneDay
    case oneWeek
    case oneMonth
    case custom(UInt64)

    static let presets: [DisappearingMessageOption] = [.off, .oneHour, .oneDay, .oneWeek, .oneMonth]
    static var allCases: [DisappearingMessageOption] { presets }

    var id: UInt64 { seconds }

    var seconds: UInt64 {
        switch self {
        case .off: return 0
        case .oneHour: return 3_600
        case .oneDay: return 86_400
        case .oneWeek: return 604_800
        case .oneMonth: return 2_592_000
        case .custom(let value): return value
        }
    }

    var label: String {
        switch self {
        case .off: return L10n.string("Off")
        case .oneHour: return L10n.plural("%llu hours", UInt64(1))
        case .oneDay: return L10n.plural("%llu days", UInt64(1))
        case .oneWeek: return L10n.plural("%llu weeks", UInt64(1))
        case .oneMonth: return L10n.plural("%llu months", UInt64(1))
        case .custom(let value): return Self.humanDuration(value)
        }
    }

    /// A whole-unit human duration for non-preset values (e.g. a 4-week timer reads "4 weeks"
    /// rather than a raw seconds count). Uses the largest unit that divides evenly.
    static func humanDuration(_ seconds: UInt64) -> String {
        guard let duration = DisappearingMessageDurationUnit.largestWholeUnit(for: seconds) else {
            return L10n.string("Off")
        }
        return duration.unit.localizedDuration(duration.count)
    }

    /// The matching preset for `seconds`, or a `.custom` wrapper when none match.
    static func option(for seconds: UInt64) -> DisappearingMessageOption {
        presets.first { $0.seconds == seconds } ?? .custom(seconds)
    }

    /// The presets plus the current value when it isn't already a preset, so the
    /// picker always has a tag matching the active selection.
    static func options(for seconds: UInt64) -> [DisappearingMessageOption] {
        let current = option(for: seconds)
        return presets.contains(current) ? presets : presets + [current]
    }
}

/// The subtitle under the conversation title. With disappearing messages on, the member count
/// stays and a compact timer sits beside it ("3 members · ⏱ 1d"), as on iOS; the spoken label
/// names both in full. With the timer off it is just the subtitle.
struct DisappearingMessageHeaderSubtitle: View {
    let durationSeconds: UInt64?
    /// The member count, or the direct chat's subtitle; may be empty.
    let subtitle: String

    @ViewBuilder
    var body: some View {
        Group {
            if let durationSeconds, durationSeconds > 0 {
                HStack(spacing: 3) {
                    if !subtitle.isEmpty {
                        Text(subtitle)
                        Text(verbatim: "·")
                    }
                    Image(systemName: "timer")
                    Text(DisappearingMessageDuration.compactLabel(seconds: durationSeconds))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.accessibilityLabel(subtitle: subtitle, durationSeconds: durationSeconds))
            } else {
                Text(subtitle)
            }
        }
        .foregroundStyle(WNColor.backgroundContentSecondary)
    }

    static func accessibilityLabel(subtitle: String, durationSeconds: UInt64) -> String {
        let duration = DisappearingMessageOption.option(for: durationSeconds).label
        guard !subtitle.isEmpty else {
            return String(format: L10n.string("Disappearing messages: %@"), duration)
        }
        return String(format: L10n.string("%@, Disappearing messages: %@"), subtitle, duration)
    }
}

/// Short spellings of a disappearing-message duration, for places with no room for "1 week".
nonisolated enum DisappearingMessageDuration {
    /// "1w", "1d", "8h", "1h 30m": weeks for exact multiples of seven days, otherwise at most two
    /// of days, hours, minutes and seconds. Matches iOS's header timer.
    static func compactLabel(seconds: UInt64, locale: Locale = AppLanguage.currentLocale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2

        let week: UInt64 = 604_800
        let clamped = min(seconds, UInt64(Int.max))
        if clamped > 0, clamped.isMultiple(of: week) {
            formatter.allowedUnits = [.weekOfMonth]
            if let label = formatter.string(from: DateComponents(weekOfMonth: Int(clamped / week))) {
                return label
            }
        }
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        let components = DateComponents(
            day: Int(clamped / 86_400),
            hour: Int(clamped % 86_400 / 3_600),
            minute: Int(clamped % 3_600 / 60),
            second: Int(clamped % 60)
        )
        return formatter.string(from: components) ?? DisappearingMessageOption.option(for: seconds).label
    }
}

/// One message's own disappearing countdown, in twelve discrete steps (T11, M06).
///
/// Built from the message's actual `retentionSeconds` and `retentionExpiresAt`. Missing or
/// nonpositive values give no countdown at all, so there is never a fabricated indicator. The
/// value never schedules or performs a deletion: MDK owns expiry. It only says which step to
/// draw and when that step next changes.
nonisolated struct MessageRetentionCountdown: Equatable, Sendable {
    static let stepCount = 12

    let durationSeconds: UInt64
    let expiresAt: Date

    init?(retentionSeconds: UInt64?, retentionExpiresAt: UInt64?) {
        guard let retentionSeconds, retentionSeconds > 0,
            let retentionExpiresAt, retentionExpiresAt > 0
        else { return nil }
        durationSeconds = retentionSeconds
        expiresAt = Date(timeIntervalSince1970: TimeInterval(retentionExpiresAt))
    }

    init?(message: MessageItem) {
        self.init(retentionSeconds: message.retentionSeconds, retentionExpiresAt: message.retentionExpiresAt)
    }

    /// When the message's retention window began: its expiry less its duration.
    var startsAt: Date {
        expiresAt.addingTimeInterval(-TimeInterval(durationSeconds))
    }

    /// The twelve instants at which one step runs out, in order. The last is the expiry itself.
    var stepBoundaries: [Date] {
        let duration = TimeInterval(durationSeconds)
        return (1...Self.stepCount).map { step in
            step == Self.stepCount
                ? expiresAt
                : startsAt.addingTimeInterval(duration * Double(step) / Double(Self.stepCount))
        }
    }

    /// The steps left at `date`, always in `0...12`: 12 for a new message (or a clock that
    /// reads earlier than its start), 0 from its expiry on. Counted against the same boundaries
    /// the indicator schedules, so a redraw at a boundary always shows the step that begins there.
    func remainingSteps(at date: Date) -> Int {
        Self.stepCount - stepBoundaries.filter { $0 <= date }.count
    }

    /// The boundaries still ahead of `date`, which are the only redraws the indicator asks for.
    /// Empty once the message has expired, so a row the core still shows past its expiry is drawn
    /// once at zero and never rescheduled.
    func upcomingBoundaries(after date: Date) -> [Date] {
        stepBoundaries.filter { $0 > date }
    }
}

/// A message's countdown in its footer: a ring with the remaining twelfths filled clockwise from
/// twelve o'clock. Neither `Gauge` nor an SF Symbol provides this at metadata size. Macs have no
/// accessory gauge styles small enough, and no symbol set has twelve steps. So this is a bounded
/// custom pie in the footer's own foreground, which pairs it with whichever bubble it is on.
///
/// Redraws only at step boundaries, through a `TimelineView` with an explicit schedule. That
/// means no per-second timer, no animation, and no work once the row is discarded. The frame is a
/// hidden `circle` symbol in the footer's font. `MessageBubble`'s inline metadata spacer reserves
/// that same symbol, so a step change never moves the footer or rewraps the body text.
struct MessageRetentionIndicator: View {
    let countdown: MessageRetentionCountdown

    var body: some View {
        TimelineView(.explicit(countdown.upcomingBoundaries(after: .now))) { context in
            MessageRetentionPie(remainingSteps: countdown.remainingSteps(at: max(context.date, .now)))
        }
        .accessibilityHidden(true)
    }
}

/// The drawing behind `MessageRetentionIndicator`, for a fixed step.
struct MessageRetentionPie: View {
    let remainingSteps: Int

    var body: some View {
        Image(systemName: "circle")
            .hidden()
            .overlay {
                ZStack {
                    Circle().strokeBorder(lineWidth: 1)
                    MessageRetentionSector(
                        fraction: Double(remainingSteps) / Double(MessageRetentionCountdown.stepCount)
                    )
                    .padding(2)
                }
                .aspectRatio(1, contentMode: .fit)
            }
    }
}

/// The filled part of the pie: `fraction` of a disc, clockwise from twelve o'clock.
nonisolated struct MessageRetentionSector: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        let fraction = min(1, max(0, fraction))
        var path = Path()
        guard fraction > 0 else { return path }
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard fraction < 1 else {
            path.addEllipse(
                in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            return path
        }
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

#Preview("Retention countdown") {
    HStack(spacing: 8) {
        ForEach([12, 9, 6, 3, 1, 0], id: \.self) { step in
            MessageRetentionPie(remainingSteps: step)
        }
        if let countdown = MessageRetentionCountdown(
            retentionSeconds: 3_600,
            retentionExpiresAt: UInt64(Date.now.timeIntervalSince1970) + 1_800
        ) {
            MessageRetentionIndicator(countdown: countdown)
        }
    }
    .font(MessageTypography.footer)
    .foregroundStyle(WNColor.messageReceivedSecondaryContent)
    .padding()
}

#Preview("Header subtitle") {
    VStack(alignment: .leading, spacing: 8) {
        DisappearingMessageHeaderSubtitle(durationSeconds: 86_400, subtitle: "3 members")
        DisappearingMessageHeaderSubtitle(durationSeconds: 604_800, subtitle: "")
        DisappearingMessageHeaderSubtitle(durationSeconds: 0, subtitle: "3 members")
    }
    .wnFont(.medium10)
    .padding()
}
