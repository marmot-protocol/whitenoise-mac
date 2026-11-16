import Foundation

/// What a finished dictation recognized.
nonisolated struct DictationResult: Equatable, Sendable {
    var text: String
    /// False when recognition failed or timed out before settling, so the text may be missing
    /// words and the person should check it before sending.
    var isComplete: Bool
}

/// A transcription in progress.
nonisolated struct DictationSession {
    /// Stops listening and returns everything recognized.
    var finish: @MainActor () async -> DictationResult
    /// Stops listening and discards the text. Synchronous, so no transcript update can land
    /// after it returns.
    var cancel: @MainActor () -> Void
}

/// The speech recognizer behind dictation. Production uses `SpeechAnalyzer` (macOS 26); tests
/// inject a scripted one.
nonisolated struct DictationEngine {
    /// Starts listening. `onUpdate` receives the transcript as it changes; `onEnded` reports that
    /// recognition failed by itself, after which the session's `finish` returns what was heard.
    var start:
        @MainActor (
            _ localeIdentifiers: [String],
            _ onUpdate: @escaping @MainActor (DictationTranscript) -> Void,
            _ onEnded: @escaping @MainActor () -> Void
        ) async throws -> DictationSession

    static var live: DictationEngine {
        if #available(macOS 26.0, *) {
            return DictationEngine(start: SpeechAnalyzerDictation.start)
        }
        return DictationEngine { _, _, _ in throw DictationFailure.startFailed }
    }
}

/// Where dictation can run at all.
nonisolated enum DictationSupport {
    /// `SpeechAnalyzer` arrived in macOS 26. Older systems don't offer the feature rather than
    /// falling back to the server-backed `SFSpeechRecognizer`.
    static var isSupportedOS: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// One dictation transcribes at most this much speech, then finishes by itself.
    static let maximumDuration: Duration = .seconds(120)
}
