import Foundation
import Testing

@testable import whitenoise_mac

/// A recognizer the test drives by hand: it starts when told to, reports what the test says was
/// heard, and finishes with the result the test hands it.
@MainActor
private final class ScriptedDictationEngine {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var requestedLocales: [[String]] = []
    /// How many times a session's `finish` has returned.
    private(set) var finishReturnCount = 0
    /// Every run's update callback, oldest first, so a test can replay an old run's late update.
    private var updateCallbacks: [@MainActor (DictationTranscript) -> Void] = []
    private var endedCallbacks: [@MainActor () -> Void] = []
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<DictationResult, Never>?

    /// Starts immediately unless `holdsStart` is set, in which case `completeStart` releases it.
    var holdsStart = false
    var startError: Error?
    /// Finishes immediately with this unless nil, in which case `completeFinish` releases it.
    var finishResult: DictationResult?

    var engine: DictationEngine {
        DictationEngine { [self] locales, onUpdate, onEnded in
            startCount += 1
            requestedLocales.append(locales)
            updateCallbacks.append(onUpdate)
            endedCallbacks.append(onEnded)
            if holdsStart {
                try await withCheckedThrowingContinuation { startContinuation = $0 }
            }
            if let startError { throw startError }
            return DictationSession(
                finish: { [self] in
                    defer { finishReturnCount += 1 }
                    if let finishResult { return finishResult }
                    return await withCheckedContinuation { finishContinuation = $0 }
                },
                cancel: { [self] in cancelCount += 1 }
            )
        }
    }

    /// Reports `transcript` from the latest run, or from `run` (0-based) when given.
    func report(_ transcript: DictationTranscript, run: Int? = nil) {
        guard let callback = run.map({ updateCallbacks[$0] }) ?? updateCallbacks.last else { return }
        callback(transcript)
    }

    /// The latest run's recognizer fails by itself.
    func failRecognition() {
        endedCallbacks.last?()
    }

    func completeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    /// Whether a session's `finish` is waiting for `completeFinish`.
    var isFinishPending: Bool { finishContinuation != nil }

    func completeFinish(_ result: DictationResult) {
        finishContinuation?.resume(returning: result)
        finishContinuation = nil
    }
}

/// Yields until `condition` holds, recording a failure at the caller when it still doesn't after
/// five seconds.
@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for the condition", sourceLocation: sourceLocation)
            return
        }
        await Task.yield()
    }
}

@MainActor
struct DictationControllerTests {
    @Test func stopHandsBackWhatWasHeard() async {
        let script = ScriptedDictationEngine()
        script.finishResult = DictationResult(text: "see you at six", isComplete: true)
        let controller = ComposerDictationController(engine: script.engine)
        var delivered: [DictationResult] = []

        controller.begin(localeIdentifiers: ["en-US"]) { delivered.append($0) }
        #expect(controller.state == .starting)
        await waitUntil { controller.state == .listening }
        #expect(script.requestedLocales == [["en-US"]])

        script.report(DictationTranscript(finalized: "see you ", volatile: "at six"))
        #expect(controller.transcript.text == "see you at six")

        controller.stop()
        await waitUntil { controller.state == .idle }
        #expect(delivered == [DictationResult(text: "see you at six", isComplete: true)])
        #expect(controller.transcript.isEmpty)
        #expect(controller.notice == nil)
    }

    @Test func cancelDeliversNothingAndStopsTheRecognizer() async {
        let script = ScriptedDictationEngine()
        script.finishResult = DictationResult(text: "never", isComplete: true)
        let controller = ComposerDictationController(engine: script.engine)
        var delivered: [DictationResult] = []

        controller.begin(localeIdentifiers: ["en"]) { delivered.append($0) }
        await waitUntil { controller.state == .listening }
        controller.cancel()

        #expect(controller.state == .idle)
        #expect(script.cancelCount == 1)
        #expect(delivered.isEmpty)
    }

