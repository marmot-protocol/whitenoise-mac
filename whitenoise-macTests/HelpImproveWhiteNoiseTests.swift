import AppKit
import MarmotKit
import SwiftUI
import Testing
import Vision

@testable import whitenoise_mac

/// The first-run "Help Improve White Noise" sheet and the model it closes through.
///
/// MarmotKit's usage receipt is device-wide, so closing the sheet is itself an answer: a pending
/// receipt is written as declined, and a failed write keeps the sheet up because nothing was
/// recorded. The fake's receipt starts at `.acceptanceRequired` under a non-empty policy revision.
///
/// `.serialized` and `@MainActor` because hosting draws through AppKit, which off the main thread
/// takes the test host down.
@Suite(.serialized) @MainActor struct HelpImproveWhiteNoiseTests {
    // MARK: - Why the Mac is being asked

    @Test func aNeverAnsweredMacGetsNoExplanation() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.usageSettings.policyRevision = ""
        let model = DiagnosticsSettingsViewModel(runtime: runtime)

        await model.load()

        #expect(model.isPromptPending)
        #expect(model.promptExplanation == nil)
    }

    @Test func aMacThatSharedReliabilityMetricsIsToldWhyItIsAskedAgain() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.usageSettings.policyRevision = ""
        runtime.usageSettings.previouslyEnabled = true
        let model = DiagnosticsSettingsViewModel(runtime: runtime)

        await model.load()

        #expect(
            model.promptExplanation
                == L10n.string(
                    "You previously shared reliability metrics. Sharing now also includes feature usage, so we need your permission again."
                ))
    }

    @Test func aChangedPolicyIsExplained() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = DiagnosticsSettingsViewModel(runtime: runtime)

        await model.load()

        #expect(
            model.promptExplanation
                == L10n.string(
                    "The scope of usage and diagnostics has changed. Review the updated information before sharing again."
                ))
    }

    @Test(arguments: [UsageDiagnosticsDecisionFfi.declined, .granted])
    func anAnsweredReceiptIsNotPendingAndNeedsNoExplanation(_ decision: UsageDiagnosticsDecisionFfi) async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.usageSettings.decision = decision
        let model = DiagnosticsSettingsViewModel(runtime: runtime)

        await model.load()

        #expect(!model.isPromptPending)
        #expect(model.promptExplanation == nil)
        #expect(await model.finishPrompt())
        #expect(runtime.usageSettings.decision == decision)
    }

    // MARK: - Closing

    /// An unreadable receipt is not pending: the sheet closes without writing anything, and
    /// Privacy & Security remains the place to choose.
    @Test func anUnreadableReceiptClosesWithoutWriting() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.usageDiagnosticsSettingsError = MarmotKitError.Io(details: "busy")
        let model = DiagnosticsSettingsViewModel(runtime: runtime)

        await model.load()

        #expect(model.settings == nil)
        #expect(model.canFinishPrompt)
        #expect(await model.finishPrompt())
        #expect(runtime.usageSettings.decision == .acceptanceRequired)
    }

    /// The decline was not recorded, so closing would leave the receipt pending and the next
    /// account would be asked the same question again.
    @Test func aFailedDeclineKeepsThePromptOpen() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.setUsageDiagnosticsConsentError = MarmotKitError.Io(details: "disk")
        let model = DiagnosticsSettingsViewModel(runtime: runtime)

        await model.load()

        #expect(await model.finishPrompt() == false)
        #expect(model.error != nil)
        #expect(model.isPromptPending)
        #expect(runtime.usageSettings.decision == .acceptanceRequired)
    }

    // MARK: - The sheet

    @Test func theSheetSaysWhatEachSwitchSharesAndWhereToChangeIt() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = DiagnosticsSettingsViewModel(runtime: runtime)
        let host = HostedViewWindow(HelpImproveWhiteNoiseSheet(model: model, onClose: {}), size: Self.size)
        defer { host.close() }

        #expect(await host.settle { model.settings != nil && !model.isLoading })
        let drawn = try #require(await host.steadyDrawing())

        for phrase in [
            "Help Improve White Noise",
            "Share usage and telemetry",
            "Share group diagnostic logs",
            "These choices apply to all accounts on this device",
            "The scope of usage and diagnostics has changed",
        ] {
            #expect(DrawnText.contains(phrase, in: drawn), "missing: \(phrase)")
        }
    }

    @Test func whatsSharedOpensTheDisclosureAndBackReturnsToTheSwitches() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = DiagnosticsSettingsViewModel(runtime: runtime)
        let host = HostedViewWindow(HelpImproveWhiteNoiseSheet(model: model, onClose: {}), size: Self.size)
        defer { host.close() }

        #expect(await host.settle { model.settings != nil && !model.isLoading })
        let choices = try #require(await host.steadyDrawing())
        let link = try #require(Self.center(ofLineContaining: "shared", below: 80, in: choices))

        host.click(at: link)
        let disclosure = try #require(
            await host.settleDrawing { DrawnText.contains("Data retention", in: $0) })
        #expect(DrawnText.contains("Usage and telemetry", in: disclosure))
        #expect(DrawnText.contains("Group diagnostic logs", in: disclosure))
        #expect(!DrawnText.contains("Share usage and telemetry", in: disclosure))

        host.click(at: Self.headerBack)
        #expect(
            await host.settleDrawing { DrawnText.contains("Share usage and telemetry", in: $0) } != nil)
        // Navigating the disclosure is not an answer.
        #expect(runtime.usageSettings.decision == .acceptanceRequired)
    }

    @Test func doneRecordsADeclineAndCloses() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = DiagnosticsSettingsViewModel(runtime: runtime)
        var closeCount = 0
        let host = HostedViewWindow(
            HelpImproveWhiteNoiseSheet(model: model, onClose: { closeCount += 1 }), size: Self.size)
        defer { host.close() }

        #expect(await host.settle { model.settings != nil && !model.isLoading })
        let drawn = try #require(await host.steadyDrawing())
        let done = try #require(Self.center(ofLineContaining: "done", below: Self.size.height - 80, in: drawn))

        host.click(at: done)

        #expect(await host.settle { closeCount == 1 })
        #expect(runtime.usageSettings.decision == .declined)
    }

    @Test func closingAfterAFailedDeclineLeavesTheSheetUp() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.setUsageDiagnosticsConsentError = MarmotKitError.Io(details: "disk")
        let model = DiagnosticsSettingsViewModel(runtime: runtime)
        var closeCount = 0
        let host = HostedViewWindow(
            HelpImproveWhiteNoiseSheet(model: model, onClose: { closeCount += 1 }), size: Self.size)
        defer { host.close() }

        #expect(await host.settle { model.settings != nil && !model.isLoading })
        host.click(at: Self.headerClose)

        #expect(await host.settle { model.error != nil && !model.isSavingUsage })
        // Give a wrongly-scheduled close the chance to land before asserting it did not.
        _ = await host.settle(timeout: .milliseconds(200)) { false }
        #expect(closeCount == 0)
        #expect(runtime.usageSettings.decision == .acceptanceRequired)
    }

    // MARK: - Fixtures

    /// The sheet's own fixed frame.
    private static let size = CGSize(width: 480, height: 460)
    /// The header's leading and trailing 28pt circles, inside 16pt of horizontal and 12pt of
    /// vertical padding.
    private static let headerBack = CGPoint(x: 16 + 14, y: 12 + 14)
    private static let headerClose = CGPoint(x: size.width - 16 - 14, y: 12 + 14)

    /// The centre, in window points, of the first recognized line at or below `top` that contains
    /// `word`. Located from the drawing so the test follows the copy rather than a pixel offset.
    private static func center(ofLineContaining word: String, below top: CGFloat, in rep: NSBitmapImageRep)
        -> CGPoint?
    {
        guard let image = rep.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let points = (request.results ?? []).compactMap { observation -> CGPoint? in
            guard let text = observation.topCandidates(1).first?.string,
                text.lowercased().contains(word)
            else { return nil }
            let box = observation.boundingBox
            let point = CGPoint(x: box.midX * size.width, y: (1 - box.midY) * size.height)
            return point.y >= top ? point : nil
        }
        return points.min { $0.y < $1.y }
    }
}
