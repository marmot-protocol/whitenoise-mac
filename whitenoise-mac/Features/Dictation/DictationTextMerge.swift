import Foundation

/// Joins dictated text onto the existing draft. Dictation never replaces what was typed: the
/// words land after it, separated the way the script expects.
nonisolated enum DictationTextMerge {
    static func merged(draft: String, transcript: String) -> String {
        let dictated = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictated.isEmpty else { return draft }
        guard let last = draft.last else { return dictated }
        if last.isWhitespace || !needsSeparator(after: last, before: dictated) {
            return draft + dictated
        }
        return draft + " " + dictated
    }

    /// Scripts written without spaces (Chinese, Japanese) join directly.
    private static func needsSeparator(after last: Character, before dictated: String) -> Bool {
        guard let first = dictated.first else { return false }
        return !(isUnspacedScript(last) && isUnspacedScript(first))
    }

    private static func isUnspacedScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
                true
            default:
                false
            }
        }
    }
}
