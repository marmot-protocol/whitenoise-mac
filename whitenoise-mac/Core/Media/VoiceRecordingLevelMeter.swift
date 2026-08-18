//
//  VoiceRecordingLevelMeter.swift
//  whitenoise-mac
//

import CoreGraphics
import Foundation

/// Turns `AVAudioRecorder`'s decibel meters into the 0...1 bar heights the live recording waveform
/// draws, and decides how many bars a stretch of recorded audio is worth.
///
/// The mapping this replaces (`pow(10, average / 36)`) is a power ratio, and speech occupies a
/// narrow slice of it: an ordinary voice at -30…-15 dBFS came out between 0.15 and 0.38, and the
/// display curve then squeezed that into 0.43…0.65 of the bar height. Every bar landed mid-height,
/// so the strip read as a hedge rather than as a voice. Normalizing *in dB* across a speech-shaped
/// window instead puts the quiet parts near the floor and lets a raised voice reach the top, which
/// is the whole point of showing a waveform while the mic is hot.
nonisolated enum VoiceRecordingLevelMeter {
    /// One bar per 40 ms of recorded audio — 25 a second. This is the *audio* clock, not a repaint
    /// rate: `barsOwed` derives the bar count from `AVAudioRecorder.currentTime`, so the strip
    /// travels exactly one bar per 40 ms of sound whatever the metering task's wakeups do.
    static let sampleIntervalSeconds: Double = 0.04
    static var sampleInterval: Duration { .seconds(sampleIntervalSeconds) }

    /// The dB window the bars span. Below the floor is room noise; above the ceiling is clipping
    /// territory. `AVAudioRecorder` reports 0 dBFS at full scale and -160 for silence.
    static let floorDecibels: Float = -52
    static let ceilingDecibels: Float = -8

    /// Peaks are what the eye reads as "loud", but a peak-only meter twitches on every consonant.
    /// Mixing keeps the body of the bar tied to the average while transients still spike.
    static let peakWeight: CGFloat = 0.4

    /// Rise fast, fall slow — the asymmetry is what makes the strip read as speech. A symmetric
    /// filter either lags every onset or flickers in every gap between words. Written as time
    /// constants rather than per-sample coefficients so the feel survives a change of bar rate.
    static let attackSeconds: Double = 0.06
    static let releaseSeconds: Double = 0.24
    static var attack: CGFloat { smoothingCoefficient(forTimeConstant: attackSeconds) }
    static var release: CGFloat { smoothingCoefficient(forTimeConstant: releaseSeconds) }

    /// Silence still draws a visible sliver, so a speaker who pauses reads as a waveform at rest
    /// rather than as a control that died.
    static let minimumAmplitude: CGFloat = 0.06

    /// Cap on the retained history — 40 minutes of audio — so an interview-length recording cannot
    /// grow the buffer without bound. Only the sent waveform reads the history; the live strip
    /// reads its tail.
    static let maximumHistorySampleCount = 60_000

    /// How many bars this much recorded audio is worth that have not been drawn yet.
    ///
    /// The strip's horizontal speed is this function: bars come from the recorder's own clock, not
    /// from one-per-wakeup, so a late or bursty metering tick cannot make the waveform travel
    /// faster than the sound it stands for. `maximum` bounds the catch-up after a long stall.
    static func barsOwed(recordedSeconds: Double, alreadyMetered: Int, maximum: Int) -> Int {
        guard recordedSeconds.isFinite, recordedSeconds > 0 else { return 0 }
        let owed = Int((recordedSeconds / sampleIntervalSeconds).rounded(.down)) - alreadyMetered
        return min(max(0, owed), max(0, maximum))
    }

    /// The height this level asks for, before smoothing.
    static func amplitude(averagePower: Float, peakPower: Float) -> CGFloat {
        let mixed =
            decibelFraction(averagePower) * (1 - peakWeight)
            + decibelFraction(peakPower) * peakWeight
        return clamped(minimumAmplitude + (1 - minimumAmplitude) * mixed)
    }

    /// One step of the attack/release filter. `previous` is the last bar drawn, so the first sample
    /// of a recording lands where the level actually is instead of ramping up from the floor.
    static func smoothed(_ target: CGFloat, previous: CGFloat?) -> CGFloat {
        guard let previous else { return clamped(target) }
        let coefficient = target > previous ? attack : release
        return clamped(previous + (target - previous) * coefficient)
    }

    static func clamped(_ amplitude: CGFloat) -> CGFloat {
        guard amplitude.isFinite else { return minimumAmplitude }
        return min(1, max(minimumAmplitude, amplitude))
    }

    /// The per-bar share of an exponential approach to `timeConstant`, at the current bar rate.
    private static func smoothingCoefficient(forTimeConstant timeConstant: Double) -> CGFloat {
        guard timeConstant > 0 else { return 1 }
        return CGFloat(1 - exp(-sampleIntervalSeconds / timeConstant))
    }

    private static func decibelFraction(_ decibels: Float) -> CGFloat {
        // A meter read before the first `updateMeters()`, or on a channel that never carried
        // audio, can hand back a non-finite value. Treat it as silence rather than as a NaN
        // height, which would collapse the bar's frame instead of drawing the resting sliver.
        guard decibels.isFinite else { return 0 }
        let bounded = min(ceilingDecibels, max(floorDecibels, decibels))
        return CGFloat((bounded - floorDecibels) / (ceilingDecibels - floorDecibels))
    }
}
