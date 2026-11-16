import Foundation
import Testing

@testable import whitenoise_mac

struct DictationValueTests {
    @Test func aFinalResultSettlesTheGuess() {
        var transcript = DictationTranscript()
        transcript.apply("hel", isFinal: false)
        #expect(transcript.text == "hel")
        transcript.apply("hello ", isFinal: true)
        #expect(transcript.text == "hello ")
        transcript.apply("wor", isFinal: false)
        #expect(transcript.finalized == "hello ")
        #expect(transcript.volatile == "wor")
        #expect(!transcript.isEmpty)
        #expect(DictationTranscript(finalized: " ", volatile: "\n").isEmpty)
    }

    @Test func dictatedWordsJoinTheDraft() {
        #expect(DictationTextMerge.merged(draft: "", transcript: " hello ") == "hello")
        #expect(DictationTextMerge.merged(draft: "Hi", transcript: "there") == "Hi there")
        #expect(DictationTextMerge.merged(draft: "Hi ", transcript: "there") == "Hi there")
        #expect(DictationTextMerge.merged(draft: "Hi", transcript: "   ") == "Hi")
        #expect(DictationTextMerge.merged(draft: "你好", transcript: "世界") == "你好世界")
        #expect(DictationTextMerge.merged(draft: "你好", transcript: "world") == "你好 world")
    }

    @Test func preferredLanguagesComeBeforeKeyboardsAndRepeatsAreDropped() {
        let candidates = DictationLocalePolicy.candidateIdentifiers(
            preferredLanguages: ["es-CL", "en-US"],
            keyboardLanguages: ["en_US", "emoji", "de", "es-cl", ""]
        )
        #expect(candidates == ["es-CL", "en-US", "de"])
    }

    @Test func onlyAModelStillMissingAfterADownloadFailed() {
        #expect(DictationModelStatus.afterInstallAttempt(.notInstalled) == .failed)
        #expect(DictationModelStatus.afterInstallAttempt(.downloading) == .downloading)
        #expect(DictationModelStatus.afterInstallAttempt(.ready) == .ready)
        #expect(DictationModelStatus.failed.offersDownload)
        #expect(DictationModelStatus.notInstalled.offersDownload)
        #expect(!DictationModelStatus.ready.offersDownload)
    }

    @MainActor
    @Test func thePreferenceIsOnUntilTurnedOff() throws {
        let suite = "dictation-preference-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preference = DictationPreference(defaults: defaults)
        #expect(preference.isEnabled)
        preference.setEnabled(false)
        #expect(!DictationPreference(defaults: defaults).isEnabled)
        preference.reset()
        #expect(preference.isEnabled)
        #expect(DictationPreference(defaults: defaults).isEnabled)
    }

    @Test func everyNoticeHasCopy() {
        let notices: [DictationNotice] = [.failed("Nope."), .microphoneDenied, .modelDownloading, .stoppedEarly]
        for notice in notices {
            #expect(!notice.message.isEmpty)
        }
        #expect(DictationNotice.microphoneSettingsURL?.scheme == "x-apple.systempreferences")
        #expect(
            DictationNotice(startError: DictationFailure.startFailed)
                == .failed(
                    DictationFailure.startFailed.errorDescription ?? ""))
        #expect(DictationNotice(startError: URLError(.unknown)) != nil)
    }

    @Test func everyFailureHasCopy() {
        let failures: [DictationFailure] = [.permissionDenied, .unsupportedLanguage, .modelDownloading, .startFailed]
        for failure in failures {
            #expect(failure.errorDescription?.isEmpty == false)
        }
    }
}
