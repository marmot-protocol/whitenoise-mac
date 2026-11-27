import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// Agent rows, the activity bar and a thread's bar hosted in a real window: each kind of item
/// draws its title and the body its type calls for, and a waiting approval offers its choices.
@Suite(.serialized) @MainActor struct AgentItemRowRenderTests {
    private typealias F = AgentPreviewFixtures
    private static let size = CGSize(width: 640, height: 520)

    private static func host(_ view: some View) -> HostedViewWindow {
        HostedViewWindow(
            view.frame(width: size.width, height: size.height, alignment: .top), size: size)
    }

    /// The fixture's row for `n` (`AgentPreviewFixtures.eventId`), as the transcript decorates it.
    private static func row(_ n: Int) throws -> MessageItem {
        try #require(F.transcript.mainItems.first { $0.id == F.eventId(n) }?.message)
    }

    private static func draws(_ message: MessageItem, _ phrases: [String]) async throws {
        let item = try #require(message.agent?.item)
        let window = host(AgentItemRow(message: message, item: item, timeLabel: "14:02", actions: .inert))
        defer { window.close() }
        let drawing = try #require(
            await window.settleDrawing { rep in phrases.allSatisfy { DrawnText.contains($0, in: rep) } },
            "\(item.type) row did not draw \(phrases)")
        for phrase in phrases { #expect(DrawnText.contains(phrase, in: drawing)) }
    }

    @Test func aWaitingApprovalDrawsItsCommandAndEveryChoice() async throws {
        try await Self.draws(
            Self.row(5), ["Allow this command?", "rm -rf build", "Allow once", "Deny and stop"])
    }

    @Test func aFinishedCommandDrawsItsTitleAndCommand() async throws {
        try await Self.draws(Self.row(4), ["Ran a command", "python3 greet.py"])
    }

    @Test func aPlanDrawsItsSteps() async throws {
        try await Self.draws(Self.row(7), ["Read greet.py", "Fix the greeting", "Run the tests"])
    }

    @Test func aQuestionDrawsItsQuestionAndOptions() async throws {
        try await Self.draws(Self.row(9), ["Which greeting should greet.py use?", "Hello"])
    }

    @Test func aSubagentTaskOffersItsThread() async throws {
        try await Self.draws(Self.row(10), ["Check other callers", "Open Thread"])
    }

    @Test func aRefusedNoticeAndAnErrorSayWhatHappened() async throws {
        try await Self.draws(Self.row(12), ["Only the owner may approve in this chat."])
        try await Self.draws(Self.row(13), ["The model gpt-9 does not exist."])
    }

    @Test func theSessionDrawsItsSettings() async throws {
        try await Self.draws(Self.row(1), ["Model", "gpt-6.1-sol"])
    }

    @Test func theActivityBarOffersStopForTheRunningTurn() async throws {
        let transcript = F.transcript
        let window = Self.host(
            AgentActivityBar(
                runningTurn: transcript.runningTurn, session: transcript.session,
                waitingCount: transcript.waiting.count, failure: nil, actions: .inert, onDismissFailure: {}
            ))
        defer { window.close() }
        #expect(await window.settleDrawing { DrawnText.contains(L10n.string("Stop"), in: $0) } != nil)
    }

    @Test func aThreadBarNamesItsSubagentAndOffersBack() async throws {
        let window = Self.host(
            AgentThreadBar(task: try Self.row(10), isEmpty: true, actions: .inert, onBack: {}))
        defer { window.close() }
        let drawing = try #require(
            await window.settleDrawing { DrawnText.contains("Check other callers", in: $0) })
        #expect(DrawnText.contains(L10n.string("Back"), in: drawing))
        #expect(DrawnText.contains(L10n.string("Nothing in this thread yet."), in: drawing))
    }
}
