//
//  DirectChatChooserTests.swift
//  whitenoise-macTests
//
//  The New chat chooser that offers an existing direct chat or another one.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

@MainActor
struct DirectChatChooserTests {
    private static let peer = String(repeating: "b", count: 64)
    private static let other = String(repeating: "c", count: 64)

    private static func chat(
        _ id: String,
        peer: String? = DirectChatChooserTests.peer,
        isDirect: Bool = true,
        updatedAt: Date? = .now,
        selfMembership: ChatSelfMembership = .member
    ) -> ChatItem {
        ChatItem(
            id: id,
            title: "Bob",
            subtitle: "",
            preview: "",
            updatedAt: updatedAt,
            avatarSeed: id,
            directPeerAccountIdHex: peer,
            pictureURL: nil,
            unreadCount: 0,
            isDirect: isDirect,
            selfMembership: selfMembership
        )
    }

    private static func recipient() -> NewChatRecipient {
        NewChatRecipient(
            sourceQuery: "",
            memberRef: "npub1bob",
            accountIdHex: peer,
            npub: "npub1bob",
            displayName: "Bob",
            pictureURL: nil
        )
    }

    /// Records what the chooser asked the workspace to do.
    private final class Recorder {
        var opened: [String] = []
        var started: [String] = []
        /// The account each Start New was bound to, in call order.
        var startedUnder: [String?] = []
        /// What the source reports as the active account; a test changes it to simulate a switch.
        var activeAccountId: String? = "account-a"
        /// Every call in order, so a test can assert that unarchiving happened before opening.
        var events: [String] = []
    }

    private static func source(
        active: [ChatItem],
        archived: [ChatItem] = [],
        recorder: Recorder
    ) -> DirectChatChooserSource {
        DirectChatChooserSource(
            activeAccountId: { recorder.activeAccountId },
            conversations: { (active, archived) },
            open: { choice in
                if choice.isArchived { recorder.events.append("unarchived \(choice.id)") }
                recorder.opened.append(choice.id)
                recorder.events.append("opened \(choice.id)")
            },
            startNew: { recipient, accountId in
                recorder.started.append(recipient.accountIdHex)
                recorder.startedUnder.append(accountId)
            }
        )
    }

    @Test func offersOnlyDirectChatsWithThatPersonTheViewerIsStillIn() {
        let now = Date.now
        let choices = DirectChatChoices.existing(
            withPeer: Self.peer.uppercased(),
            active: [
                Self.chat("older", updatedAt: now.addingTimeInterval(-60)),
                Self.chat("group", peer: nil, isDirect: false),
                Self.chat("someone-else", peer: Self.other),
                Self.chat("left", selfMembership: .left),
                Self.chat("newest", updatedAt: now),
            ],
            archived: [Self.chat("archived", updatedAt: now.addingTimeInterval(-3_600))]
        )

        #expect(choices.map(\.id) == ["newest", "older", "archived"])
        #expect(choices.map(\.isArchived) == [false, false, true])
    }

    @Test func withNoExistingChatThePersonGetsANewOneWithoutAsking() async {
        let recorder = Recorder()
        let model = DirectChatChooserViewModel()

        await model.choose(Self.recipient(), from: Self.source(active: [], recorder: recorder))

        #expect(model.presentation == nil)
        #expect(recorder.started == [Self.peer])
    }

    @Test func anExistingChatIsOfferedAlongsideANewOne() async throws {
        let recorder = Recorder()
        let model = DirectChatChooserViewModel()
        let source = Self.source(active: [Self.chat("dm")], recorder: recorder)

        await model.choose(Self.recipient(), from: source)
        let presentation = try #require(model.presentation)
        #expect(presentation.choices.map(\.id) == ["dm"])
        #expect(recorder.started.isEmpty)

        await model.startNew(from: source)
        #expect(model.presentation == nil)
        #expect(recorder.started == [Self.peer])
        #expect(recorder.opened.isEmpty)
    }

