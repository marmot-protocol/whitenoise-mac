//
//  VoiceRecordingWaveform.swift
//  whitenoise-mac
//

import CoreGraphics
import Foundation

/// Geometry for the live recording strip: narrow fixed-width bars at a fixed pitch, as many as the
/// composer is wide enough to hold.
///
/// Fixed width is the point. Dividing the available width by a fixed bar *count* — what the playback
/// waveform does, because it has a fixed number of samples to show — makes each bar as wide as a
/// finger in the composer, and it stops looking like a waveform. Here the count follows the width
/// instead, so the bars stay thin and the strip holds a few seconds of sound whatever the window
/// size.
nonisolated enum VoiceRecordingWaveform {
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2
    static var barPitch: CGFloat { barWidth + barSpacing }

    /// Ceiling on the tail the model keeps for the strip. Wide enough for a very wide window
    /// (2.5k points of waveform) and small enough that the observable copy on each bar stays
    /// trivial; the full-length history lives elsewhere.
    static let maximumWindowSampleCount = 512

    /// How many bars fit across `width`. The last bar needs no trailing gap, hence the `+ spacing`.
    static func barCount(forWidth width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 0 }
        return min(maximumWindowSampleCount, max(0, Int((width + barSpacing) / barPitch)))
    }

    /// The newest `barCount` levels, oldest first, clamped to what a bar can draw.
    ///
    /// Bars are positioned by their slot, and the strip advances by exactly one slot per bar the
    /// recorder's clock has earned (see `VoiceRecordingLevelMeter.barsOwed`). Nothing here is
    /// animated: the horizontal speed has to be constant, and an implicit animation retargeted on
    /// every new sample turns any scheduling lag into extra distance instead of a pause — the
    /// waveform accelerates for as long as the lag lasts.
    static func visibleLevels(window: [CGFloat], barCount: Int) -> [CGFloat] {
        guard barCount > 0 else { return [] }
        return window.suffix(barCount).map(VoiceRecordingLevelMeter.clamped)
    }

    /// The bars a stopped take draws: as many as fit, but never more than the take earned at the
    /// live strip's pace.
    ///
    /// The cap is what keeps the staged recording recognisable as the one just recorded. A
    /// two-second take was 50 bars of the composer's width while the mic was hot; stretching those
    /// two seconds across the whole bar once it stops changes the bar width, the spacing and the
    /// shape of the sound all at once, and the strip reads as a different control. `nil` seconds —
    /// a recorder that could not report a duration — fills the width instead of drawing nothing.
    static func stoppedBarCount(width: CGFloat, recordedSeconds: Double?) -> Int {
        let fitting = barCount(forWidth: width)
        guard let recordedSeconds else { return fitting }
        return min(
            fitting,
            VoiceRecordingLevelMeter.barsOwed(
                recordedSeconds: recordedSeconds,
                alreadyMetered: 0,
                maximum: maximumWindowSampleCount
            )
        )
    }

    /// The whole take on `barCount` bars, oldest first — the counterpart to `visibleLevels`, which
    /// keeps only the tail. Once the mic is off there is nothing left to travel past, so the strip
    /// shows the recording end to end rather than its last few seconds.
    static func condensedLevels(history: [CGFloat], barCount: Int) -> [CGFloat] {
        guard barCount > 0, !history.isEmpty else { return [] }
        return MediaWaveformAnalyzer.normalized(history, count: barCount)
            .map(VoiceRecordingLevelMeter.clamped)
    }

    /// How many metered levels a finished recording carries with it.
    ///
    /// Not the playback waveform's 36: the staged recording draws its own bar per 40 ms, and 36
    /// buckets spread over a minute-long take repeat each value across seven neighbouring bars —
    /// which rebuilds the wide stepped waveform out of thin bars. A take shorter than the ceiling
    /// keeps every bar it metered. Metering that never ran keeps the playback count, so the
    /// synthetic fallback waveform stays the size the transcript draws.
    static func storedSampleCount(forMeteredCount count: Int) -> Int {
        guard count > 0 else { return MediaWaveformAnalyzer.sampleCount }
        return min(count, maximumWindowSampleCount)
    }
}