    @Test func cancelWhileTheLastWordsSettleDeliversNothing() async {
        let script = ScriptedDictationEngine()
        let controller = ComposerDictationController(engine: script.engine)
        var delivered: [DictationResult] = []

        controller.begin(localeIdentifiers: ["en"]) { delivered.append($0) }
        await waitUntil { controller.state == .listening }
        controller.stop()
        #expect(controller.state == .finishing)
        await waitUntil { script.isFinishPending }

        controller.cancel()
        script.completeFinish(DictationResult(text: "too late", isComplete: true))
        await waitUntil { script.finishReturnCount == 1 }
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.state == .idle)
        #expect(delivered.isEmpty)
    }

    @Test func aStopWhileStartingFinishesOnceListening() async {
        let script = ScriptedDictationEngine()
        script.holdsStart = true
        script.finishResult = DictationResult(text: "quick", isComplete: true)
        let controller = ComposerDictationController(engine: script.engine)
        var delivered: [DictationResult] = []

        controller.begin(localeIdentifiers: ["en"]) { delivered.append($0) }
        await waitUntil { script.startCount == 1 }
        controller.stop()
        #expect(controller.state == .starting)

        script.completeStart()
        await waitUntil { !delivered.isEmpty }
        #expect(delivered == [DictationResult(text: "quick", isComplete: true)])
        #expect(controller.state == .idle)
    }

    @Test func aCancelledStartNeverListens() async {
        let script = ScriptedDictationEngine()
        script.holdsStart = true
        let controller = ComposerDictationController(engine: script.engine)

        controller.begin(localeIdentifiers: ["en"]) { _ in Issue.record("cancelled dictation delivered") }
        await waitUntil { script.startCount == 1 }
        controller.cancel()
        script.completeStart()
        await waitUntil { script.cancelCount == 1 }

        #expect(controller.state == .idle)
        #expect(script.cancelCount == 1)
    }

    @Test func aLateUpdateFromACancelledRunDoesNotReachTheNextOne() async {
        let script = ScriptedDictationEngine()
        script.finishResult = DictationResult(text: "", isComplete: true)
        let controller = ComposerDictationController(engine: script.engine)

        controller.begin(localeIdentifiers: ["en"]) { _ in }
        await waitUntil { controller.state == .listening }
        controller.cancel()

        controller.begin(localeIdentifiers: ["en"]) { _ in }
        await waitUntil { controller.state == .listening }
        script.report(DictationTranscript(finalized: "fresh"))
        script.report(DictationTranscript(finalized: "stale words"), run: 0)
        #expect(controller.transcript.text == "fresh")
    }

    @Test func aFailedStartExplainsWhy() async {
        let script = ScriptedDictationEngine()
        script.startError = DictationFailure.permissionDenied
        let controller = ComposerDictationController(engine: script.engine)

        controller.begin(localeIdentifiers: ["en"]) { _ in Issue.record("failed start delivered") }
        await waitUntil { controller.state == .idle && controller.notice != nil }

        #expect(controller.notice == .microphoneDenied)
        #expect(controller.notice?.opensMicrophoneSettings == true)
        controller.dismissNotice()
        #expect(controller.notice == nil)
    }

    @Test func aStartThatFailsForAnotherReasonSaysSo() async {
        let script = ScriptedDictationEngine()
        script.startError = DictationFailure.unsupportedLanguage
        let controller = ComposerDictationController(engine: script.engine)

        controller.begin(localeIdentifiers: ["en"]) { _ in Issue.record("failed start delivered") }
        await waitUntil { controller.state == .idle && controller.notice != nil }

        #expect(controller.notice == .failed(DictationFailure.unsupportedLanguage.errorDescription ?? ""))
        #expect(controller.notice?.opensMicrophoneSettings == false)
    }

    @Test func aDownloadingNoticeGoesAwayOnceTheModelIsReady() async {
        let script = ScriptedDictationEngine()
        script.startError = DictationFailure.modelDownloading
        let controller = ComposerDictationController(engine: script.engine)

        controller.begin(localeIdentifiers: ["en"]) { _ in Issue.record("failed start delivered") }
        await waitUntil { controller.state == .idle && controller.notice != nil }
        #expect(controller.notice == .modelDownloading)

        controller.modelStatusChanged(.downloading)
        #expect(controller.notice == .modelDownloading)
        controller.modelStatusChanged(.ready)
        #expect(controller.notice == nil)
    }

    @Test func aReadyModelLeavesOtherNoticesAlone() async {
        let script = ScriptedDictationEngine()
        script.startError = DictationFailure.permissionDenied
        let controller = ComposerDictationController(engine: script.engine)

        controller.begin(localeIdentifiers: ["en"]) { _ in }
        await waitUntil { controller.state == .idle && controller.notice != nil }
        controller.modelStatusChanged(.ready)

        #expect(controller.notice == .microphoneDenied)
    }

    @Test func aCancelledStartShowsNoNotice() async {
        let script = ScriptedDictationEngine()
        script.startError = CancellationError()
        let controller = ComposerDictationController(engine: script.engine)

        controller.begin(localeIdentifiers: ["en"]) { _ in }
        await waitUntil { controller.state == .idle }

        #expect(controller.notice == nil)
    }

    @Test func anIncompleteResultIsDeliveredWithAWarning() async {
        let script = ScriptedDictationEngine()
        script.finishResult = DictationResult(text: "half a sent", isComplete: false)
        let controller = ComposerDictationController(engine: script.engine)
        var delivered: [DictationResult] = []

        controller.begin(localeIdentifiers: ["en"]) { delivered.append($0) }
        await waitUntil { controller.state == .listening }
        controller.stop()
        await waitUntil { !delivered.isEmpty }

        #expect(delivered.first?.text == "half a sent")
        #expect(controller.notice == .stoppedEarly)
    }

    @Test func anEmptyIncompleteResultWarnsAboutNothing() async {
        let script = ScriptedDictationEngine()
        script.finishResult = DictationResult(text: "  ", isComplete: false)
        let controller = ComposerDictationController(engine: script.engine)
        var delivered = 0

        controller.begin(localeIdentifiers: ["en"]) { _ in delivered += 1 }
        await waitUntil { controller.state == .listening }
        controller.stop()
        await waitUntil { delivered == 1 }

        #expect(controller.notice == nil)
    }

    @Test func aRecognitionFailureHandsBackWhatWasHeardAsIncomplete() async {
        let script = ScriptedDictationEngine()
        script.finishResult = DictationResult(text: "see you at", isComplete: false)
        let controller = ComposerDictationController(engine: script.engine)
        var delivered: [DictationResult] = []

        controller.begin(localeIdentifiers: ["en"]) { delivered.append($0) }
        await waitUntil { controller.state == .listening }
        script.report(DictationTranscript(finalized: "see you at"))
        script.failRecognition()
        await waitUntil { !delivered.isEmpty }

        #expect(delivered == [DictationResult(text: "see you at", isComplete: false)])
        #expect(controller.state == .idle)
        #expect(controller.notice == .stoppedEarly)
    }

    @Test func aRecognitionFailureWhileStartingFinishesOnceListening() async {
        let script = ScriptedDictationEngine()
        script.holdsStart = true
        script.finishResult = DictationResult(text: "", isComplete: false)
        let controller = ComposerDictationController(engine: script.engine)
        var delivered: [DictationResult] = []

        controller.begin(localeIdentifiers: ["en"]) { delivered.append($0) }
        await waitUntil { script.startCount == 1 }
        script.failRecognition()
        #expect(controller.state == .starting)

        script.completeStart()
        await waitUntil { !delivered.isEmpty }
        #expect(delivered == [DictationResult(text: "", isComplete: false)])
        #expect(controller.state == .idle)
    }

    @Test func aRecognitionFailureFromACancelledRunIsIgnored() async {
        let script = ScriptedDictationEngine()
        let controller = ComposerDictationController(engine: script.engine)

        controller.begin(localeIdentifiers: ["en"]) { _ in Issue.record("cancelled run delivered") }
        await waitUntil { controller.state == .listening }
        controller.cancel()
        script.failRecognition()

        #expect(controller.state == .idle)
    }

    @Test func theDurationLimitFinishesByItself() async {
        let script = ScriptedDictationEngine()
        script.finishResult = DictationResult(text: "long story", isComplete: true)
        let controller = ComposerDictationController(engine: script.engine, maximumDuration: .milliseconds(10))
        var delivered: [DictationResult] = []

        controller.begin(localeIdentifiers: ["en"]) { delivered.append($0) }
        let deadline = ContinuousClock.now + .seconds(5)
        while delivered.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(delivered == [DictationResult(text: "long story", isComplete: true)])
    }

    @Test func aSecondBeginWhileActiveIsIgnored() async {
        let script = ScriptedDictationEngine()
        let controller = ComposerDictationController(engine: script.engine)

        controller.begin(localeIdentifiers: ["en"]) { _ in }
        controller.begin(localeIdentifiers: ["fr"]) { _ in }
        await waitUntil { controller.state == .listening }

        #expect(script.requestedLocales == [["en"]])
        controller.cancel()
    }

    @Test func closingTheConversationCancelsDictation() async {
        let script = ScriptedDictationEngine()
        let model = ConversationViewModel(
            account: AccountItem.samples[0],
            groupIdHex: "group",
            runtime: FakeMarmotRuntime(accounts: []),
            dictationEngine: script.engine
        )

        model.dictation.begin(localeIdentifiers: ["en"]) { _ in Issue.record("closed chat delivered") }
        await waitUntil { model.dictation.state == .listening }
        model.stop()

        #expect(model.dictation.state == .idle)
        #expect(script.cancelCount == 1)
    }
}
