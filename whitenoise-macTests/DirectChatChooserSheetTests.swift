//
//  DirectChatChooserSheetTests.swift
//  whitenoise-macTests
//
//  The chooser sheet's layout, and the workspace-backed source the New chat panel hands it.
//

import AppKit
import Foundation
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

@MainActor
struct DirectChatChooserSheetTests {
    private static let peer = String(repeating: "b", count: 64)

    private static func chat(_ id: String, preview: String = "", updatedAt: Date = .now) -> ChatItem {
        ChatItem(
            id: id,
            title: "Bob",
            subtitle: "",
            preview: preview,
            updatedAt: updatedAt,
            avatarSeed: peer,
            directPeerAccountIdHex: peer,
            pictureURL: nil,
            unreadCount: 0,
            isDirect: true
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

    private static func sheet(_ choices: [DirectChatChoice]) -> DirectChatChooserSheet {
        DirectChatChooserSheet(
            presentation: DirectChatChooserPresentation(recipient: recipient(), choices: choices),
            onOpen: { _ in },
            onStartNew: {},
            onCancel: {}
        )
    }

    private static func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view.environment(WorkspaceState.preview()))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    // MARK: - Sheet

    /// The sheet is a fixed-width card; each existing chat adds a row under the header.
    @Test func eachExistingChatAddsARowToAFixedWidthSheet() {
        let one = Self.fittingSize(
            Self.sheet([DirectChatChoice(chat: Self.chat("a", preview: "See you tomorrow"), isArchived: false)])
        )
        let two = Self.fittingSize(
            Self.sheet([
                DirectChatChoice(chat: Self.chat("a", preview: "See you tomorrow"), isArchived: false),
                DirectChatChoice(chat: Self.chat("b"), isArchived: true),
            ])
        )

        #expect(one.width == 400)
        #expect(two.width == 400)
        #expect(two.height > one.height)
    }

    /// However many chats the person shares with the viewer, the list scrolls instead of pushing
    /// Start New off the bottom of the sheet.
    @Test func aLongListScrollsInsteadOfGrowingTheSheet() {
        let choices = (0..<30).map { index in
            DirectChatChoice(
                chat: Self.chat(
                    "chat-\(index)",
                    preview: "Message \(index)",
                    updatedAt: .now.addingTimeInterval(TimeInterval(-index * 60))
                ),
                isArchived: index.isMultiple(of: 3)
            )
        }
        let few = Self.fittingSize(Self.sheet(Array(choices.prefix(2))))
        let many = Self.fittingSize(Self.sheet(choices))
        let evenMore = Self.fittingSize(
            Self.sheet(
                choices
                    + choices.map {
                        DirectChatChoice(chat: Self.chat("more-\($0.id)"), isArchived: false)
                    }))

        #expect(many.height > few.height)
        #expect(many.height == evenMore.height)
    }

    /// The chooser's presentation is identified by the person it is about, so re-choosing the
    /// same person replaces the sheet's contents rather than stacking another sheet.
    @Test func thePresentationIsIdentifiedByThePerson() {
        let first = DirectChatChooserPresentation(
            recipient: Self.recipient(),
            choices: [DirectChatChoice(chat: Self.chat("a"), isArchived: false)]
        )
        let second = DirectChatChooserPresentation(
            recipient: Self.recipient(),
            choices: [DirectChatChoice(chat: Self.chat("b"), isArchived: true)],
            accountId: "account-a"
        )

        #expect(first.id == Self.peer)
        #expect(first.id == second.id)
        #expect(first != second)
        #expect(first.accountId == nil)
        #expect(second.choices.first?.id == "b")
    }

    // MARK: - Workspace source

    /// The workspace source reads the active account's chats, active and archived, and nothing
    /// while no account is active.
    @Test func theWorkspaceSourceReadsTheActiveAccountsConversations() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let state = WorkspaceState(clientFactory: { runtime })
        let source = DirectChatChooserSource.workspace(state)
        await state.bootstrap()
        let accountId = try #require(state.activeAccountId)
        state.chatsByAccount[accountId] = [Self.chat("stale-dm")]

        state.activeAccountId = nil
        #expect(source.activeAccountId() == nil)
        let signedOut = source.conversations()
        #expect(signedOut.active.isEmpty)
        #expect(signedOut.archived.isEmpty)

        state.activeAccountId = accountId
        state.chatsByAccount[accountId] = [Self.chat("active-dm")]
        state.archivedChatsByAccount[accountId] = [Self.chat("archived-dm")]

        let after = source.conversations()
        #expect(source.activeAccountId() == accountId)
        #expect(after.active.map(\.id) == ["active-dm"])
        #expect(after.archived.map(\.id) == ["archived-dm"])
    }

    /// A chat that is not archived opens straight away, without touching the archive.
    @Test func theWorkspaceSourceOpensAnActiveChatWithoutUnarchiving() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.installGroups([directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let chat = try #require(state.activeChats.first { $0.id == "direct-group" })
        state.selection = nil

        await DirectChatChooserSource.workspace(state).open(DirectChatChoice(chat: chat, isArchived: false))

        #expect(runtime.setGroupArchivedCallCount == 0)
        #expect(state.selection == .chat("direct-group"))
    }

    /// An archived chat that cannot be unarchived is not opened out of the sidebar's view.
    @Test func theWorkspaceSourceDoesNotOpenAChatItCouldNotUnarchive() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        var archived = directGroup()
        archived.archived = true
        runtime.installGroups([archived])
        runtime.setGroupArchivedError = FakeMarmotRuntimeError.unused
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let chat = try #require(state.archivedChats.first { $0.id == "direct-group" })

        await DirectChatChooserSource.workspace(state).open(DirectChatChoice(chat: chat, isArchived: true))

        #expect(state.selection != .chat("direct-group"))
        #expect(state.archivedChats.contains { $0.id == "direct-group" })
    }

    /// The source holds the workspace weakly: once it is gone, every call is a no-op rather than
    /// keeping a signed-out workspace alive through a lingering sheet.
    @Test func aSourceOutlivingItsWorkspaceDoesNothing() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        var state: WorkspaceState? = WorkspaceState(clientFactory: { runtime })
        let source = DirectChatChooserSource.workspace(try #require(state))
        state = nil

        #expect(source.activeAccountId() == nil)
        let conversations = source.conversations()
        #expect(conversations.active.isEmpty)
        #expect(conversations.archived.isEmpty)
        await source.open(DirectChatChoice(chat: Self.chat("dm"), isArchived: true))
        await source.startNew(Self.recipient(), nil)

        #expect(runtime.setGroupArchivedCallCount == 0)
        #expect(runtime.createdGroupMemberRefs.isEmpty)
    }
}
