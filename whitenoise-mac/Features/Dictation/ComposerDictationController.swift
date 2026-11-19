import Foundation
import Observation

/// Something the composer says about the last dictation, shown above the message field.
nonisolated enum DictationNotice: Equatable {
    /// Dictation could not start; the message says why.
    case failed(String)
    /// The person turned microphone access off; only System Settings can turn it back on.
    case microphoneDenied
    /// macOS is fetching the speech model. Goes away by itself once the model is ready.
    case modelDownloading
    /// Recognition failed or timed out before settling: the words are in the field, but may be
    /// missing some.
    case stoppedEarly

    /// What a failed start tells the person, or nil for a start that was cancelled.
    init?(startError error: Error) {
        switch error {
        case is CancellationError: return nil
        case DictationFailure.permissionDenied: self = .microphoneDenied
        case DictationFailure.modelDownloading: self = .modelDownloading
        default:
            self = .failed((error as? LocalizedError)?.errorDescription ?? L10n.string("Dictation couldn't start."))
        }
    }

    var message: String {
        switch self {
        case .failed(let message): message
        case .microphoneDenied: DictationFailure.permissionDenied.errorDescription ?? ""
        case .modelDownloading: DictationFailure.modelDownloading.errorDescription ?? ""
        case .stoppedEarly: L10n.string("Dictation stopped early. Check the message before sending.")
        }
    }

    /// Whether the notice offers to open the Microphone pane of System Settings.
    var opensMicrophoneSettings: Bool { self == .microphoneDenied }

    /// The Microphone pane of Privacy & Security.
    static let microphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
}

/// Drives dictation into one conversation's composer: click to start listening, click again to
/// stop, and the recognized words join the draft. On the Mac the words never send themselves —
/// iOS sends on release of a hold, but a click-to-stop toggle has no gesture that says "send",
/// so the person reads the text in the field and sends it as they would anything they typed.
///
/// macOS transcribes on device; the audio is never written to disk or sent anywhere.
@MainActor
@Observable
final class ComposerDictationController {
    enum State: Equatable {
        case idle
        /// Waiting for permission and the recognizer to start.
        case starting
        case listening
        /// Stopped; the recognizer is settling the last words.
        case finishing

        var isActive: Bool { self != .idle }
    }

    private(set) var state: State = .idle
    private(set) var transcript = DictationTranscript()
    private(set) var notice: DictationNotice?

    /// One start-to-finish run. Every callback and task holds the attempt it was made for and
    /// checks it is still `current` before touching state, so a cancelled run's late transcript
    /// update or finish can never land on the next one. This is an identity rather than a
    /// counter, and it cannot be replaced by cancelling a task: the recognizer's update callback
    /// is not a task this controller owns, and it may still be queued on the main actor when the
    /// session is cancelled.
    private final class Attempt {
        var session: DictationSession?
        var stopRequestedWhileStarting = false
        var onFinish: ((DictationResult) -> Void)?
    }

    @ObservationIgnored private let engine: DictationEngine
    @ObservationIgnored private let maximumDuration: Duration
    @ObservationIgnored private var current: Attempt?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?

    var isActive: Bool { state.isActive }

    init(engine: DictationEngine = .live, maximumDuration: Duration = DictationSupport.maximumDuration) {
        self.engine = engine
        self.maximumDuration = maximumDuration
    }

    isolated deinit {
        startTask?.cancel()
        limitTask?.cancel()
        finishTask?.cancel()
        current?.session?.cancel()
    }

    /// Starts listening. `onFinish` receives the recognized text once the person stops (or the
    /// duration limit does); nothing is delivered for a cancelled run or a failed start.
    func begin(localeIdentifiers: [String], onFinish: @escaping (DictationResult) -> Void) {
        guard state == .idle else { return }
        let attempt = Attempt()
        attempt.onFinish = onFinish
        current = attempt
        state = .starting
        transcript = DictationTranscript()
        notice = nil
        startTask = Task { [weak self, engine] in
            do {
                let session = try await engine.start(
                    localeIdentifiers,
                    { [weak self] update in
                        guard let self, self.current === attempt, self.state.isActive else { return }
                        self.transcript = update
                    },
                    { [weak self] in self?.requestFinish(attempt) }
                )
                guard let self, self.current === attempt, self.state == .starting else {
                    session.cancel()
                    return
                }
                attempt.session = session
                self.startTask = nil
                self.state = .listening
                self.armDurationLimit(for: attempt)
                if attempt.stopRequestedWhileStarting {
                    self.finish(attempt)
                }
            } catch {
                guard let self, self.current === attempt else { return }
                self.reset()
                self.notice = DictationNotice(startError: error)
            }
        }
    }

    /// The person clicked stop: hand back what was recognized. A stop while the recognizer is
    /// still starting finishes as soon as it is listening.
    func stop() {
        guard let attempt = current else { return }
        requestFinish(attempt)
    }

    /// Finishes `attempt` if it is still the current run: a stop from the person, or the
    /// recognizer failing by itself, which delivers what was heard as incomplete.
    private func requestFinish(_ attempt: Attempt) {
        guard current === attempt else { return }
        switch state {
        case .starting:
            attempt.stopRequestedWhileStarting = true
        case .listening:
            finish(attempt)
        case .idle, .finishing:
            return
        }
    }

    /// Discards the run, including one whose last words are still settling.
    func cancel() {
        guard state.isActive else { return }
        reset()
    }

    func dismissNotice() {
        notice = nil
    }

    /// The speech model's status changed. A "downloading" notice goes away once the model is
    /// ready, so the person knows they can dictate now.
    func modelStatusChanged(_ status: DictationModelStatus) {
        guard notice == .modelDownloading, status == .ready else { return }
        notice = nil
    }

    private func finish(_ attempt: Attempt) {
        guard state == .listening, let session = attempt.session else { return }
        limitTask?.cancel()
        limitTask = nil
        state = .finishing
        finishTask = Task { [weak self] in
            let result = await session.finish()
            guard let self, self.current === attempt else { return }
            let onFinish = attempt.onFinish
            self.reset()
            if !result.isComplete, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.notice = .stoppedEarly
            }
            onFinish?(result)
        }
    }

    private func armDurationLimit(for attempt: Attempt) {
        limitTask?.cancel()
        limitTask = Task { [weak self, maximumDuration] in
            do {
                try await Task.sleep(for: maximumDuration)
            } catch {
                return
            }
            guard let self, self.current === attempt, self.state == .listening else { return }
            self.finish(attempt)
        }
    }

    private func reset() {
        let session = current?.session
        current = nil
        startTask?.cancel()
        startTask = nil
        limitTask?.cancel()
        limitTask = nil
        finishTask?.cancel()
        finishTask = nil
        state = .idle
        transcript = DictationTranscript()
        session?.cancel()
    }
}
