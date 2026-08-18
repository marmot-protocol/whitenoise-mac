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
}
