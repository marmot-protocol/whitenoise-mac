import Foundation

/// Text recognized so far: settled text, then the recognizer's current guess for the words still
/// being spoken.
nonisolated struct DictationTranscript: Equatable, Sendable {
    var finalized = ""
    var volatile = ""

    var text: String { finalized + volatile }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A final result settles its audio range, replacing the guess for it.
    mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
    }
}
