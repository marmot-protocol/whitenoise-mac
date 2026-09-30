//
//  DisappearingCustomDuration.swift
//  whitenoise-mac
//
//  The "Custom…" disappearing-message timer as it is being typed: a whole count and a unit.
//

import Foundation

/// A custom disappearing-message duration, held as the text the reader typed.
///
/// The count stays an exactly parsed decimal string: `UInt64.Stride` is `Int`, so any range-based
/// numeric control spanning past `Int.max` traps in stride math, and narrowing to `Int` silently
/// clamps large core values. Validation rejects rather than clamps, so a valid core value
/// round-trips through Set unchanged and nothing is silently truncated.
nonisolated struct DisappearingCustomDuration: Equatable, Sendable {
    var text = "1"
    var unit = DisappearingMessageDurationUnit.days

    /// Prefilled from the group's current timer, in the largest unit that divides it evenly,
    /// so a 4-week timer opens as "4 weeks". An off timer opens as one day.
    init(seconds: UInt64) {
        guard let duration = DisappearingMessageDurationUnit.largestWholeUnit(for: seconds) else { return }
        text = String(duration.count)
        unit = duration.unit
    }

    /// The entered count, exactly parsed; `nil` for anything that isn't a decimal `UInt64`.
    var count: UInt64? {
        UInt64(text.trimmingCharacters(in: .whitespaces))
    }

    /// The entered duration in seconds, or `nil` when it isn't a positive value that fits
    /// `UInt64`. Bounds the *total* (count × unit), not a per-unit cap, so large-but-valid values
    /// commit.
    var seconds: UInt64? {
        guard let count, count >= 1 else { return nil }
        let (seconds, overflow) = count.multipliedReportingOverflow(by: unit.seconds)
        return overflow ? nil : seconds
    }

    /// One more, saturating at the `UInt64` bound. Does nothing to text that isn't a count.
    mutating func increment() {
        guard let count, count < UInt64.max else { return }
        text = String(count + 1)
    }

    /// One fewer, stopping at 1: a zero-length timer is "Off", which is a preset, not a custom.
    mutating func decrement() {
        guard let count, count > 1 else { return }
        text = String(count - 1)
    }
}
