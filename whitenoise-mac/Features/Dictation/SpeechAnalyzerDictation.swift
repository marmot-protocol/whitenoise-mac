// coverage:ignore-file
// Drives the microphone and Apple's on-device recognizer, neither of which a unit test can run;
// everything that decides what to do with the result lives in tested files beside this one.

import AVFoundation
import Foundation
import OSLog
import Speech
import Synchronization

nonisolated enum DictationDiagnostics {
    static let log = Logger(subsystem: "dev.ipf.whitenoise.mac", category: "dictation")
}

/// The on-device recognizer for one language. `SpeechTranscriber` is Apple's newer model;
/// `DictationTranscriber` is the keyboard-dictation model, which more Macs and languages support.
@available(macOS 26.0, *)
nonisolated enum DictationRecognizer: Sendable {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber): transcriber
        case .dictation(let transcriber): transcriber
        }
    }

    /// The first candidate language either model supports, preferring `SpeechTranscriber` for
    /// each language before moving to the next.
    static func resolve(_ identifiers: [String]) async -> DictationRecognizer? {
        let speechAvailable = SpeechTranscriber.isAvailable
        for identifier in identifiers {
            let requested = Locale(identifier: identifier)
            if speechAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
                return .speech(
                    SpeechTranscriber(
                        locale: locale,
                        transcriptionOptions: [],
                        reportingOptions: [.volatileResults, .fastResults],
                        attributeOptions: []
                    ))
            }
            if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
                return .dictation(
                    DictationTranscriber(
                        locale: locale,
                        contentHints: [.shortForm],
                        transcriptionOptions: [.punctuation],
                        reportingOptions: [.volatileResults, .frequentFinalization],
                        attributeOptions: []
                    ))
            }
        }
        return nil
    }

    var locale: Locale? {
        switch self {
        case .speech(let transcriber): transcriber.selectedLocales.first
        case .dictation(let transcriber): transcriber.selectedLocales.first
        }
    }

    /// Recognized text and whether it is final, in the order the recognizer reports it.
    func results() -> AsyncThrowingStream<(text: String, isFinal: Bool), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch self {
                    case .speech(let transcriber):
                        for try await result in transcriber.results {
                            continuation.yield((String(result.text.characters), result.isFinal))
                        }
                    case .dictation(let transcriber):
                        for try await result in transcriber.results {
                            continuation.yield((String(result.text.characters), result.isFinal))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@available(macOS 26.0, *)
enum SpeechAnalyzerDictation {
    /// Starts on-device transcription from the microphone.
    static func start(
        localeIdentifiers: [String],
        onUpdate: @escaping @MainActor (DictationTranscript) -> Void,
        onEnded: @escaping @MainActor () -> Void
    ) async throws -> DictationSession {
        guard await requestMicrophoneAccess() else {
            throw DictationFailure.permissionDenied
        }
        try Task.checkCancellation()
        guard let recognizer = await DictationRecognizer.resolve(localeIdentifiers) else {
            throw DictationFailure.unsupportedLanguage
        }
        switch await AssetInventory.status(forModules: [recognizer.module]) {
        case .installed:
            break
        case .unsupported:
            throw DictationFailure.unsupportedLanguage
        case .supported, .downloading:
            // A start cancelled while the inventory answered doesn't ask macOS for a download.
            try Task.checkCancellation()
            DictationModelInstaller.shared.install(localeIdentifiers: localeIdentifiers)
            throw DictationFailure.modelDownloading
        @unknown default:
            throw DictationFailure.unsupportedLanguage
        }
        try Task.checkCancellation()

        let pipeline = SpeechAnalyzerPipeline(recognizer: recognizer)
        do {
            // Cancelling the start (Esc, the X, switching chats) must reach a pipeline that is
            // still loading the model, or the microphone stays on after the composer shows idle.
            try await withTaskCancellationHandler {
                try await pipeline.start(onUpdate: onUpdate, onEnded: onEnded)
            } onCancel: {
                Task { @MainActor in pipeline.cancel() }
            }
            try Task.checkCancellation()
        } catch {
            pipeline.cancel()
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            DictationDiagnostics.log.error("Dictation failed to start: \(String(describing: error), privacy: .public)")
            throw DictationFailure.startFailed
        }
        return DictationSession(
            finish: { await pipeline.finish() },
            cancel: { pipeline.cancel() }
        )
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: false
        @unknown default: false
        }
    }
}

/// Microphone → format conversion → `SpeechAnalyzer` → transcript.
@available(macOS 26.0, *)
@MainActor
private final class SpeechAnalyzerPipeline {
    /// How long the recognizer may take to settle the last words after stop.
    private static let finishTimeout: Duration = .seconds(4)

    private let recognizer: DictationRecognizer
    private let analyzer: SpeechAnalyzer
    private let capture = DictationAudioCapture()
    private let input: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var transcript = DictationTranscript()
    private var resultsFailed = false
    private var ended = false

    init(recognizer: DictationRecognizer) {
        self.recognizer = recognizer
        analyzer = SpeechAnalyzer(
            modules: [recognizer.module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        (input, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    func start(
        onUpdate: @escaping @MainActor (DictationTranscript) -> Void,
        onEnded: @escaping @MainActor () -> Void
    ) async throws {
        let naturalFormat = capture.naturalFormat
        guard
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [recognizer.module],
                considering: naturalFormat
            )
        else {
            DictationDiagnostics.log.error(
                "The recognizer offered no audio format for \(naturalFormat.description, privacy: .public)")
            throw DictationFailure.startFailed
        }

        let results = recognizer.results()
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in results {
                    guard let self, !Task.isCancelled else { return }
                    self.transcript.apply(result.text, isFinal: result.isFinal)
                    onUpdate(self.transcript)
                }
            } catch {
                guard let self else { return }
                self.resultsFailed = true
                DictationDiagnostics.log.error(
                    "Dictation results ended: \(String(describing: type(of: error)), privacy: .public)")
                // Nothing more will be recognized: give the microphone back now and let the
                // controller finish, which hands back what was heard as incomplete.
                guard !self.ended else { return }
                self.stopListening()
                onEnded()
            }
        }

        // Audio captured while the model loads waits in the stream. A cancel that landed while
        // the format was being chosen must not open the microphone; no suspension separates this
        // check from `capture.start`, so a later cancel finds the capture running and stops it.
        try Task.checkCancellation()
        guard !ended else { throw CancellationError() }
        let continuation = inputContinuation
        try capture.start(convertingTo: format) { continuation.yield($0) }

        // `start(inputSequence:)` returns once analysis is running, so a failure to load the model
        // or start reaches the caller before the session is handed out.
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: input)
    }

    /// Stops the microphone and closes the input; safe to call repeatedly.
    func stopListening() {
        capture.stop()
        inputContinuation.finish()
    }

    func finish() async -> DictationResult {
        guard !ended else { return DictationResult(text: transcript.text, isComplete: false) }
        ended = true
        // The microphone goes back as soon as listening stops, before the recognizer settles.
        stopListening()
        let analyzer = analyzer
        let resultsTask = resultsTask
        let finalized = await Self.complete(within: Self.finishTimeout) { () -> Bool in
            var finalized = true
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                finalized = false
                DictationDiagnostics.log.error(
                    "Dictation didn't finalize: \(String(describing: error), privacy: .public)")
                await analyzer.cancelAndFinishNow()
            }
            await resultsTask?.value
            return finalized
        }
        if finalized == nil {
            DictationDiagnostics.log.error("Dictation timed out finalizing")
            Task { await analyzer.cancelAndFinishNow() }
            resultsTask?.cancel()
        }
        return DictationResult(text: transcript.text, isComplete: finalized == true && !resultsFailed)
    }

    /// Discards the session without waiting for the recognizer to wind down.
    func cancel() {
        guard !ended else { return }
        ended = true
        stopListening()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    /// Runs `work` and returns its result, or nil when it doesn't finish in time, without
    /// waiting for a recognizer that ignores cancellation.
    private static func complete(
        within timeout: Duration,
        _ work: @escaping @Sendable () async -> Bool
    ) async -> Bool? {
        let gate = DictationResumeGate()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task {
                gate.resume(await work())
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(nil)
            }
        }
    }
}

