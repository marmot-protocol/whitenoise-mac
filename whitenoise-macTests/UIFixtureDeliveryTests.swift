import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// The heavy-chat UI fixture is how the delivery footer's rare states get looked at by hand — a
/// convergence-retired message only happens naturally through a two-device race. These pin that
/// the fixture shows each of them, and nothing else that would bury them.
@MainActor
struct UIFixtureDeliveryTests {
    @Test func heavyChatFixtureShowsEachDeliveryStateOnce() async throws {
        try await UIFixtureWorkspaceTests.withHeavyChat { state, account, model in
            let client = try #require(state.client)
            let snapshot = try #require(model.snapshot)
            // The rows the transcript shows, mapped from the window as the shell maps them.
            await state.applyTimelineWindow(
                TimelinePageFfi(
                    messages: snapshot.messages.map(\.timeline),
                    hasMoreBefore: snapshot.hasMoreBefore,
                    hasMoreAfter: snapshot.hasMoreAfter
                ),
                groupIdHex: model.groupIdHex,
                account: account,
                client: client,
                owner: nil,
                marksLatestRowRead: false
            )
            let messages = state.messagesByChat["ui-fixture-heavy-chat"] ?? []
            let now = Date.now

            func indicator(_ index: Int) throws -> MessageDeliveryIndicator {
                let message = try #require(messages.first { $0.id == "ui-fixture-message-\(index)" })
                return message.deliveryIndicator(at: now)
            }

            #expect(try indicator(897) == .warning)
            #expect(try indicator(898) == .warning)
            #expect(try indicator(894) == .failed)

            // Every other own row is relay-confirmed, so the seeded rows are the only markers in view.
            let markers = messages.map { $0.deliveryIndicator(at: now) }
            #expect(markers.filter { $0 == .warning }.count == 2)
            #expect(markers.filter { $0 == .failed }.count == 1)
        }
    }
}