    @Test func pickingAnExistingChatOpensItInsteadOfCreatingOne() async throws {
        let recorder = Recorder()
        let model = DirectChatChooserViewModel()
        let source = Self.source(active: [Self.chat("dm")], recorder: recorder)

        await model.choose(Self.recipient(), from: source)
        let choice = try #require(model.presentation?.choices.first)
        await model.open(choice, from: source)

        #expect(model.presentation == nil)
        #expect(recorder.opened == ["dm"])
        #expect(recorder.events == ["opened dm"])
        #expect(recorder.started.isEmpty)
    }

    @Test func pickingAnArchivedChatUnarchivesItBeforeOpeningIt() async throws {
        let recorder = Recorder()
        let model = DirectChatChooserViewModel()
        let source = Self.source(active: [], archived: [Self.chat("archived")], recorder: recorder)

        await model.choose(Self.recipient(), from: source)
        let choice = try #require(model.presentation?.choices.first)
        #expect(choice.isArchived)
        await model.open(choice, from: source)

        #expect(recorder.events == ["unarchived archived", "opened archived"])
        #expect(recorder.started.isEmpty)
    }

    /// The workspace side of the same choice: the chat really leaves the archive, the way the
    /// group composer's reuse path does, before it is selected.
    @Test func theWorkspaceSourceUnarchivesAnArchivedChatBeforeSelectingIt() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        var archived = directGroup()
        archived.archived = true
        runtime.installGroups([archived])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let chat = try #require(state.archivedChats.first { $0.id == "direct-group" })
        await DirectChatChooserSource.workspace(state).open(DirectChatChoice(chat: chat, isArchived: true))

        #expect(runtime.archivedGroup == ArchivedGroup(groupIdHex: "direct-group", archived: false))
        #expect(state.archivedChats.isEmpty)
        #expect(state.activeChats.contains { $0.id == "direct-group" })
        #expect(state.selection == .chat("direct-group"))
    }

    /// Start New runs in a task the view launches after the sheet is up. An account switch in
    /// between must not move the new chat to the account switched to.
    @Test func startNewIsBoundToTheAccountTheChooserOpenedUnder() async throws {
        let recorder = Recorder()
        let model = DirectChatChooserViewModel()
        let source = Self.source(active: [Self.chat("dm")], recorder: recorder)

        await model.choose(Self.recipient(), from: source)
        #expect(model.presentation?.accountId == "account-a")
        recorder.activeAccountId = "account-b"
        await model.startNew(from: source)

        #expect(recorder.startedUnder == ["account-a"])
    }

    @Test func aFirstDirectChatIsBoundToTheAccountItWasChosenUnder() async {
        let recorder = Recorder()
        let model = DirectChatChooserViewModel()

        await model.choose(Self.recipient(), from: Self.source(active: [], recorder: recorder))

        #expect(recorder.startedUnder == ["account-a"])
    }

    /// The workspace side: a Start New bound to an account that is no longer active creates nothing.
    @Test func theWorkspaceSourceDoesNotStartANewChatUnderAnotherAccount() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        #expect(state.activeAccountId != nil)
        let source = DirectChatChooserSource.workspace(state)
        #expect(source.activeAccountId() == state.activeAccountId)

        await source.startNew(Self.recipient(), "Another Account")

        #expect(runtime.createdGroupMemberRefs.isEmpty)
        #expect(state.selection != .chat("created-group"))

        await source.startNew(Self.recipient(), state.activeAccountId)

        #expect(runtime.createdGroupMemberRefs == ["npub1bob"])
        #expect(state.selection == .chat("created-group"))
    }

    @Test func cancellingDoesNothing() async {
        let recorder = Recorder()
        let model = DirectChatChooserViewModel()
        let source = Self.source(active: [Self.chat("dm")], recorder: recorder)

        await model.choose(Self.recipient(), from: source)
        model.cancel()
        await model.startNew(from: source)

        #expect(model.presentation == nil)
        #expect(recorder.opened.isEmpty)
        #expect(recorder.started.isEmpty)
    }
}