/// Resumes a continuation once, from whichever side finishes first.
nonisolated private final class DictationResumeGate: Sendable {
    private let continuation = Mutex<CheckedContinuation<Bool?, Never>?>(nil)

    func install(_ continuation: CheckedContinuation<Bool?, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(_ value: Bool?) {
        let continuation = self.continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(returning: value)
    }
}

/// Taps the microphone and converts its buffers to the recognizer's format. The engine is driven
/// from the main actor; the tap block, built in a nonisolated function, runs on the audio thread.
@available(macOS 26.0, *)
@MainActor
private final class DictationAudioCapture {
    private let engine = AVAudioEngine()
    private var running = false

    var naturalFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func start(
        convertingTo format: AVAudioFormat,
        deliver: @escaping @Sendable (AnalyzerInput) -> Void
    ) throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            DictationDiagnostics.log.error("No microphone input (\(inputFormat.sampleRate, privacy: .public) Hz)")
            throw DictationFailure.startFailed
        }
        guard let converter = DictationBufferConverter(from: inputFormat, to: format) else {
            DictationDiagnostics.log.error("Can't convert microphone audio to \(format.description, privacy: .public)")
            throw DictationFailure.startFailed
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat,
            block: Self.tap(converter: converter, deliver: deliver)
        )
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            DictationDiagnostics.log.error(
                "The audio engine didn't start: \(String(describing: error), privacy: .public)")
            throw DictationFailure.startFailed
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    nonisolated private static func tap(
        converter: DictationBufferConverter,
        deliver: @escaping @Sendable (AnalyzerInput) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let converted = converter.convert(buffer) else { return }
            deliver(AnalyzerInput(buffer: converted))
        }
    }
}

/// Owned by one tap block, so only the audio tap's serial thread uses it.
nonisolated private final class DictationBufferConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        // Priming adds leading silence and drifts the timestamps the recognizer relies on.
        converter.primeMethod = .none
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard buffer.frameLength > 0,
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
