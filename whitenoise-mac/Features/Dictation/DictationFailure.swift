import Foundation

/// Why dictation could not start.
nonisolated enum DictationFailure: LocalizedError, Equatable {
    case permissionDenied
    case unsupportedLanguage
    /// macOS is downloading the speech model; the person tries again after.
    case modelDownloading
    case startFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            L10n.string("Microphone access is needed to dictate messages.")
        case .unsupportedLanguage:
            L10n.string("Dictation isn't available for your language.")
        case .modelDownloading:
            L10n.string("macOS is downloading the speech model for your language. Try again in a moment.")
        case .startFailed:
            L10n.string("Dictation couldn't start.")
        }
    }
}
