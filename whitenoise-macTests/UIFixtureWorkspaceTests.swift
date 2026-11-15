import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// The `-uiFixture heavy-chat` launch is what every UI test starts from, so it has to reach the
/// heavy chat's transcript through the same steps the app shell takes: bootstrap, activate the
/// account's scope, open the selected chat's conversation window.
@MainActor
struct UIFixtureWorkspaceTests: WorkspaceTestSupport {
    /// The fixture workspace with the heavy chat's conversation window open, as the shell opens it.
    static func openHeavyChat() async throws -> (WorkspaceState, AccountItem, ConversationViewModel) {
        let state = WorkspaceState.uiFixture(named: "heavy-chat")
        await state.bootstrap()
        let account = try #require(state.activeAccount)
        let chat = try #require(state.selectedChat)

        let session = SessionState()
        await session.activate(account: account, runtime: state.client, connectivityAvailable: true)
        let scope = try #require(session.accountScope)
        let model = scope.selectConversation(groupIdHex: chat.id)
        await waitUntil { model.snapshot != nil }
        return (state, account, model)
    }

    @Test func heavyChatFixtureOpensItsConversation() async throws {
        let (state, _, model) = try await Self.openHeavyChat()

        #expect(state.phase == .ready)
        #expect(state.selectedChat?.id == "ui-fixture-heavy-chat")
        #expect(state.activeChats.count > 200)
        let messages = try #require(model.snapshot?.messages)
        #expect(messages.count == WorkspaceState.timelineWindowLimit)
        #expect(messages.contains { !$0.timeline.media.isEmpty })
        #expect(messages.contains { $0.references.reactions.totalCount > 0 })
    }

    /// The search performance test types chat names; the fixture has to find them, or it measures
    /// five empty result lists.
    @Test func heavyChatFixtureSearchFindsChatsByName() async throws {
        let (state, account, _) = try await Self.openHeavyChat()
        let client = try #require(state.client)
        let query = try #require(ChatListSearchQuery.matches(text: "Launch", view: .chats))

        let ids = try await client.chatListQueryIds(accountRef: account.accountRef, query: query)

        let titles = state.activeChats.filter { ids.contains($0.id) }.map(\.title)
        #expect(titles.count == ids.count)
        #expect(titles.count == 44)
        #expect(titles.allSatisfy { $0.hasPrefix("Launch Review") })
    }

    /// A fixture launch is the same app as a normal one, so it shares its preferences. Its bootstrap
    /// must not replace the account the next normal launch reopens.
    @Test func heavyChatFixtureLeavesTheSavedAccountAlone() async throws {
        let key = WorkspaceState.activeAccountKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("a-real-account", forKey: key)

        let (state, _, _) = try await Self.openHeavyChat()

        #expect(state.activeAccount != nil)
        #expect(UserDefaults.standard.string(forKey: key) == "a-real-account")
    }
}
