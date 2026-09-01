import Foundation

/// The rates an audio message can be played back at.
///
/// Mirrors the iOS client, whose audio bubble cycles a single badge through 1x, 1.5x and 2x and
/// wraps back round. Keeping the same three rates in the same order means a voice note sounds the
/// same on both clients, and the badge reads the same way to someone who moves between them.
nonisolated enum AudioPlaybackSpeed: CaseIterable, Sendable {
    case normal
    case oneAndAHalf
    case double

    /// What a row starts at, and what the cycle wraps back to.
    static let initial = AudioPlaybackSpeed.normal

    /// The `AVAudioPlayer.rate` this speed asks for.
    ///
    /// `AVAudioPlayer` only honours a rate other than `1` when `enableRate` was set *before*
    /// `prepareToPlay()`, which is why `MessageAudioPlaybackController` arms it while preparing
    /// the player rather than when the badge is first clicked.
    var rate: Float {
        switch self {
        case .normal: 1
        case .oneAndAHalf: 1.5
        case .double: 2
        }
    }

    /// How the rate is written: one fraction digit at most, so 1 and 2 stay whole rather than
    /// showing a pointless `.0`, and 1.5 keeps its half.
    private static let rateStyle = FloatingPointFormatStyle<Float>.number.precision(.fractionLength(0...1))

    /// The badge's text, in `locale`'s notation.
    ///
    /// Not a catalog string — the only part that varies between languages is the decimal separator,
    /// and seven of the nine we ship write 1.5 as `1,5`. A format style takes that from the locale's
    /// own data, which is both correct everywhere and one fewer numeral for a translator to get
    /// wrong. The `x` multiplier suffix is shown verbatim in every language, as it is on iOS.
    func label(locale: Locale) -> String {
        "\(rate.formatted(Self.rateStyle.locale(locale)))x"
    }

    /// The speed one click on the badge moves to, wrapping from the last case back to the first.
    var next: AudioPlaybackSpeed {
        let speeds = Self.allCases
        guard let index = speeds.firstIndex(of: self) else { return Self.initial }
        return speeds[(index + 1) % speeds.count]
    }
}
