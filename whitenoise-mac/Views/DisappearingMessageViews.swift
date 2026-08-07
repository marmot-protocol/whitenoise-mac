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

/// The shared subtitle used below conversation and group-detail titles. Active timers render as
/// an icon plus compact duration; inactive timers retain the surface-specific fallback text.
struct DisappearingMessageHeaderSubtitle: View {
    let durationSeconds: UInt64?
    let fallback: String

    @ViewBuilder
    var body: some View {
        Group {
            if let durationSeconds, durationSeconds > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text(DisappearingMessageOption.option(for: durationSeconds).label)
                }
            } else {
                Text(fallback)
            }
        }
        .foregroundStyle(WNColor.backgroundContentSecondary)
    }
}
