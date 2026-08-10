//
//  ChatListWidthTests.swift
//  whitenoise-macTests
//
//  Guards on the resizable chat-list drawer.
//
//  The mistake these exist to catch is the drawer coming to rest at a width nothing
//  renders correctly at: wide enough for the title column but too narrow for a name,
//  or "collapsed" because an absent preference read as zero.
//

import CoreGraphics
import Foundation
import Testing

@testable import whitenoise_mac

@Suite(.serialized)
struct ChatListWidthTests {
    @Test func resolveClampsToTheAllowedFullRange() {
        #expect(ChatListWidthPolicy.resolve(proposedWidth: 1_000) == ChatListWidthPolicy.maximumWidth)
        #expect(ChatListWidthPolicy.resolve(proposedWidth: 260) == 260)
        #expect(
            ChatListWidthPolicy.resolve(proposedWidth: ChatListWidthPolicy.minimumExpandedWidth - 1)
                == ChatListWidthPolicy.minimumExpandedWidth
        )
    }

    @Test func resolveSnapsPastTheThresholdInsteadOfNarrowingFurther() {
        #expect(
            ChatListWidthPolicy.resolve(proposedWidth: ChatListWidthPolicy.collapseThreshold - 1)
                == ChatListWidthPolicy.collapsedWidth
        )
        #expect(ChatListWidthPolicy.resolve(proposedWidth: 0) == ChatListWidthPolicy.collapsedWidth)
        #expect(ChatListWidthPolicy.resolve(proposedWidth: -400) == ChatListWidthPolicy.collapsedWidth)
        // At and above the threshold the drawer stays a full row, at its narrowest.
        #expect(
            ChatListWidthPolicy.resolve(proposedWidth: ChatListWidthPolicy.collapseThreshold)
                == ChatListWidthPolicy.minimumExpandedWidth
        )
    }

    /// The whole point of the snap: there is no resting width between the avatar rail and the
    /// narrowest full row, because those are exactly the widths that truncate a group name.
    @Test func noProposedWidthResolvesBetweenTheTwoRegimes() {
        for proposed in stride(from: CGFloat(-200), through: 600, by: 1) {
            let resolved = ChatListWidthPolicy.resolve(proposedWidth: proposed)
            #expect(
                resolved == ChatListWidthPolicy.collapsedWidth
                    || (resolved >= ChatListWidthPolicy.minimumExpandedWidth
                        && resolved <= ChatListWidthPolicy.maximumWidth),
                "\(proposed) resolved to an unrenderable \(resolved)"
            )
        }
    }

    @Test func resolveRefusesToCollapseAPaneWithNoRailForm() {
        #expect(
            ChatListWidthPolicy.resolve(proposedWidth: 40, allowsCollapse: false)
                == ChatListWidthPolicy.minimumExpandedWidth
        )
        #expect(
            ChatListWidthPolicy.resolve(proposedWidth: 280, allowsCollapse: false) == 280
        )
    }

    @Test func resolveFallsBackToTheDefaultForANonFiniteWidth() {
        #expect(ChatListWidthPolicy.resolve(proposedWidth: .nan) == ChatListWidthPolicy.defaultWidth)
        #expect(ChatListWidthPolicy.resolve(proposedWidth: .infinity) == ChatListWidthPolicy.defaultWidth)
    }

    /// An absent preference means "never resized", not zero. Routing the missing key through
    /// `resolve` would read a first launch as a collapsed drawer.
    @Test func restoringAnAbsentPreferenceGivesTheDefaultWidthNotACollapsedDrawer() {
        #expect(ChatListWidthPolicy.restored(storedWidth: nil) == ChatListWidthPolicy.defaultWidth)
        #expect(ChatListWidthPolicy.defaultWidth == ChatListWidthPolicy.maximumWidth)
        #expect(!ChatListWidthPolicy.isCollapsed(width: ChatListWidthPolicy.restored(storedWidth: nil)))
        let insideRange = ChatListWidthPolicy.minimumExpandedWidth + 20
        #expect(ChatListWidthPolicy.restored(storedWidth: Double(insideRange)) == insideRange)
        // A width persisted by an older/newer build outside the range is pulled back in.
        #expect(ChatListWidthPolicy.restored(storedWidth: 900) == ChatListWidthPolicy.maximumWidth)
        #expect(ChatListWidthPolicy.restored(storedWidth: 12) == ChatListWidthPolicy.collapsedWidth)
    }

    @Test func isCollapsedSplitsExactlyAtTheNarrowestFullRow() {
        #expect(ChatListWidthPolicy.isCollapsed(width: ChatListWidthPolicy.collapsedWidth))
        #expect(ChatListWidthPolicy.isCollapsed(width: ChatListWidthPolicy.minimumExpandedWidth - 0.5))
        #expect(!ChatListWidthPolicy.isCollapsed(width: ChatListWidthPolicy.minimumExpandedWidth))
        #expect(!ChatListWidthPolicy.isCollapsed(width: ChatListWidthPolicy.maximumWidth))
    }

    /// Without the explicit hop at the boundary, `minimumExpandedWidth - stepIncrement` clamps
    /// straight back to `minimumExpandedWidth` and the rail is unreachable without a pointer.
    @Test func steppingReachesBothRegimesFromTheKeyboard() {
        #expect(
            ChatListWidthPolicy.stepped(from: ChatListWidthPolicy.minimumExpandedWidth, toward: .narrower)
                == ChatListWidthPolicy.collapsedWidth
        )
        #expect(
            ChatListWidthPolicy.stepped(from: ChatListWidthPolicy.collapsedWidth, toward: .wider)
                == ChatListWidthPolicy.minimumExpandedWidth
        )
        #expect(
            ChatListWidthPolicy.stepped(from: ChatListWidthPolicy.collapsedWidth, toward: .narrower)
                == ChatListWidthPolicy.collapsedWidth
        )
        #expect(
            ChatListWidthPolicy.stepped(from: ChatListWidthPolicy.maximumWidth, toward: .wider)
                == ChatListWidthPolicy.maximumWidth
        )
        // The middle of the full range, so a step in either direction lands mid-range rather
        // than on a clamp regardless of where the two ends sit.
        let midRange = (ChatListWidthPolicy.minimumExpandedWidth + ChatListWidthPolicy.maximumWidth) / 2
        #expect(
            ChatListWidthPolicy.stepped(from: midRange, toward: .narrower)
                == midRange - ChatListWidthPolicy.stepIncrement
        )
        #expect(
            ChatListWidthPolicy.stepped(from: midRange, toward: .wider)
                == midRange + ChatListWidthPolicy.stepIncrement
        )
        // A step never lands between the regimes either.
        #expect(
            ChatListWidthPolicy.stepped(
                from: ChatListWidthPolicy.minimumExpandedWidth + 5,
                toward: .narrower
            ) == ChatListWidthPolicy.minimumExpandedWidth
        )
        #expect(
            ChatListWidthPolicy.stepped(
                from: ChatListWidthPolicy.minimumExpandedWidth,
                toward: .narrower,
                allowsCollapse: false
            ) == ChatListWidthPolicy.minimumExpandedWidth
        )
    }

    @MainActor
    @Test func aDragCollapsesTheDrawerAndReleasesTheSidebarSearch() {
        let restore = ChatListWidthTests.clearStoredWidth()
        defer { restore() }
        let state = WorkspaceState()

        #expect(state.chatListDrawerWidth == ChatListWidthPolicy.defaultWidth)
        #expect(!state.isChatListCollapsed)

        state.searchText = "dinner"
        state.resizeChatListDrawer(toProposedWidth: 90)

        #expect(state.isChatListCollapsed)
        #expect(state.chatListDrawerWidth == ChatListWidthPolicy.collapsedWidth)
        // A query the rail can neither show nor clear would filter the list invisibly.
        #expect(state.searchText.isEmpty)

        state.searchText = "dinner"
        state.resizeChatListDrawer(toProposedWidth: 250)

        #expect(!state.isChatListCollapsed)
        #expect(state.chatListDrawerWidth == 250)
        // Widening is not a reason to throw the query away.
        #expect(state.searchText == "dinner")
    }

    @MainActor
    @Test func settingsFloorsTheRenderedWidthWithoutForgettingACollapsedChatList() {
        let restore = ChatListWidthTests.clearStoredWidth()
        defer { restore() }
        let state = WorkspaceState()
        state.resizeChatListDrawer(toProposedWidth: 90)
        #expect(state.chatListWidth == ChatListWidthPolicy.collapsedWidth)

        state.selection = .settings(.profile)

        #expect(!state.isChatListDrawerShowingChats)
        #expect(state.chatListDrawerWidth == ChatListWidthPolicy.minimumExpandedWidth)
        #expect(!state.isChatListCollapsed)
        // Merely visiting settings must not overwrite the preference.
        #expect(state.chatListWidth == ChatListWidthPolicy.collapsedWidth)

        state.selection = .chat("group")
        #expect(state.isChatListCollapsed)
    }

    @MainActor
    @Test func aPaneWithNoRailFormCannotBeDraggedShut() {
        let restore = ChatListWidthTests.clearStoredWidth()
        defer { restore() }
        let state = WorkspaceState()
        state.isNewChatComposerVisible = true

        #expect(!state.isChatListDrawerShowingChats)
        state.resizeChatListDrawer(toProposedWidth: 20)

        #expect(state.chatListWidth == ChatListWidthPolicy.minimumExpandedWidth)
        #expect(!state.isChatListCollapsed)
    }

    @MainActor
    @Test func steppingTheDrawerPersistsTheResolvedWidth() {
        let restore = ChatListWidthTests.clearStoredWidth()
        defer { restore() }
        let state = WorkspaceState()

        state.stepChatListDrawerWidth(.narrower)
        #expect(state.chatListWidth == ChatListWidthPolicy.maximumWidth - ChatListWidthPolicy.stepIncrement)
        #expect(
            UserDefaults.standard.object(forKey: WorkspaceState.chatListWidthKey) as? Double
                == Double(state.chatListWidth)
        )

        while !state.isChatListCollapsed {
            state.stepChatListDrawerWidth(.narrower)
        }
        #expect(state.chatListWidth == ChatListWidthPolicy.collapsedWidth)

        state.stepChatListDrawerWidth(.wider)
        #expect(state.chatListWidth == ChatListWidthPolicy.minimumExpandedWidth)
    }

    /// `WorkspaceState` reads and writes `UserDefaults.standard` for this preference, so a test
    /// that constructs one has to start from a known state and put the user's own width back.
    @MainActor
    private static func clearStoredWidth() -> () -> Void {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: WorkspaceState.chatListWidthKey) as? Double
        defaults.removeObject(forKey: WorkspaceState.chatListWidthKey)
        return {
            if let previous {
                defaults.set(previous, forKey: WorkspaceState.chatListWidthKey)
            } else {
                defaults.removeObject(forKey: WorkspaceState.chatListWidthKey)
            }
        }
    }
}
