import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// The `-uiFixture heavy-chat` launch is what every UI test starts from, so it has to reach the
/// heavy chat's transcript through the same steps the app shell takes: bootstrap, activate the
/// account's scope, open the selected chat's conversation window.
@MainActor
struct UIFixtureWorkspaceTests: WorkspaceTestSupport {
    /// Runs `body` on the fixture workspace with the heavy chat's conversation window open, as the
    /// shell opens it, then closes the account scope, so its subscriptions end with the test even
    /// when `body` throws.
    static func withHeavyChat(
        _ body: (WorkspaceState, AccountItem, ConversationViewModel) async throws -> Void
    ) async throws {
        let state = WorkspaceState.uiFixture(named: "heavy-chat")
        await state.bootstrap()
        let account = try #require(state.activeAccount)
        let chat = try #require(state.selectedChat)

        let session = SessionState()
        await session.activate(account: account, runtime: state.client, connectivityAvailable: true)
        do {
            let scope = try #require(session.accountScope)
            let model = scope.selectConversation(groupIdHex: chat.id)
            await waitUntil { model.snapshot != nil }
            try await body(state, account, model)
        } catch {
            await session.deactivate()
            throw error
        }
        await session.deactivate()
    }

    @Test func heavyChatFixtureOpensItsConversation() async throws {
        try await Self.withHeavyChat { state, _, model in
            #expect(state.phase == .ready)
            #expect(state.selectedChat?.id == "ui-fixture-heavy-chat")
            #expect(state.activeChats.count > 200)
            let messages = try #require(model.snapshot?.messages)
            #expect(messages.count == WorkspaceState.timelineWindowLimit)
            #expect(messages.contains { !$0.timeline.media.isEmpty })
            #expect(messages.contains { $0.references.reactions.totalCount > 0 })
        }
    }

    /// The search performance test types chat names; the fixture has to find them, or it measures
    /// five empty result lists.
    @Test func heavyChatFixtureSearchFindsChatsByName() async throws {
        try await Self.withHeavyChat { state, account, _ in
            let client = try #require(state.client)
            let query = try #require(ChatListSearchQuery.matches(text: "Launch", view: .chats))

            let ids = try await client.chatListQueryIds(accountRef: account.accountRef, query: query)

            let titles = state.activeChats.filter { ids.contains($0.id) }.map(\.title)
            #expect(titles.count == ids.count)
            #expect(titles.count == 44)
            #expect(titles.allSatisfy { $0.hasPrefix("Launch Review") })
        }
    }

    /// A fixture launch is the same app as a normal one, so it shares its preferences. Its bootstrap
    /// must not replace the account the next normal launch reopens.
    @Test func heavyChatFixtureLeavesTheSavedAccountAlone() async throws {
        let key = WorkspaceState.activeAccountKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("a-real-account", forKey: key)

        try await Self.withHeavyChat { state, _, _ in
            #expect(state.activeAccount != nil)
            #expect(UserDefaults.standard.string(forKey: key) == "a-real-account")
        }
    }
}
