//
//  GroupsTests.swift
//  whitenoise-macTests
//
//  Group membership and creation: group details, member mutations, invites, leaving,
//  the group image, contacts and follow state, new-chat drafts and people search.
//
//  Split out of `whitenoise_macTests.swift` verbatim: every test body below is the
//  one that lived in that file, moved rather than rewritten.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MarmotKit
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications

@testable import whitenoise_mac

struct GroupsTests: WorkspaceTestSupport {
    @MainActor
    @Test func groupImageSearchSelectionEncryptsAndUploadsToBlossom() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let imageSourceLoader = FakeGroupImageSourceLoader(
            response: try Self.testPNGData(width: 64, height: 64)
        )
        let imageSearchClient = FakeGroupImageSearchClient(results: [
            GroupImageSearchResult(
                id: "image-1",
                title: "Aurora",
                imageURL: "https://example.com/aurora.jpg",
                thumbnailURL: "https://example.com/aurora-thumb.jpg",
                creator: "Open Photographer",
                license: "by",
                attribution: nil,
                sourceURL: "https://example.com/aurora",
                width: 1024,
                height: 680
            )
        ])
        let state = WorkspaceState(
            groupImageSearchClient: imageSearchClient,
            groupImageSourceLoader: imageSourceLoader,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        state.showGroupImagePicker(for: groupChat)
        #expect(state.groupImageSearchQuery.isEmpty)
        await state.searchGroupImages()
        let emptyImageSearchQueries = await imageSearchClient.queries
        #expect(emptyImageSearchQueries.isEmpty)

        state.groupImageSearchQuery = "aurora"
        await state.searchGroupImages()
        guard let result = state.groupImageResults.first else {
            Issue.record("Expected an image result")
            return
        }
        await state.setGroupImage(result)

        let imageSearchQueries = await imageSearchClient.queries
        #expect(imageSearchQueries == ["aurora"])
        #expect(await imageSourceLoader.requestedURLs == [URL(string: "https://example.com/aurora.jpg")!])
        #expect(runtime.updateGroupImageCallCount == 1)
        #expect(runtime.updatedEncryptedGroupImageMediaType == "image/jpeg")
        #expect(runtime.updatedEncryptedGroupImage?.isEmpty == false)
        #expect(runtime.updateGroupAvatarUrlCallCount == 0)
        #expect(!state.isGroupImagePickerPresented)
        #expect(state.activeChats.first?.pictureURL == nil)
        #expect(state.activeChats.first?.groupImageHashHex == "encrypted-image-hash")
        #expect(state.activeChats.first?.groupImagePayload?.data == runtime.downloadedGroupImage)
    }

    @MainActor
    @Test func localGroupImageSelectionEncryptsAndUploadsToBlossom() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let imageSourceLoader = FakeGroupImageSourceLoader(response: nil)
        let state = WorkspaceState(
            groupImageSourceLoader: imageSourceLoader,
            clientFactory: { runtime }
        )
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("group-image-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try Self.testPNGData(width: 80, height: 60).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        await state.bootstrap()
        let groupChat = try #require(state.activeChats.first)
        state.showGroupImagePicker(for: groupChat)
        await state.setGroupImage(fileURL: imageURL)

        #expect(await imageSourceLoader.requestedURLs.isEmpty)
        #expect(runtime.updateGroupImageCallCount == 1)
        #expect(runtime.updatedEncryptedGroupImageMediaType == "image/jpeg")
        #expect(runtime.updatedEncryptedGroupImage?.isEmpty == false)
        #expect(runtime.updateGroupAvatarUrlCallCount == 0)
        #expect(state.activeChats.first?.groupImageHashHex == "encrypted-image-hash")
        #expect(state.activeChats.first?.groupImagePayload?.data == runtime.downloadedGroupImage)
        #expect(!state.isGroupImagePickerPresented)
    }

    @MainActor
    @Test func clearingGroupImageRemovesEncryptedImageAndLegacyURL() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        var group = messageGroup()
        group.avatarUrl = "https://legacy.example/group.jpg"
        group.imageHashHex = "existing-encrypted-image-hash"
        runtime.installGroup(group)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let groupChat = try #require(state.activeChats.first)
        #expect(runtime.downloadGroupImageCallCount == 0)
        state.showGroupImagePicker(for: groupChat)
        await state.clearGroupImage()

        #expect(runtime.updateGroupAvatarUrlCallCount == 1)
        #expect(runtime.updatedGroupAvatar?.url == nil)
        #expect(runtime.clearGroupImageCallCount == 1)
        #expect(state.activeChats.first?.pictureURL == nil)
        #expect(state.activeChats.first?.groupImageHashHex == nil)
        #expect(!state.isGroupImagePickerPresented)
    }

    @MainActor
    @Test func groupImageUpdateDropsOverlappingDuplicateInvocation() async throws {
        // Issue #134: set/clear group image both funnel through an async avatar update.
        // The in-flight flag must guard the entry point itself so a second control action
        // delivered before SwiftUI disables the UI does not publish a conflicting update.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let imageSourceLoader = FakeGroupImageSourceLoader(
            response: try Self.testPNGData(width: 64, height: 64)
        )
        let state = WorkspaceState(
            groupImageSourceLoader: imageSourceLoader,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        let result = GroupImageSearchResult(
            id: "image-1",
            title: "Aurora",
            imageURL: "https://example.com/aurora.jpg",
            thumbnailURL: "https://example.com/aurora-thumb.jpg",
            creator: "Open Photographer",
            license: "by",
            attribution: nil,
            sourceURL: "https://example.com/aurora",
            width: 1024,
            height: 680
        )

        state.showGroupImagePicker(for: groupChat)
        runtime.groupAvatarUpdateGateEnabled = true
        async let firstUpdate: Void = state.setGroupImage(result)

        while !(state.isSavingGroupImage && runtime.didReachGroupAvatarUpdateGate) {
            await Task.yield()
        }

        // Closing/reopening the picker while the first update is suspended must not clear the
        // in-flight guard; an overlapping clear action still has to be dropped.
        state.closeGroupImagePicker()
        #expect(!state.isGroupImagePickerPresented)
        #expect(state.isSavingGroupImage)
        state.showGroupImagePicker(for: groupChat)
        await state.clearGroupImage()
        #expect(runtime.updateGroupImageCallCount == 1)
        #expect(runtime.clearGroupImageCallCount == 0)

        runtime.releaseGroupAvatarUpdateGate()
        await firstUpdate

        #expect(runtime.updateGroupImageCallCount == 1)
        #expect(runtime.updatedEncryptedGroupImage?.isEmpty == false)
        #expect(!state.isSavingGroupImage)
    }

    @MainActor
    @Test func groupImagePickerDismissesWhenSelectionClears() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        state.showGroupImagePicker(for: groupChat)
        state.selection = nil

        #expect(state.selectedChat == nil)
        #expect(!state.isGroupImagePickerPresented)
    }

    @MainActor
    @Test func groupImagePickerDismissesWhenSelectedChatIsRemoved() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        state.showGroupImagePicker(for: groupChat)
        runtime.installChatListUpdates([
            .removeRow(trigger: .removed, groupIdHex: groupChat.id)
        ])
        await state.reloadChats()
        let didRemoveSelectedChat = await waitFor {
            state.activeChats.isEmpty && state.selectedChat == nil
        }

        #expect(didRemoveSelectedChat)
        #expect(!state.isGroupImagePickerPresented)
    }

    @MainActor
    @Test func groupImagePickerDismissesWhenRemovedChatAutoReselectsNextChat() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first(where: { $0.id == "group" }) else {
            Issue.record("Expected a group chat")
            return
        }

        state.selectChat(groupChat)
        state.showGroupImagePicker(for: groupChat)
        runtime.installChatListUpdates([
            .removeRow(trigger: .removed, groupIdHex: groupChat.id)
        ])
        await state.reloadChats()
        let didReselectNextChat = await waitFor {
            state.selection == .chat("direct-group") && state.selectedChat?.id == "direct-group"
        }

        #expect(didReselectNextChat)
        #expect(!state.isGroupImagePickerPresented)
    }

    @MainActor
    @Test func directChatDoesNotOpenGroupImagePicker() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didHydrateDirectChat = await waitFor {
            state.activeChats.first?.isDirect == true
        }
        guard let directChat = state.activeChats.first else {
            Issue.record("Expected a direct chat")
            return
        }

        state.showGroupImagePicker(for: directChat)

        #expect(didHydrateDirectChat)
        #expect(directChat.isDirect)
        #expect(!state.isGroupImagePickerPresented)
    }

    /// Chat info is the header's own affordance, and it works for a direct chat as well as a group.
    ///
    /// It used to hang off a header sheet that only a group could raise. Opening it now moves the
    /// state the pane slides in on, so this drives that call and reads the state back rather than
    /// looking for a modifier in the header.
    @MainActor
    @Test func openingChatInfoSlidesTheDetailsPaneInForAGroupAndForADirectChat() async throws {
        let account = desktopAccount()
        let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            alongside: [messageGroup()],
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceIdHex,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        #expect(!state.isGroupDetailsPresented, "nothing has been asked for yet")

        let group = try #require(state.activeChats.first { !$0.isDirect })
        await state.showGroupDetails(for: group)
        #expect(state.isGroupDetailsPresented)

        state.closeGroupDetails()
        #expect(!state.isGroupDetailsPresented, "the back control returns to the transcript")
        #expect(state.groupDetailsSnapshot == nil)

        // The affordance the header sheet could never offer: a 1:1 chat has info too.
        let direct = try #require(state.activeChats.first { $0.isDirect })
        await state.showGroupDetails(for: direct)
        #expect(state.isGroupDetailsPresented)

        state.closeGroupDetails()
        #expect(!state.isGroupDetailsPresented)
    }

    /// Both slide-in panes return to the transcript through the same back control.
    ///
    /// The chevron's *position* is no longer a test's business: both panes wear one
    /// `DetailsPaneHeader`, so the leading back / avatar / title / trailing-actions order is written
    /// once and neither pane has an order of its own to drift away from. What is still worth
    /// driving is that the control does what a back control does — from either pane.
    @MainActor
    @Test func bothSlideInPanesReturnToTheTranscriptThroughTheirBackControl() async throws {
        let account = desktopAccount()
        let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            alongside: [messageGroup()],
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceIdHex,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let group = try #require(state.activeChats.first { !$0.isDirect })
        await state.showGroupDetails(for: group)
        state.closeGroupDetails()
        #expect(!state.isGroupDetailsPresented)

        await state.showContactDetails(accountIdHex: aliceIdHex, displayName: "Alice", pictureURL: nil)
        #expect(state.contactDetailsTarget != nil)
        state.closeContactDetails()
        #expect(state.contactDetailsTarget == nil, "the contact pane's back control left it open")
    }

    @MainActor
    @Test func directContactDetailsShowsAndNavigatesToGroupsInCommon() async throws {
        let account = desktopAccount()
        let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            alongside: [messageGroup()],
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceIdHex,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installGroupDetailsRecord(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let directChat = try #require(state.activeChats.first { $0.id == "direct-group" })
        state.selectChat(directChat)
        await state.showGroupDetails(for: directChat)

        // The direct chat whose details are open is the conversation the viewer is already in,
        // so it must not be listed back to them as a group in common.
        #expect(state.commonGroupsForContact.map(\.id) == ["group"])
        #expect(!state.isLoadingCommonGroups)
        #expect(!state.commonGroupsLoadHadFailures)

        let sharedGroup = try #require(state.commonGroupsForContact.first { $0.id == "group" })
        state.openCommonGroup(sharedGroup)
        #expect(state.selection == .chat("group"))
        #expect(!state.isGroupDetailsPresented)
        #expect(state.commonGroupsForContact.isEmpty)
    }

    @MainActor
    @Test func groupMemberContactDetailsResolveProfileAndReturnToGroupInfo() async throws {
        let account = desktopAccount()
        let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        )
        runtime.installProfile(
            accountIdHex: aliceIdHex,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Cooper",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let groupChat = try #require(state.activeChats.first { $0.id == "group" })
        state.selectChat(groupChat)
        await state.showGroupDetails(for: groupChat)
        let alice = try #require(state.groupDetailsSnapshot?.members.first { $0.id == aliceIdHex })

        await state.showContactDetails(for: alice)

        #expect(state.contactDetailsTarget?.accountIdHex == aliceIdHex)
        #expect(state.contactDetailsTarget?.title == "Alice Cooper")
        #expect(state.contactDetailsTarget?.pictureURL == "https://example.com/alice.png")
        // "group" is the group whose details are open, so the only shared conversation is
        // filtered out and the section reads empty.
        #expect(state.commonGroupsForContact.isEmpty)
        #expect(!state.isLoadingContactDetails)
        #expect(state.isGroupDetailsPresented)

        state.closeContactDetails()
        #expect(state.contactDetailsTarget == nil)
        #expect(state.isGroupDetailsPresented)
        #expect(state.commonGroupsForContact.isEmpty)
    }

    @MainActor
    @Test func groupMemberContactDetailsListDirectChatButNotTheOpenGroup() async throws {
        let account = desktopAccount()
        let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            alongside: [messageGroup()],
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceIdHex,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installGroupDetailsRecord(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let groupChat = try #require(state.activeChats.first { $0.id == "group" })
        state.selectChat(groupChat)
        await state.showGroupDetails(for: groupChat)
        let alice = try #require(state.groupDetailsSnapshot?.members.first { $0.id == aliceIdHex })

        await state.showContactDetails(for: alice)

        // The open group is dropped; the direct chat the viewer shares with Alice still shows.
        #expect(state.commonGroupsForContact.map(\.id) == ["direct-group"])
        let directMessageGroup = try #require(state.commonGroupsForContact.first)
        #expect(directMessageGroup.isDirect)
        #expect(!state.commonGroupsLoadHadFailures)
    }

    @MainActor
    @Test func messageSenderContactDetailsExcludeTheHostingGroup() async throws {
        let account = desktopAccount()
        let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            alongside: [messageGroup()],
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceIdHex,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installGroupDetailsRecord(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let message = MessageItem(
            id: "m1",
            groupIdHex: "group",
            senderAccountIdHex: aliceIdHex,
            senderName: "Alice",
            body: "Hello",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            timelineAt: 1_700_000_000,
            isOutgoing: false
        )
        await state.showContactDetails(for: message)

        // Tapping a sender inside "group" opens their card from that group, so it is not
        // reported back as a group in common.
        #expect(state.contactDetailsTarget?.accountIdHex == aliceIdHex)
        #expect(state.commonGroupsForContact.map(\.id) == ["direct-group"])
    }

    @MainActor
    @Test func followToggleTracksTheReturnedListRatherThanTheRequestedMutation() async throws {
        let account = desktopAccount()
        let aliceHex = String(repeating: "a", count: 64)
        let bobHex = String(repeating: "b", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        await state.showContactDetails(accountIdHex: aliceHex, displayName: "Alice", pictureURL: nil)
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == false)

        await state.toggleFollow(accountIdHex: aliceHex)

        #expect(
            runtime.followMutationCalls == [
                FollowMutationCall(accountRef: account.label, userRef: aliceHex, isFollow: true)
            ]
        )
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == true)
        #expect(state.followedAccountIdsHex == [aliceHex])
        #expect(!state.isTogglingFollow)
        #expect(state.lastError == nil)

        await state.toggleFollow(accountIdHex: aliceHex)
        #expect(runtime.followMutationCalls.last?.isFollow == false)
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == false)

        // The mutations return the complete list the core actually published. When that list
        // contradicts the requested mutation, the list is what the UI must report.
        runtime.followMutationResultOverride = [bobHex]
        await state.toggleFollow(accountIdHex: aliceHex)
        #expect(runtime.followMutationCalls.last?.isFollow == true)
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == false)
        #expect(state.isFollowingContact(accountIdHex: bobHex) == true)
    }

    @MainActor
    @Test func followListUnavailableLeavesTheCachedFollowStateUntouched() async throws {
        // `FollowListUnavailable` is the core refusing to publish a replacement it could not
        // base on the current contact-list event: nothing changed, and a retry is safe. It
        // must not read as a lost follow, and must not move the cached state either way.
        let account = desktopAccount()
        let aliceHex = String(repeating: "a", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installFollows(accountRef: account.label, follows: [aliceHex])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        await state.showContactDetails(accountIdHex: aliceHex, displayName: "Alice", pictureURL: nil)
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == true)

        runtime.followMutationError = MarmotKitError.FollowListUnavailable
        await state.toggleFollow(accountIdHex: aliceHex)

        #expect(state.isFollowingContact(accountIdHex: aliceHex) == true)
        #expect(!state.isTogglingFollow)
        #expect(
            state.lastError
                == L10n.string(
                    "Couldn't reach your relays to update your follow list. Nothing changed — try again."
                )
        )
    }

    @MainActor
    @Test func failedFollowStatusRefreshKeepsTheKnownRelationship() async throws {
        // A failed refresh must not fail closed: showing "Follow" for someone this account
        // already follows invites a duplicate publish and misreports the relationship.
        let account = desktopAccount()
        let aliceHex = String(repeating: "a", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installFollows(accountRef: account.label, follows: [aliceHex])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        await state.showContactDetails(accountIdHex: aliceHex, displayName: "Alice", pictureURL: nil)
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == true)
        state.closeContactDetails()

        runtime.followReadError = FakeMarmotRuntimeError.followListReadFailed
        await state.showContactDetails(accountIdHex: aliceHex, displayName: "Alice", pictureURL: nil)

        #expect(state.isFollowingContact(accountIdHex: aliceHex) == true)
        // A known relationship survives the failure, so there is nothing to retry.
        #expect(state.contactFollowStatus(accountIdHex: aliceHex) == .known(true))
        #expect(!state.followStatusReadFailed)
        #expect(!state.isLoadingContactDetails)
    }

    @MainActor
    @Test func unreadableFollowStatusOffersARetryInsteadOfHidingTheControl() async throws {
        // An unknown relationship must never be a resting state: the control stays put and
        // asks to be retried, so a failed read cannot look like a missing feature.
        let account = desktopAccount()
        let aliceHex = String(repeating: "a", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installFollows(accountRef: account.label, follows: [aliceHex])
        runtime.followReadError = FakeMarmotRuntimeError.followListReadFailed
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        await state.showContactDetails(accountIdHex: aliceHex, displayName: "Alice", pictureURL: nil)

        #expect(state.contactFollowStatus(accountIdHex: aliceHex) == .unavailable)
        #expect(state.followStatusReadFailed)
        #expect(!state.isLoadingFollowStatus)
        // The read is retried once on its own before the control gives up and asks.
        #expect(runtime.isFollowingCallCount == WorkspaceState.followStatusAttemptLimit)

        runtime.followReadError = nil
        await state.refreshFollowStatus(forContactIdHex: aliceHex)

        #expect(state.contactFollowStatus(accountIdHex: aliceHex) == .known(true))
        #expect(!state.followStatusReadFailed)
    }

    @MainActor
    @Test func directChatInfoResolvesThePeerFollowState() async throws {
        // Chat info is the profile a 1:1 conversation opens, so it carries the follow control
        // and has to resolve the relationship on its own — reaching it must not require
        // opening the peer's contact details first.
        let account = desktopAccount()
        let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            alongside: [],
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceIdHex,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installGroupDetailsRecord(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        )
        runtime.installFollows(accountRef: account.label, follows: [aliceIdHex])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let directChat = try #require(state.activeChats.first { $0.id == "direct-group" })
        state.selectChat(directChat)
        await state.showGroupDetails(for: directChat)

        #expect(state.contactFollowStatus(accountIdHex: aliceIdHex) == .known(true))
        #expect(state.canOfferFollow(accountIdHex: aliceIdHex))
    }

    @MainActor
    @Test func followIsNeverOfferedForAnIdentitySignedInOnThisDevice() async throws {
        // Not just the active account: a second identity signed in here is still you, and a
        // blank key has nobody to act on at all.
        let account = desktopAccount()
        let aliceHex = String(repeating: "a", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        #expect(!state.canOfferFollow(accountIdHex: account.accountIdHex))
        #expect(!state.canOfferFollow(accountIdHex: account.accountIdHex.uppercased()))
        #expect(!state.canOfferFollow(accountIdHex: "   "))
        #expect(state.canOfferFollow(accountIdHex: aliceHex))
    }

    @MainActor
    @Test func noteToSelfChatInfoReadsNoFollowState() async throws {
        // A note-to-self chat seeds its avatar from the group id, so keying the read off the
        // seed would ask the core whether the account follows a group.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let noteToSelf = ChatItem(
            id: "self-group",
            title: "Note to self",
            subtitle: "Direct message",
            preview: "",
            updatedAt: nil,
            avatarSeed: "self-group",
            pictureURL: nil,
            unreadCount: 0,
            isDirect: true
        )
        #expect(noteToSelf.directPeerAccountIdHex == nil)

        await state.refreshDirectPeerFollowStatus(for: noteToSelf)
        #expect(runtime.isFollowingCallCount == 0)
    }

    /// Follow leads the contact profile's action row.
    ///
    /// It used to sit inside the same form row as "Copy Public Key", several screens of detail below
    /// the fold, which is why nobody could find it. The order is the fix, so it is stated once in
    /// `ContactProfileAction.ordered` and the row is built from it — this asserts the order itself
    /// rather than the stack that happens to render it.
    @MainActor
    @Test func aContactProfileLeadsWithFollowAndOffersMessageAfterIt() async throws {
        #expect(ContactProfileAction.ordered == [.follow, .message])
        #expect(
            Set(ContactProfileAction.ordered) == Set(ContactProfileAction.allCases),
            "an action was added to the profile row and left out of its order"
        )

        // And chat info for a direct chat is the peer's profile too, so opening it resolves the
        // follow relationship the same control needs — the reason it can carry one at all.
        let account = desktopAccount()
        let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            alongside: [messageGroup()],
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceIdHex,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let direct = try #require(state.activeChats.first { $0.isDirect })
        let followReadsBefore = runtime.isFollowingCallCount
        await state.showGroupDetails(for: direct)
        #expect(
            runtime.isFollowingCallCount > followReadsBefore,
            "chat info for a 1:1 never asked who the peer is to you"
        )
    }

    /// The composer prompt and chat info answer the same invite, and answering it reaches the core
    /// the same way from both.
    ///
    /// Answering was written out twice, which is how the two came to disagree about the icon, the
    /// label and — visibly — the shape. They share `PendingInviteActionButtons` now; what is worth
    /// driving is that both entry points still accept and decline the invite that is actually open.
    @MainActor
    @Test func bothInvitePromptsAcceptAndDeclineTheSameInvite() async throws {
        for acceptFromChatInfo in [true, false] {
            let account = desktopAccount()
            var details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
            details.group.pendingConfirmation = true
            let runtime = FakeMarmotRuntime(accounts: [account])
            runtime.installGroupDetails(details)
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()

            let invite = try #require(state.activeChats.first)
            state.selection = .chat(invite.id)

            if acceptFromChatInfo {
                await state.showGroupDetails(for: invite)
                await state.acceptSelectedGroupInvite()
            } else {
                await state.acceptGroupInvite(for: invite)
            }
            #expect(
                runtime.acceptGroupInviteCallCount == 1,
                "the \(acceptFromChatInfo ? "chat info" : "composer") prompt did not answer the invite"
            )
            #expect(runtime.declineGroupInviteCallCount == 0)
        }

        // …and declining reaches the core from both, rather than only from the prompt that owned
        // the pair when it was written out twice.
        for declineFromChatInfo in [true, false] {
            let account = desktopAccount()
            var details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
            details.group.pendingConfirmation = true
            let runtime = FakeMarmotRuntime(accounts: [account])
            runtime.installGroupDetails(details)
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()

            let invite = try #require(state.activeChats.first)
            state.selection = .chat(invite.id)

            if declineFromChatInfo {
                await state.showGroupDetails(for: invite)
                await state.declineSelectedGroupInvite()
            } else {
                await state.declineGroupInvite(for: invite)
            }
            #expect(runtime.declineGroupInviteCallCount == 1)
            #expect(runtime.acceptGroupInviteCallCount == 0)
        }
    }

    /// One shape table, so a pair of buttons standing next to each other cannot disagree about
    /// their outline.
    ///
    /// The visible defect: `Accept` named no border shape at all, so `.glassProminent` drew it as
    /// the platform's capsule beside an 8pt rounded-rectangle `Decline`. Both tiers ask the same
    /// function now — the primary for a `ButtonBorderShape`, the ground-drawing tiers for the whole
    /// outline — and this asserts the two answers describe the same shape.
    @MainActor
    @Test func everyButtonTierTakesItsOutlineFromTheOneShapeTable() {
        let rect = CGRect(x: 0, y: 0, width: 180, height: 44)

        for controlSize in [ControlSize.small, .regular, .large] {
            let radius = WNButtonMetrics.cornerRadius(for: controlSize)
            #expect(
                WNButtonMetrics.backgroundShape(.rounded, for: controlSize).path(in: rect)
                    == RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
            )
            #expect(
                WNButtonMetrics.backgroundShape(.capsule, for: controlSize).path(in: rect)
                    == Capsule(style: .continuous).path(in: rect)
            )
            #expect(WNButtonMetrics.borderShape(.capsule, for: controlSize) == .capsule)
            #expect(
                WNButtonMetrics.borderShape(.rounded, for: controlSize)
                    == .roundedRectangle(radius: radius)
            )
        }

        // A capsule has no radius of its own — it is always half its own height, which is what
        // keeps a pill a pill as the control grows. A rounded tier opens up at `.large`.
        #expect(WNButtonMetrics.cornerRadius(for: .large) > WNButtonMetrics.cornerRadius(for: .regular))
    }

    @MainActor
    @Test func followStatusReportsLoadingWhileTheReadIsInFlight() async throws {
        let account = desktopAccount()
        let aliceHex = String(repeating: "a", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installFollows(accountRef: account.label, follows: [aliceHex])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        runtime.followReadGateEnabled = true
        async let details: Void = state.showContactDetails(
            accountIdHex: aliceHex,
            displayName: "Alice",
            pictureURL: nil
        )
        while !runtime.didReachFollowReadGate {
            await Task.yield()
        }

        #expect(state.contactFollowStatus(accountIdHex: aliceHex) == .loading)
        #expect(state.isLoadingFollowStatus)

        runtime.releaseFollowReadGate()
        await details

        #expect(state.contactFollowStatus(accountIdHex: aliceHex) == .known(true))
        #expect(!state.isLoadingFollowStatus)

        // Closing the sheet must not strand the loading or retry state for the next contact.
        state.closeContactDetails()
        #expect(!state.isLoadingFollowStatus)
        #expect(!state.followStatusReadFailed)
        #expect(state.followStatusContactIdHex == nil)
    }

    @MainActor
    @Test func openingAProfileDoesNotDiscardAnInFlightFollowListRefresh() async throws {
        // The two reads answer different questions — "who does this account follow" and "does it
        // follow this one contact" — so they must not share a request generation. They did, and a
        // profile opening mid-refresh silently discarded the whole-list read: `hasCompleteFollowList`
        // stayed false, which leaves every unresolved contact reading as "Checking…" forever and
        // drops followed-only people out of the compose list.
        let account = desktopAccount()
        let aliceHex = String(repeating: "a", count: 64)
        let bobHex = String(repeating: "b", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installFollows(accountRef: account.label, follows: [aliceHex])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        runtime.followListReadGateEnabled = true
        async let listRefresh: Bool = state.refreshFollowedAccounts()
        while !runtime.didReachFollowListReadGate {
            await Task.yield()
        }

        // A profile opens while the list refresh is parked mid-flight.
        await state.refreshFollowStatus(forContactIdHex: bobHex)
        #expect(state.contactFollowStatus(accountIdHex: bobHex) == .known(false))

        runtime.releaseFollowListReadGate()
        let applied = await listRefresh

        #expect(applied)
        #expect(state.hasCompleteFollowList)
        #expect(state.followedAccountIdsHex == [aliceHex])
        // The whole list settles the contacts it does not name, rather than stranding them.
        #expect(state.isFollowingContact(accountIdHex: bobHex) == false)
    }

    @MainActor
    @Test func aFollowReadResolvedBeforeAMutationCannotClobberThePublishedList() async throws {
        // The relationship is already known, so the button is live while a refresh is still in
        // flight. That read resolved "not following" before the mutation ran; letting it land
        // afterwards flips the control back to "Follow" for someone just followed, and the next
        // tap would try to follow them a second time.
        let account = desktopAccount()
        let aliceHex = String(repeating: "a", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        // A complete list settles the relationship, so the control renders `.known` — not
        // `.loading` — and stays tappable while the per-contact read below is parked.
        #expect(await state.refreshFollowedAccounts())
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == false)

        runtime.followReadGateEnabled = true
        async let staleRead: Void = state.refreshFollowStatus(forContactIdHex: aliceHex)
        while !runtime.didReachFollowReadGate {
            await Task.yield()
        }

        await state.toggleFollow(accountIdHex: aliceHex)
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == true)

        runtime.releaseFollowReadGate()
        await staleRead

        // The mutation published the newer truth; the older answer is dropped, not written back.
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == true)
        #expect(state.contactFollowStatus(accountIdHex: aliceHex) == .known(true))
        #expect(state.followedAccountIdsHex == [aliceHex])
    }

    @MainActor
    @Test func followMutationCompletingAfterTheContactSheetClosesIsDropped() async throws {
        // The #135 shape: a late completion must not resurrect the spinner or post an error
        // against a screen the user already left.
        let account = desktopAccount()
        let aliceHex = String(repeating: "a", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        await state.showContactDetails(accountIdHex: aliceHex, displayName: "Alice", pictureURL: nil)
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == false)

        runtime.followMutationGateEnabled = true
        async let toggle: Void = state.toggleFollow(accountIdHex: aliceHex)
        while !runtime.didReachFollowMutationGate {
            await Task.yield()
        }
        #expect(state.isTogglingFollow)

        state.closeContactDetails()
        #expect(!state.isTogglingFollow)

        runtime.releaseFollowMutationGate()
        await toggle

        #expect(!state.isTogglingFollow)
        #expect(state.contactDetailsTarget == nil)
        #expect(state.lastError == nil)
        // Dropped, not applied — the next read of the list picks the published follow up.
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == false)
    }

    @MainActor
    @Test func switchingAccountsClearsTheFollowList() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let primary = desktopAccount()
        let secondary = AccountSummaryFfi(
            label: "Second Identity",
            accountIdHex: String(repeating: "2", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceHex = String(repeating: "a", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        runtime.installFollows(accountRef: primary.label, follows: [aliceHex])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        #expect(await state.refreshFollowedAccounts())
        #expect(state.followedAccountIdsHex == [aliceHex])
        #expect(state.hasCompleteFollowList)

        let other = try #require(state.accounts.first { $0.accountIdHex == secondary.accountIdHex })
        state.selectAccount(other)

        #expect(state.followedAccountIdsHex.isEmpty)
        #expect(!state.hasCompleteFollowList)
        #expect(state.isFollowingContact(accountIdHex: aliceHex) == nil)
    }

    @MainActor
    @Test func followIsBlockedForEveryLocalAccountNotJustTheActiveOne() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let primary = desktopAccount()
        let secondary = AccountSummaryFfi(
            label: "Second Identity",
            accountIdHex: String(repeating: "2", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        // A whole-list read settles every contact, so nothing but the self-check can be
        // what stops these two mutations.
        #expect(await state.refreshFollowedAccounts())
        #expect(state.isFollowingContact(accountIdHex: secondary.accountIdHex) == false)

        await state.toggleFollow(accountIdHex: secondary.accountIdHex)
        await state.toggleFollow(accountIdHex: primary.accountIdHex)

        #expect(runtime.followMutationCalls.isEmpty)
        #expect(state.followedAccountIdsHex.isEmpty)
        #expect(!state.isTogglingFollow)
    }

    @MainActor
    @Test func composeContactsIncludeFollowedAccountsWithNoChatOrSharedGroup() async throws {
        let account = desktopAccount()
        let aliceHex = String(repeating: "a", count: 64)
        let carolHex = String(repeating: "c", count: 64)
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceHex,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installProfile(
            accountIdHex: carolHex,
            profile: UserProfileMetadataFfi(
                name: "carol",
                displayName: "Carol",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        // Alice is both a follow and an existing DM; Carol has only ever been followed.
        runtime.installFollows(accountRef: account.label, follows: [aliceHex, carolHex])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        await state.refreshComposeContacts()

        #expect(state.composeContacts.map(\.accountIdHex).sorted() == [aliceHex, carolHex].sorted())

        let alice = try #require(state.composeContacts.first { $0.accountIdHex == aliceHex })
        #expect(alice.displayName == "Alice")
        #expect(alice.pictureURL == "https://example.com/alice.png")

        let carol = try #require(state.composeContacts.first { $0.accountIdHex == carolHex })
        #expect(carol.displayName == "Carol")
        #expect(carol.lastActivity == nil)
        // No `lastActivity` files a followed stranger below every real conversation.
        #expect(state.composeContacts.last?.accountIdHex == carolHex)
    }

    @MainActor
    @Test func staleGroupDetailsLoadDoesNotClobberNewerSnapshotOrDropSpinner() async throws {
        // Issue #135: `loadGroupDetails` is reachable concurrently for the same group, and the FFI
        // pair it awaits is completion-ordered, not request-ordered. An older, slower load must not
        // overwrite a newer snapshot, must not report a stale error, and an older completion must
        // not clear `isLoadingGroupDetails` while a newer load is still running.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        var olderDetails = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        olderDetails.group.name = "Older Snapshot"
        runtime.installGroupDetails(olderDetails)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }
        await state.showGroupDetails(for: groupChat)
        #expect(state.groupDetailsSnapshot?.name == "Older Snapshot")

        // Arm the gate so the next `groupDetails` FFI call (the older load) suspends in-flight after
        // capturing the older details.
        runtime.groupDetailsGateEnabled = true
        async let older: Void = state.reloadSelectedGroupDetails()
        while !(state.isLoadingGroupDetails && runtime.didReachGroupDetailsGate) {
            await Task.yield()
        }
        #expect(state.isLoadingGroupDetails)

        // While the older load is held, install a newer snapshot and run a newer load to completion.
        // The gate only holds the first call, so this newer load is not gated.
        var newerDetails = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        newerDetails.group.name = "Newer Snapshot"
        runtime.installGroupDetails(newerDetails)
        await state.reloadSelectedGroupDetails()

        // The newer load applied its snapshot and, owning the spinner, cleared it.
        #expect(state.groupDetailsSnapshot?.name == "Newer Snapshot")
        #expect(state.isLoadingGroupDetails == false)

        // Release the older load. Its completion is now superseded, so it must neither overwrite the
        // newer snapshot, report an error, nor resurrect the spinner.
        runtime.releaseGroupDetailsGate()
        _ = await older

        #expect(state.groupDetailsSnapshot?.name == "Newer Snapshot")
        #expect(state.isLoadingGroupDetails == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func closingGroupDetailsInvalidatesInFlightLoad() async throws {
        // Issue #135: closing group details must invalidate any in-flight load so a stale completion
        // cannot repopulate the closed snapshot or resurrect the shared spinner.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.showGroupDetails(for: groupChat)
        #expect(state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot?.name == "Test Group")

        // Hold a reload in-flight at the gate, then close group details before it completes.
        // Opening first avoids the chat-list enrichment task racing to consume the test gate.
        runtime.groupDetailsGateEnabled = true
        async let inflight: Void = state.reloadSelectedGroupDetails()
        while !(state.isLoadingGroupDetails && runtime.didReachGroupDetailsGate) {
            await Task.yield()
        }

        state.closeGroupDetails()
        #expect(!state.isGroupDetailsPresented)
        #expect(state.isLoadingGroupDetails == false)
        #expect(state.groupDetailsSnapshot == nil)

        // Releasing the now-invalidated load must not repopulate the closed UI or set the spinner.
        runtime.releaseGroupDetailsGate()
        _ = await inflight

        #expect(!state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot == nil)
        #expect(state.isLoadingGroupDetails == false)
    }

    @MainActor
    @Test func closingGroupDetailsPreservesOperationOwnedFlags() {
        // Issues #522 and #553: these flags are mutexes owned by the async operations that set them.
        // Closing the panel while FFI is suspended must leave them set until each operation's defer runs.
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        state.isSavingGroupProfile = true
        state.isInvitingGroupMember = true
        state.isLeavingGroup = true
        state.isSavingGroupImage = true
        state.isUpdatingDisappearingMessages = true
        state.isAcceptingGroupInvite = true
        state.isDecliningGroupInvite = true
        state.mutatingGroupMemberId = "member-in-flight"

        state.closeGroupDetails()

        #expect(state.isSavingGroupProfile)
        #expect(state.isInvitingGroupMember)
        #expect(state.isLeavingGroup)
        #expect(state.isSavingGroupImage)
        #expect(state.isUpdatingDisappearingMessages)
        #expect(state.isAcceptingGroupInvite)
        #expect(state.isDecliningGroupInvite)
        #expect(state.mutatingGroupMemberId == "member-in-flight")
        #expect(state.hasInFlightGroupCommit)
    }

    @MainActor
    @Test func accountScopedUITeardownPreservesOperationOwnedFlags() {
        // Issue #523 follow-up: account-scoped group UI teardown must not clear operation-owned
        // group-commit flags while FFI is still suspended.
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        state.isSavingGroupProfile = true
        state.isInvitingGroupMember = true
        state.isLeavingGroup = true
        state.isSavingGroupImage = true
        state.isUpdatingDisappearingMessages = true
        state.mutatingGroupMemberId = "member-in-flight"

        state.resetActiveAccountUIState()

        #expect(state.isSavingGroupProfile)
        #expect(state.isInvitingGroupMember)
        #expect(state.isLeavingGroup)
        #expect(state.isSavingGroupImage)
        #expect(state.isUpdatingDisappearingMessages)
        #expect(state.mutatingGroupMemberId == "member-in-flight")
        #expect(state.hasInFlightGroupCommit)
    }

    @MainActor
    @Test func hasInFlightGroupCommitReflectsEachMLSCommitOwnershipState() {
        // Issue #523: every MLS group-commit operation must contribute to the shared mutex.
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })

        #expect(!state.hasInFlightGroupCommit)

        state.isSavingGroupProfile = true
        #expect(state.hasInFlightGroupCommit)
        state.isSavingGroupProfile = false

        state.isInvitingGroupMember = true
        #expect(state.hasInFlightGroupCommit)
        state.isInvitingGroupMember = false

        state.mutatingGroupMemberId = "member-in-flight"
        #expect(state.hasInFlightGroupCommit)
        state.mutatingGroupMemberId = nil

        state.isUpdatingDisappearingMessages = true
        #expect(state.hasInFlightGroupCommit)
        state.isUpdatingDisappearingMessages = false

        state.isLeavingGroup = true
        #expect(state.hasInFlightGroupCommit)
        state.isLeavingGroup = false

        state.isSavingGroupImage = true
        #expect(state.hasInFlightGroupCommit)
        state.isSavingGroupImage = false

        #expect(!state.hasInFlightGroupCommit)
    }

    @MainActor
    @Test func closingGroupDetailsInvalidatesInFlightGroupMemberMutationApply() async throws {
        // Issue #392: group-member mutations return a fresh group-details snapshot. If the details
        // panel is closed while the mutation is in flight, that completion must not repopulate the
        // closed panel's backing snapshot.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let groupChat = try #require(state.activeChats.first { $0.id == "group" })
        let member = try #require(state.groupDetailsSnapshot?.members.first { !$0.isSelf })

        runtime.groupMutationGateEnabled = true
        async let promotion: Void = state.promoteGroupMember(member)
        while !(state.mutatingGroupMemberId == member.id && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        state.closeGroupDetails()
        #expect(state.groupDetailsSnapshot == nil)
        #expect(!state.isGroupDetailsPresented)
        #expect(state.mutatingGroupMemberId == member.id)

        // Issue #522: reopening the same group while the first MLS commit is still suspended must
        // not permit a second member mutation through the shared in-flight guard.
        await state.showGroupDetails(for: groupChat)
        #expect(state.groupDetailsSnapshot?.members.contains(where: { $0.id == member.id }) == true)
        await state.promoteGroupMember(member)
        #expect(runtime.promoteAdminDetailedCallCount == 1)
        state.closeGroupDetails()

        runtime.releaseGroupMutationGate()
        await promotion

        #expect(state.groupDetailsSnapshot == nil)
        #expect(!state.isGroupDetailsPresented)
        #expect(state.mutatingGroupMemberId == nil)
    }

    @MainActor
    @Test func accountSwitchInvalidatesInFlightGroupMemberMutationCacheApply() async throws {
        // Issue #392: an account switch clears the member cache. A mutation started by the previous
        // account must not re-seed that cache after the switch completes.
        let primary = desktopAccount()
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, backup])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: primary.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let primaryAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })
        state.prepareForActiveAccountSwitch(to: primaryAccount, preservingMessageCacheFor: nil)
        await state.reloadChats(forceFreshSnapshot: true)
        let groupChat = try #require(state.activeChats.first { $0.id == "group" })
        state.selection = .chat(groupChat.id)
        await state.showGroupDetails(for: groupChat)
        let member = try #require(state.groupDetailsSnapshot?.members.first { !$0.isSelf })
        #expect(state.groupMemberDetailsCache["group"] != nil)

        runtime.groupMutationGateEnabled = true
        async let promotion: Void = state.promoteGroupMember(member)
        while !(state.mutatingGroupMemberId == member.id && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.prepareForActiveAccountSwitch(to: backupAccount, preservingMessageCacheFor: nil)
        #expect(state.activeAccountId == "Backup Account")
        #expect(state.groupMemberDetailsCache.isEmpty)

        runtime.releaseGroupMutationGate()
        await promotion

        #expect(state.activeAccountId == "Backup Account")
        #expect(state.groupMemberDetailsCache.isEmpty)
        #expect(state.mutatingGroupMemberId == nil)
    }

    @MainActor
    @Test func groupMemberMutationInvalidatesOlderInFlightGroupDetailsLoad() async throws {
        // Issue #392 follow-up: a mutation applies a fresh details/member snapshot. An older
        // loadGroupDetails call that was already waiting in FFI must not complete afterward and
        // overwrite the mutation result with its pre-mutation snapshot.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let member = try #require(state.groupDetailsSnapshot?.members.first { !$0.isSelf })
        #expect(member.isAdmin == false)

        runtime.groupDetailsGateEnabled = true
        async let staleLoad: Void = state.reloadSelectedGroupDetails()
        while !(state.isLoadingGroupDetails && runtime.didReachGroupDetailsGate) {
            await Task.yield()
        }

        await state.promoteGroupMember(member)
        #expect(state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id })?.isAdmin == true)
        #expect(state.isLoadingGroupDetails == false)

        runtime.releaseGroupDetailsGate()
        await staleLoad

        #expect(state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id })?.isAdmin == true)
        #expect(state.isLoadingGroupDetails == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func groupDetailsProfileSaveAndInviteUseBindings() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.installNormalizedMemberRef(
            query: "npub1newmemzer",
            accountIdHex: "new1234567890new1234567890new1234567890new1234567890new1",
            npub: "npub1newmemzer"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.showGroupDetails(for: groupChat)
        #expect(state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot?.name == "Test Group")
        #expect(state.groupDetailsSnapshot?.members.count == 3)
        #expect(state.groupDetailsSnapshot?.canInvite == true)
        #expect(state.groupDetailsSnapshot?.relays == MarmotClient.seedRelays)
        #expect(state.groupDetailsSnapshot?.adminIds == [account.accountIdHex])
        #expect(state.groupDetailsSnapshot?.pendingConfirmation == false)

        state.groupProfileDraftName = "Renamed Group"
        state.groupProfileDraftDescription = "Planning room"
        await state.saveGroupProfile()

        #expect(
            runtime.updatedGroupProfile
                == UpdatedGroupProfile(
                    groupIdHex: "group",
                    name: "Renamed Group",
                    description: "Planning room"
                ))
        #expect(state.groupDetailsSnapshot?.name == "Renamed Group")
        #expect(state.activeChats.first?.title == "Renamed Group")

        state.groupInviteMemberQuery = "npub1newmemzer"
        await state.inviteMemberToSelectedGroup()

        #expect(runtime.invitedMemberRefs == ["npub1newmemzer"])
        #expect(state.groupInviteMemberQuery.isEmpty)
        #expect(state.groupDetailsSnapshot?.members.contains { $0.npub == "npub1newmemzer" } == true)
    }

    @MainActor
    @Test func groupInviteAcceptUsesBindingAndClearsPendingState() async throws {
        let account = desktopAccount()
        var details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        details.group.pendingConfirmation = true
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(details)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }
        #expect(groupChat.pendingConfirmation)

        await state.showGroupDetails(for: groupChat)
        #expect(state.groupDetailsSnapshot?.pendingConfirmation == true)

        await state.acceptSelectedGroupInvite()

        #expect(runtime.acceptedInviteGroupIds == ["group"])
        #expect(state.isGroupDetailsPresented)
        #expect(state.groupDetailsSnapshot?.pendingConfirmation == false)
        #expect(state.activeChats.first?.pendingConfirmation == false)
    }

    @MainActor
    @Test func groupInviteDeclineUsesBindingAndRemovesChat() async throws {
        let account = desktopAccount()
        var details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        details.group.pendingConfirmation = true
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(details)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }
        await state.showGroupDetails(for: groupChat)

        await state.declineSelectedGroupInvite()

        #expect(runtime.declinedInviteGroupIds == ["group"])
        #expect(!state.isGroupDetailsPresented)
        #expect(state.activeChats.isEmpty)
        #expect(state.selectedChat == nil)
    }

    @MainActor
    @Test func pendingInviteAvatarOpensTheInvitersProfileWithTheirNpub() async throws {
        // End to end for the invite prompt's avatar: the roster read that names the inviter also
        // has to leave enough behind to *open* them — the npub above all, since checking the key
        // is why someone looks at a profile before accepting an invite from a name they may not
        // recognise.
        let account = desktopAccount()
        let aliceIdHex = "alice1234567890alice1234567890alice1234567890alice1234567890"
        var details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        details.group.pendingConfirmation = true
        details.group.welcomerAccountIdHex = aliceIdHex
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(details)
        runtime.installProfile(
            accountIdHex: aliceIdHex,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Inviter",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let groupChat = try #require(state.activeChats.first)
        #expect(groupChat.pendingConfirmation)

        _ = await state.cachedGroupMembers(
            groupIdHex: groupChat.id,
            account: try #require(state.activeAccount),
            client: runtime
        )
        await state.settlePeerProfileRefreshQueueForTesting()

        let inviter = try #require(state.pendingInviteInviterIdentity(for: groupChat))
        #expect(inviter.accountIdHex == aliceIdHex)
        #expect(inviter.npub == "npub1alyce")
        // The avatar draws the published picture, so it is recognisably them and not a monogram.
        #expect(inviter.sanitizedPictureURL == URL(string: "https://example.com/alice.png"))

        let name = try #require(state.inviterDisplayName(forGroupIdHex: groupChat.id))
        await state.showContactDetails(for: inviter, named: name, invitedTo: groupChat)

        let target = try #require(state.contactDetailsTarget)
        #expect(target.accountIdHex == aliceIdHex)
        #expect(target.npub == "npub1alyce")
        #expect(target.displayName == "Alice Inviter")
    }

    @MainActor
    @Test func acceptGroupInviteDropsOverlappingDuplicateAfterClosingDetails() async throws {
        let account = desktopAccount()
        var details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        details.group.pendingConfirmation = true
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(details)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let groupChat = try #require(state.activeChats.first)
        await state.showGroupDetails(for: groupChat)

        runtime.groupInviteGateEnabled = true
        async let firstAccept: Void = state.acceptSelectedGroupInvite()
        while !(state.isAcceptingGroupInvite && runtime.didReachGroupInviteGate) {
            await Task.yield()
        }

        state.closeGroupDetails()
        #expect(!state.isGroupDetailsPresented)

        await state.acceptGroupInvite(for: groupChat)
        await state.declineGroupInvite(for: groupChat)
        #expect(runtime.acceptGroupInviteCallCount == 1)
        #expect(runtime.declineGroupInviteCallCount == 0)

        runtime.releaseGroupInviteGate()
        await firstAccept

        #expect(runtime.acceptGroupInviteCallCount == 1)
        #expect(runtime.declineGroupInviteCallCount == 0)
        #expect(!state.isAcceptingGroupInvite)
        #expect(!state.isDecliningGroupInvite)
    }

    @MainActor
    @Test func declineGroupInviteDropsOverlappingDuplicateAfterClosingDetails() async throws {
        let account = desktopAccount()
        var details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        details.group.pendingConfirmation = true
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(details)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let groupChat = try #require(state.activeChats.first)
        await state.showGroupDetails(for: groupChat)

        runtime.groupInviteGateEnabled = true
        async let firstDecline: Void = state.declineSelectedGroupInvite()
        while !(state.isDecliningGroupInvite && runtime.didReachGroupInviteGate) {
            await Task.yield()
        }

        state.closeGroupDetails()
        #expect(!state.isGroupDetailsPresented)

        await state.declineGroupInvite(for: groupChat)
        await state.acceptGroupInvite(for: groupChat)
        #expect(runtime.declineGroupInviteCallCount == 1)
        #expect(runtime.acceptGroupInviteCallCount == 0)

        runtime.releaseGroupInviteGate()
        await firstDecline

        #expect(runtime.declineGroupInviteCallCount == 1)
        #expect(runtime.acceptGroupInviteCallCount == 0)
        #expect(!state.isDecliningGroupInvite)
        #expect(!state.isAcceptingGroupInvite)
    }

    @MainActor
    @Test func groupDetailsMemberAdminActionsUseDetailedMutations() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.showGroupDetails(for: groupChat)
        guard let member = state.groupDetailsSnapshot?.members.first(where: { !$0.isSelf }) else {
            Issue.record("Expected another member")
            return
        }

        await state.promoteGroupMember(member)
        #expect(runtime.promotedAdminRef == "npub1alyce")
        #expect(state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id })?.isAdmin == true)

        guard let promotedMember = state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id }) else {
            Issue.record("Expected promoted member")
            return
        }
        await state.demoteGroupMember(promotedMember)
        #expect(runtime.demotedAdminRef == "npub1alyce")
        #expect(state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id })?.isAdmin == false)

        guard let demotedMember = state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id }) else {
            Issue.record("Expected demoted member")
            return
        }
        await state.removeGroupMember(demotedMember)
        #expect(runtime.removedMemberRefs == ["npub1alyce"])
        #expect(state.groupDetailsSnapshot?.members.contains { $0.id == member.id } == false)
    }

    @MainActor
    @Test func groupMemberRowSelfDemoteRejectsLastAdminDespiteActionFlagDrift() async throws {
        // Issue #518: the member-row action is FFI-driven. Even if that flag drifts and exposes
        // self-demote for the last admin, the client must preserve the same guard as Step Down.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex),
            managementState: GroupManagementStateFfi(
                myAccountIdHex: account.accountIdHex,
                isSelfAdmin: true,
                isLastAdmin: true,
                canInvite: true,
                canLeave: false,
                requiresSelfDemoteBeforeLeave: true,
                memberActions: [
                    GroupMemberActionStateFfi(
                        memberIdHex: account.accountIdHex,
                        isSelf: true,
                        isAdmin: true,
                        canRemove: false,
                        canPromote: false,
                        canDemote: true
                    )
                ]
            ))
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let selfMember = try #require(state.groupDetailsSnapshot?.members.first(where: { $0.isSelf }))
        #expect(selfMember.canDemote)

        await state.demoteGroupMember(selfMember)

        #expect(runtime.selfDemoteAdminDetailedCallCount == 0)
        #expect(state.lastError == L10n.string("Make another member an admin before stepping down."))
        #expect(state.mutatingGroupMemberId == nil)
    }

    @MainActor
    @Test func groupDetailsArchiveAndLeaveRefreshChatList() async throws {
        let account = desktopAccount()
        let archiveRuntime = FakeMarmotRuntime(accounts: [account])
        archiveRuntime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let archiveState = WorkspaceState(clientFactory: { archiveRuntime })

        await archiveState.bootstrap()
        guard let archiveChat = archiveState.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await archiveState.showGroupDetails(for: archiveChat)
        await archiveState.setSelectedGroupArchived(true)

        #expect(archiveRuntime.archivedGroup == ArchivedGroup(groupIdHex: "group", archived: true))
        #expect(!archiveState.isGroupDetailsPresented)
        #expect(archiveState.activeChats.isEmpty)
        #expect(archiveState.archivedChats.count == 1)
        #expect(archiveState.archivedChats.first?.id == "group")

        let leaveRuntime = FakeMarmotRuntime(accounts: [account])
        let leaveDetails = groupDetailsFixture(selfAccountIdHex: account.accountIdHex, selfIsAdmin: false)
        leaveRuntime.installGroupDetails(
            leaveDetails,
            managementState: GroupManagementStateFfi(
                myAccountIdHex: account.accountIdHex,
                isSelfAdmin: false,
                isLastAdmin: false,
                canInvite: false,
                canLeave: true,
                requiresSelfDemoteBeforeLeave: false,
                memberActions: []
            )
        )
        let leaveState = WorkspaceState(clientFactory: { leaveRuntime })

        await leaveState.bootstrap()
        guard let leaveChat = leaveState.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await leaveState.showGroupDetails(for: leaveChat)
        // Leaving is two-phase on every surface now: resolve eligibility, then act on confirmation.
        await leaveState.prepareSelectedChatLeave()
        let leaveTarget = try #require(leaveState.chatPendingLeave)
        #expect(leaveRuntime.leaveGroupCallCount == 0)
        await leaveState.confirmChatLeave(leaveTarget)

        #expect(leaveRuntime.leftGroupIdHex == "group")
        #expect(!leaveState.isGroupDetailsPresented)
        // The row survives the leave — the core keeps the conversation with `Left` membership and
        // an uncommitted leave request — so the list must show the departure as settled and offer
        // the local delete, not park it on a "Leaving" badge it can never leave.
        let departed = try #require(leaveState.activeChats.first { $0.id == "group" })
        #expect(departed.selfMembership == .left)
        #expect(departed.leaveRequestPending)
        #expect(ChatRowStatus.status(for: departed) == .membershipEnded(.left))
        #expect(ChatDestructiveActions.action(for: departed) == .deleteLocally)
    }

    /// A workspace holding one group whose leave eligibility is exactly as specified, so a test can
    /// pin the core-side answer (`canLeave` / `requiresSelfDemoteBeforeLeave` / `isLastAdmin`)
    /// instead of inferring it from the fixture's admin set.
    @MainActor
    private func leavableChatState(
        canLeave: Bool,
        requiresSelfDemoteBeforeLeave: Bool = false,
        isLastAdmin: Bool = false,
        leaveRequestPending: Bool = false,
        selfIsAdmin: Bool = false,
        openingInspector: Bool = false,
        // Leaves this account alone in the group, so a `.lastAdmin` block has neither a successor to
        // promote nor anyone the departure would inform.
        soleMember: Bool = false,
        // Empty by default, which is also the "nobody can be promoted" case the sole-admin dead end
        // needs. Pass actions when the test is about who may take the admin role over.
        memberActions: [GroupMemberActionStateFfi] = []
    ) async throws -> WorkspaceState {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(
                selfAccountIdHex: account.accountIdHex,
                selfIsAdmin: selfIsAdmin,
                soleMember: soleMember
            ),
            managementState: GroupManagementStateFfi(
                myAccountIdHex: account.accountIdHex,
                isSelfAdmin: selfIsAdmin,
                isLastAdmin: isLastAdmin,
                canInvite: selfIsAdmin,
                canLeave: canLeave,
                requiresSelfDemoteBeforeLeave: requiresSelfDemoteBeforeLeave,
                leaveRequestPending: leaveRequestPending,
                memberActions: memberActions
            )
        )
        if openingInspector {
            return try await openInstalledGroupDetails(runtime: runtime)
        }
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        return state
    }

    @MainActor
    private func openInstalledGroupDetails(runtime: FakeMarmotRuntime) async throws -> WorkspaceState {
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let groupChat = try #require(state.activeChats.first)
        await state.showGroupDetails(for: groupChat)

        return state
    }

    @MainActor
    @Test func saveGroupProfileDropsOverlappingDuplicateInvocation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)

        state.groupProfileDraftName = "Renamed Group"
        state.groupProfileDraftDescription = "Planning room"
        runtime.groupMutationGateEnabled = true

        async let firstSave: Void = state.saveGroupProfile()
        while !(state.isSavingGroupProfile && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        await state.saveGroupProfile()
        #expect(runtime.updateGroupProfileCallCount == 1)

        runtime.releaseGroupMutationGate()
        await firstSave

        #expect(runtime.updateGroupProfileCallCount == 1)
        #expect(!state.isSavingGroupProfile)
    }

    @MainActor
    @Test func saveGroupProfileDropsWhileMemberMutationIsInFlight() async throws {
        // PR #418 review: a profile save triggers loadGroupDetails(), which must not start a
        // newer details generation while a member mutation owns the apply window for its result.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let member = try #require(state.groupDetailsSnapshot?.members.first(where: { !$0.isSelf }))

        runtime.groupMutationGateEnabled = true
        async let firstPromote: Void = state.promoteGroupMember(member)
        while !(state.mutatingGroupMemberId == member.id && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        state.groupProfileDraftName = "Renamed While Mutating"
        state.groupProfileDraftDescription = "Should be ignored until mutation finishes"
        await state.saveGroupProfile()
        #expect(runtime.updateGroupProfileCallCount == 0)
        #expect(state.isSavingGroupProfile == false)

        runtime.releaseGroupMutationGate()
        await firstPromote

        #expect(runtime.promoteAdminDetailedCallCount == 1)
        #expect(state.groupDetailsSnapshot?.members.first(where: { $0.id == member.id })?.isAdmin == true)
    }

    @MainActor
    @Test func mutateGroupMemberDropsWhileProfileSaveIsInFlight() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let member = try #require(state.groupDetailsSnapshot?.members.first(where: { !$0.isSelf }))

        state.groupProfileDraftName = "Renamed Group"
        state.groupProfileDraftDescription = "Planning room"
        runtime.groupMutationGateEnabled = true
        async let save: Void = state.saveGroupProfile()
        let reachedProfileSaveGate = await waitFor {
            state.isSavingGroupProfile && runtime.didReachGroupMutationGate
        }
        #expect(reachedProfileSaveGate)
        guard reachedProfileSaveGate else {
            runtime.releaseGroupMutationGate()
            await save
            return
        }

        #expect(state.hasInFlightGroupCommit)
        await state.promoteGroupMember(member)
        #expect(runtime.promoteAdminDetailedCallCount == 0)

        runtime.releaseGroupMutationGate()
        await save
    }

    @MainActor
    @Test func invitingMembersNamesEveryoneWithoutAKeyPackageInOneAttempt() async throws {
        // The add-members sheet had the compose draft's old bug: `invite_members` names one refused
        // member per attempt, so staging three people with no KeyPackage named the first and left
        // the user to deselect and press again to meet the next.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1carol"] = Self.carolAccountIdHex
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let staged = [Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient()]

        let invited = await state.inviteMembers(staged)

        #expect(!invited)
        #expect(
            state.unreachableInviteRecipients(staged).map(\.accountIdHex)
                == [Self.bobAccountIdHex, Self.carolAccountIdHex])
        #expect(state.reachableInviteRecipients(staged).map(\.accountIdHex) == [Self.aliceAccountIdHex])
        #expect(state.lastError == nil)
        #expect(!state.hasUnnamedInviteRefusal)
        // Bob rode along at the end of the follow-up, which keeps it failing in resolution — so
        // Carol was found without anything being committed.
        #expect(
            runtime.inviteMemberRefAttempts == [
                ["npub1alyce", "npub1p0p", "npub1carol"],
                ["npub1alyce", "npub1carol", "npub1p0p"],
            ])
        #expect(runtime.invitedMemberRefs.isEmpty)

        // The next press carries the roster the sheet has been showing all along.
        let retried = await state.inviteMembers(staged)
        #expect(retried)
        #expect(runtime.invitedMemberRefs == ["npub1alyce"])
    }

    @MainActor
    @Test func invitingMembersNamesAMemberWhoseRefusalNamesNobody() async throws {
        // A KeyPackage that exists but can't be used names no account, and the invite still stops
        // over it. Asking about each staged person with the refused one alongside settles who.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.invalidKeyPackageMemberRefs = ["npub1carol"]
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let staged = [Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient()]

        let invited = await state.inviteMembers(staged)

        #expect(!invited)
        #expect(
            state.unreachableInviteRecipients(staged).map(\.accountIdHex)
                == [Self.bobAccountIdHex, Self.carolAccountIdHex])
        #expect(state.lastError == nil)
        #expect(!state.hasUnnamedInviteRefusal)
        #expect(runtime.invitedMemberRefs.isEmpty)
    }

    @MainActor
    @Test func invitingMembersSaysSomeoneWhenTheFirstRefusalNamesNobody() async throws {
        // Nothing refused yet, so there is no known-unreachable member to ask alongside — and
        // asking about one person alone would invite them. The sheet says what it knows.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.invalidKeyPackageMemberRefs = ["npub1carol"]
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let staged = [Self.carolDraftRecipient(), Self.aliceDraftRecipient()]

        let invited = await state.inviteMembers(staged)

        #expect(!invited)
        #expect(state.hasUnnamedInviteRefusal)
        #expect(state.unreachableInviteRecipients(staged).isEmpty)
        #expect(state.lastError == nil)
        #expect(runtime.invitedMemberRefs.isEmpty)
    }

    @MainActor
    @Test func inviteMemberDropsWhileProfileSaveIsInFlight() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.installNormalizedMemberRef(
            query: "npub1newmemzer",
            accountIdHex: "new1234567890new1234567890new1234567890new1234567890new1",
            npub: "npub1newmemzer"
        )
        let state = try await openInstalledGroupDetails(runtime: runtime)

        state.groupProfileDraftName = "Renamed Group"
        state.groupProfileDraftDescription = "Planning room"
        state.groupInviteMemberQuery = "npub1newmemzer"
        runtime.groupMutationGateEnabled = true
        async let save: Void = state.saveGroupProfile()
        let reachedProfileSaveGate = await waitFor {
            state.isSavingGroupProfile && runtime.didReachGroupMutationGate
        }
        #expect(reachedProfileSaveGate)
        guard reachedProfileSaveGate else {
            runtime.releaseGroupMutationGate()
            await save
            return
        }

        await state.inviteMemberToSelectedGroup()
        #expect(runtime.inviteMembersDetailedCallCount == 0)

        runtime.releaseGroupMutationGate()
        await save
    }

    @MainActor
    @Test func inviteMemberDropsOverlappingDuplicateInvocation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.installNormalizedMemberRef(
            query: "npub1newmemzer",
            accountIdHex: "new1234567890new1234567890new1234567890new1234567890new1",
            npub: "npub1newmemzer"
        )
        let state = try await openInstalledGroupDetails(runtime: runtime)

        state.groupInviteMemberQuery = "npub1newmemzer"
        runtime.groupMutationGateEnabled = true

        async let firstInvite: Void = state.inviteMemberToSelectedGroup()
        while !(state.isInvitingGroupMember && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        await state.inviteMemberToSelectedGroup()
        #expect(runtime.inviteMembersDetailedCallCount == 1)

        runtime.releaseGroupMutationGate()
        await firstInvite

        #expect(runtime.inviteMembersDetailedCallCount == 1)
        #expect(!state.isInvitingGroupMember)
    }

    @MainActor
    @Test func inviteMemberDropsWhileMemberMutationIsInFlight() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.installNormalizedMemberRef(
            query: "npub1newmemzer",
            accountIdHex: "new1234567890new1234567890new1234567890new1234567890new1",
            npub: "npub1newmemzer"
        )
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let member = try #require(state.groupDetailsSnapshot?.members.first(where: { !$0.isSelf }))

        runtime.groupMutationGateEnabled = true
        async let firstPromote: Void = state.promoteGroupMember(member)
        while !(state.mutatingGroupMemberId == member.id && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        state.groupInviteMemberQuery = "npub1newmemzer"
        await state.inviteMemberToSelectedGroup()
        #expect(runtime.inviteMembersDetailedCallCount == 0)

        runtime.releaseGroupMutationGate()
        await firstPromote
    }

    @MainActor
    @Test func mutateGroupMemberDropsWhileInviteIsInFlight() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.installNormalizedMemberRef(
            query: "npub1newmemzer",
            accountIdHex: "new1234567890new1234567890new1234567890new1234567890new1",
            npub: "npub1newmemzer"
        )
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let member = try #require(state.groupDetailsSnapshot?.members.first(where: { !$0.isSelf }))

        state.groupInviteMemberQuery = "npub1newmemzer"
        runtime.groupMutationGateEnabled = true
        async let firstInvite: Void = state.inviteMemberToSelectedGroup()
        while !(state.isInvitingGroupMember && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        await state.promoteGroupMember(member)
        #expect(runtime.promoteAdminDetailedCallCount == 0)

        runtime.releaseGroupMutationGate()
        await firstInvite
    }

    @MainActor
    @Test func selfDemoteAdminDropsOverlappingDuplicateInvocation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(
                selfAccountIdHex: account.accountIdHex,
                otherIsAdmin: true
            ))
        let state = try await openInstalledGroupDetails(runtime: runtime)

        runtime.groupMutationGateEnabled = true
        async let firstDemote: Void = state.selfDemoteSelectedGroupAdmin()
        while !(state.mutatingGroupMemberId != nil && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        await state.selfDemoteSelectedGroupAdmin()
        #expect(runtime.selfDemoteAdminDetailedCallCount == 1)

        runtime.releaseGroupMutationGate()
        await firstDemote

        #expect(runtime.selfDemoteAdminDetailedCallCount == 1)
        #expect(state.mutatingGroupMemberId == nil)
    }

    @MainActor
    @Test func selfDemoteAdminUsesFallbackMutexWhenSelfMemberIsMissing() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        var details = groupDetailsFixture(
            selfAccountIdHex: account.accountIdHex,
            otherIsAdmin: true
        )
        details.members.removeAll(where: \.isSelf)
        runtime.installGroupDetails(
            details,
            managementState: GroupManagementStateFfi(
                myAccountIdHex: account.accountIdHex,
                isSelfAdmin: true,
                isLastAdmin: false,
                canInvite: true,
                canLeave: true,
                requiresSelfDemoteBeforeLeave: true,
                memberActions: []
            ))
        let state = try await openInstalledGroupDetails(runtime: runtime)

        runtime.groupMutationGateEnabled = true
        async let firstDemote: Void = state.selfDemoteSelectedGroupAdmin()
        for _ in 0..<100 {
            if state.mutatingGroupMemberId == account.accountIdHex && runtime.didReachGroupMutationGate {
                break
            }
            await Task.yield()
        }

        #expect(state.mutatingGroupMemberId == account.accountIdHex)
        #expect(runtime.didReachGroupMutationGate)

        await state.selfDemoteSelectedGroupAdmin()
        #expect(runtime.selfDemoteAdminDetailedCallCount == 1)

        runtime.releaseGroupMutationGate()
        await firstDemote

        #expect(runtime.selfDemoteAdminDetailedCallCount == 1)
        #expect(state.mutatingGroupMemberId == nil)
    }

    @MainActor
    @Test func archiveGroupDropsOverlappingDuplicateInvocation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)

        runtime.groupMutationGateEnabled = true
        async let firstArchive: Void = state.setSelectedGroupArchived(true)
        while !(state.isArchivingGroup && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        await state.setSelectedGroupArchived(true)
        #expect(runtime.setGroupArchivedCallCount == 1)

        runtime.releaseGroupMutationGate()
        await firstArchive

        #expect(runtime.setGroupArchivedCallCount == 1)
        #expect(!state.isArchivingGroup)
    }

    @MainActor
    @Test func groupDetailsOnlyCloseAfterArchiveCommits() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)

        runtime.setGroupArchivedError = FakeMarmotRuntimeError.unused
        await state.setSelectedGroupArchived(true)
        #expect(state.isGroupDetailsPresented)
        #expect(state.activeChats.contains { $0.id == "group" })
        #expect(state.archivedChats.isEmpty)

        runtime.setGroupArchivedError = nil
        state.archivingChatId = "another-chat"
        await state.setSelectedGroupArchived(true)
        #expect(state.isGroupDetailsPresented)
        #expect(runtime.setGroupArchivedCallCount == 1)
        #expect(!state.isArchivingGroup)
    }

    @MainActor
    @Test func setDisappearingMessagesDropsWhileMemberMutationIsInFlight() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let member = try #require(state.groupDetailsSnapshot?.members.first(where: { !$0.isSelf }))
        let groupIdHex = try #require(state.groupDetailsSnapshot?.groupIdHex)

        runtime.groupMutationGateEnabled = true
        async let firstPromote: Void = state.promoteGroupMember(member)
        let didSuspendPromote = await waitFor {
            state.mutatingGroupMemberId == member.id && runtime.didReachGroupMutationGate
        }
        guard didSuspendPromote else {
            runtime.groupMutationGateEnabled = false
            runtime.releaseGroupMutationGate()
            await firstPromote
            Issue.record("Expected member mutation to reach the test gate")
            return
        }

        await state.setDisappearingMessages(groupIdHex: groupIdHex, seconds: 86_400)
        #expect(runtime.updateMessageRetentionCallCount == 0)
        #expect(!state.isUpdatingDisappearingMessages)

        runtime.releaseGroupMutationGate()
        await firstPromote
    }

    @MainActor
    @Test func saveGroupProfileDropsWhileRetentionUpdateIsInFlight() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let groupIdHex = try #require(state.groupDetailsSnapshot?.groupIdHex)

        runtime.groupMutationGateEnabled = true
        async let firstRetention: Void = state.setDisappearingMessages(groupIdHex: groupIdHex, seconds: 86_400)
        let didSuspendRetention = await waitFor {
            state.isUpdatingDisappearingMessages && runtime.didReachGroupMutationGate
        }
        guard didSuspendRetention else {
            runtime.groupMutationGateEnabled = false
            runtime.releaseGroupMutationGate()
            await firstRetention
            Issue.record("Expected retention update to reach the test gate")
            return
        }

        state.groupProfileDraftName = "Renamed While Retaining"
        state.groupProfileDraftDescription = "Should be ignored until retention finishes"
        await state.saveGroupProfile()
        #expect(runtime.updateGroupProfileCallCount == 0)
        #expect(!state.isSavingGroupProfile)

        runtime.releaseGroupMutationGate()
        await firstRetention
    }

    /// Preparing a leave deliberately does **not** consult `hasInFlightGroupCommit`: that token is
    /// the group-details panel's own mutual exclusion, and gating on it would let an unrelated
    /// in-flight commit block leaving a different chat from the sidebar. The per-chat
    /// `leavingChatId` guard is what serializes leaves.
    @MainActor
    @Test func chatLeavePreparationSurvivesUnrelatedInFlightGroupCommit() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex, selfIsAdmin: false)
        runtime.installGroupDetails(
            details,
            managementState: GroupManagementStateFfi(
                myAccountIdHex: account.accountIdHex,
                isSelfAdmin: false,
                isLastAdmin: false,
                canInvite: false,
                canLeave: true,
                requiresSelfDemoteBeforeLeave: false,
                memberActions: []
            )
        )
        let state = try await openInstalledGroupDetails(runtime: runtime)

        state.groupProfileDraftName = "Renamed Group"
        state.groupProfileDraftDescription = "Planning room"
        runtime.groupMutationGateEnabled = true
        async let firstSave: Void = state.saveGroupProfile()
        let didSuspendSave = await waitFor {
            state.isSavingGroupProfile && runtime.didReachGroupMutationGate
        }
        guard didSuspendSave else {
            runtime.groupMutationGateEnabled = false
            runtime.releaseGroupMutationGate()
            await firstSave
            Issue.record("Expected profile save to reach the test gate")
            return
        }

        // The confirmation still opens; nothing has been published yet, because publishing waits on
        // the user's confirmation rather than on the unrelated save.
        await state.prepareSelectedChatLeave()
        #expect(state.chatPendingLeave?.groupIdHex == details.group.groupIdHex)
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(!state.isLeavingGroup)

        runtime.releaseGroupMutationGate()
        await firstSave
    }

    @MainActor
    @Test func updateSelectedGroupImageDropsWhileMemberMutationIsInFlight() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let member = try #require(state.groupDetailsSnapshot?.members.first(where: { !$0.isSelf }))
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        let result = GroupImageSearchResult(
            id: "image-1",
            title: "Aurora",
            imageURL: "https://example.com/aurora.jpg",
            thumbnailURL: "https://example.com/aurora-thumb.jpg",
            creator: "Open Photographer",
            license: "by",
            attribution: nil,
            sourceURL: "https://example.com/aurora",
            width: 1024,
            height: 680
        )

        runtime.groupMutationGateEnabled = true
        async let firstPromote: Void = state.promoteGroupMember(member)
        let didSuspendPromote = await waitFor {
            state.mutatingGroupMemberId == member.id && runtime.didReachGroupMutationGate
        }
        guard didSuspendPromote else {
            runtime.groupMutationGateEnabled = false
            runtime.releaseGroupMutationGate()
            await firstPromote
            Issue.record("Expected member mutation to reach the test gate")
            return
        }

        state.showGroupImagePicker(for: groupChat)
        await state.setGroupImage(result)
        #expect(runtime.updateGroupAvatarUrlCallCount == 0)
        #expect(!state.isSavingGroupImage)

        runtime.releaseGroupMutationGate()
        await firstPromote
    }

    @MainActor
    @Test func leaveGroupDropsOverlappingDuplicateInvocation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex, selfIsAdmin: false)
        runtime.installGroupDetails(
            details,
            managementState: GroupManagementStateFfi(
                myAccountIdHex: account.accountIdHex,
                isSelfAdmin: false,
                isLastAdmin: false,
                canInvite: false,
                canLeave: true,
                requiresSelfDemoteBeforeLeave: false,
                memberActions: []
            )
        )
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let target = ChatLeaveTarget(
            groupIdHex: details.group.groupIdHex,
            subject: .namedGroup(details.group.name),
            requiresSelfDemote: false
        )

        runtime.groupMutationGateEnabled = true
        async let firstLeave: Void = state.confirmChatLeave(target)
        while !(state.leavingChatId == target.groupIdHex && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        await state.confirmChatLeave(target)
        #expect(runtime.leaveGroupCallCount == 1)

        runtime.releaseGroupMutationGate()
        await firstLeave

        #expect(runtime.leaveGroupCallCount == 1)
        #expect(state.leavingChatId == nil)
        #expect(!state.isLeavingGroup)
    }

    // MARK: - Chat-list leave / local delete

    /// Preparing a leave resolves eligibility and opens the confirmation — it must not publish
    /// anything, or a context-menu click would leave the chat without asking.
    @MainActor
    @Test func chatListLeavePreparationOnlyOpensTheConfirmation() async throws {
        let state = try await leavableChatState(canLeave: true)
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)

        await state.prepareChatLeave(for: chat)

        #expect(state.chatPendingLeave?.groupIdHex == chat.id)
        #expect(state.chatPendingLeave?.requiresSelfDemote == false)
        #expect(state.chatActionAlert == nil)
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(runtime.selfDemoteAdminDetailedCallCount == 0)
    }

    /// The two surfaces must resolve to the same thing. The sidebar row and the inspector reach the
    /// same shared entry point, so the same group produces the same pending confirmation.
    @MainActor
    @Test func chatListAndInspectorLeavePreparationAgree() async throws {
        let rowState = try await leavableChatState(canLeave: true)
        let rowChat = try #require(rowState.activeChats.first)
        await rowState.prepareChatLeave(for: rowChat)

        let inspectorState = try await leavableChatState(canLeave: true, openingInspector: true)
        await inspectorState.prepareSelectedChatLeave()

        #expect(rowState.chatPendingLeave?.groupIdHex == inspectorState.chatPendingLeave?.groupIdHex)
        #expect(
            rowState.chatPendingLeave?.requiresSelfDemote
                == inspectorState.chatPendingLeave?.requiresSelfDemote
        )
    }

    /// Two quick clicks must not race: whichever eligibility fetch finishes last would otherwise own
    /// the confirmation, so the dialog could name a chat the user did not click.
    ///
    /// `preparingChatLeaveId` is the guard under test, and pinning it takes two things the obvious
    /// version of this test does not have. The second row must be a *real* installed group whose
    /// eligibility resolves to a leave — an unknown id could only ever fail, so the confirmation
    /// would stay put no matter what the guard did. And the overlap has to be arranged rather than
    /// hoped for: the fake returns installed management state without suspending, so two
    /// `async let` preparations on the main actor would simply run one after the other, and the
    /// already-open `chatPendingLeave` would be what turned the second one away. Parking the first
    /// fetch at the gate is what makes `preparingChatLeaveId` the only thing standing in the way.
    @MainActor
    @Test func overlappingLeavePreparationsCannotRetargetTheConfirmation() async throws {
        let account = desktopAccount()
        let state = try await leavableChatState(canLeave: true)
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)

        var secondGroup = messageGroup()
        secondGroup.groupIdHex = "second-group"
        secondGroup.name = "Second Group"
        runtime.installGroupDetailsRecord(
            GroupDetailsFfi(group: secondGroup, members: []),
            managementState: GroupManagementStateFfi(
                myAccountIdHex: account.accountIdHex,
                isSelfAdmin: false,
                isLastAdmin: false,
                canInvite: false,
                canLeave: true,
                requiresSelfDemoteBeforeLeave: false,
                leaveRequestPending: false,
                memberActions: []
            )
        )

        runtime.groupManagementStateGateEnabled = true
        async let first: Void = state.prepareChatLeave(
            groupIdHex: chat.id,
            subject: .namedGroup("First")
        )
        while !(state.preparingChatLeaveId == chat.id && runtime.didReachGroupManagementStateGate) {
            await Task.yield()
        }

        // The second click lands while the first eligibility fetch is still parked.
        await state.prepareChatLeave(
            groupIdHex: secondGroup.groupIdHex,
            subject: .namedGroup("Second")
        )
        #expect(state.preparingChatLeaveId == chat.id)
        #expect(state.chatPendingLeave == nil)
        #expect(state.chatActionAlert == nil)

        runtime.releaseGroupManagementStateGate()
        await first

        #expect(state.chatPendingLeave?.groupIdHex == chat.id)
        #expect(state.chatPendingLeave?.subject == .namedGroup("First"))
        #expect(state.preparingChatLeaveId == nil)
    }

    /// The core makes the creator of a chat its sole admin and MIP-03 forbids the self-removal that
    /// would empty the admin set, so leaving is blocked until another member is promoted. The report
    /// says exactly that and offers no local delete: dropping the local copy while the group still
    /// counts this account as a member would strand every message they send afterwards.
    ///
    /// This is now the *narrow* dead end, and the fixture roster is what keeps it here: Alice and Bob
    /// are still in the group, so somebody would be stranded. Empty that roster and the same
    /// eligibility resolves to a local delete instead — see
    /// `lastMemberBlockedAsLastAdminIsOfferedTheLocalDeleteInsteadOfADeadEnd`.
    @MainActor
    @Test func lastAdminLeaveIsReportedWithoutOfferingALocalDelete() async throws {
        let state = try await leavableChatState(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            isLastAdmin: true,
            selfIsAdmin: true
        )
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)

        await state.prepareChatLeave(for: chat)

        #expect(state.chatPendingLeave == nil)
        #expect(state.chatPendingLocalDelete == nil)
        // No `memberActions`, so the core has named nobody this account may promote: the successor
        // picker would be an empty list, and the honest answer is the blocker.
        #expect(state.chatPendingAdminHandoff == nil)
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(runtime.selfDemoteAdminDetailedCallCount == 0)
        #expect(runtime.promoteAdminDetailedCallCount == 0)
        #expect(runtime.locallyDeletedGroupIds.isEmpty)
        let alert = try #require(state.chatActionAlert)
        #expect(alert.message == ChatDestructiveActions.LeaveBlocker.lastAdmin.message)
        // The chat is still listed and still a member's chat — nothing was silently dropped.
        #expect(state.activeChats.contains { $0.id == chat.id })
        #expect(ChatDestructiveActions.action(for: chat) == .leave)
    }

    /// The sole admin of a group with someone who *can* take over gets the successor picker rather
    /// than the dead end — and gets it before anything is committed, so cancelling costs nothing.
    @MainActor
    @Test func soleAdminLeaveOffersASuccessorPickerRatherThanADeadEnd() async throws {
        let state = try await soleAdminWithSuccessorState()
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)

        await state.prepareChatLeave(for: chat)

        let handoff = try #require(state.chatPendingAdminHandoff)
        #expect(handoff.groupIdHex == chat.id)
        #expect(handoff.subject == chat.confirmationSubject)
        // Alice only: Bob carries no action state, so the core has not said he may be promoted.
        #expect(handoff.candidates.map(\.npub) == ["npub1alyce"])
        // And because she is the only one, the picker opens with her already chosen — the sheet is a
        // confirmation at that point, not a question with one available answer.
        #expect(handoff.preselectedSuccessorId == handoff.candidates.first?.id)
        // A question, not a commit: nothing about the group has changed, and no blocker was reported.
        #expect(state.chatActionAlert == nil)
        #expect(state.chatPendingLeave == nil)
        #expect(runtime.promoteAdminDetailedCallCount == 0)
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(runtime.selfDemoteAdminDetailedCallCount == 0)
        #expect(state.activeChats.contains { $0.id == chat.id })
    }

    /// The other side of the preselection: as soon as the core names more than one member this
    /// account may promote, the choice is real and belongs to the user. Preselecting one of them
    /// would let a return-press hand the admin role to whoever the roster happens to list first.
    @MainActor
    @Test func successorPickerWithMoreThanOneCandidateOpensWithNobodyChosen() async throws {
        let state = try await leavableChatState(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            isLastAdmin: true,
            selfIsAdmin: true,
            memberActions: [
                GroupMemberActionStateFfi(
                    memberIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
                    isSelf: false,
                    isAdmin: false,
                    canRemove: true,
                    canPromote: true,
                    canDemote: false
                ),
                GroupMemberActionStateFfi(
                    memberIdHex: "bob1234567890bob1234567890bob1234567890bob1234567890bob1",
                    isSelf: false,
                    isAdmin: false,
                    canRemove: true,
                    canPromote: true,
                    canDemote: false
                ),
            ]
        )
        let chat = try #require(state.activeChats.first)

        await state.prepareChatLeave(for: chat)

        let handoff = try #require(state.chatPendingAdminHandoff)
        #expect(handoff.candidates.map(\.npub) == ["npub1alyce", "npub1p0p"])
        #expect(handoff.preselectedSuccessorId == nil)
    }

    /// The point of the whole flow: one confirmation promotes the successor, steps this account down,
    /// and removes it — in that order, because MIP-03 rejects any other.
    @MainActor
    @Test func confirmedHandoffPromotesTheSuccessorThenLeaves() async throws {
        let state = try await soleAdminWithSuccessorState()
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)

        await state.prepareChatLeave(for: chat)
        let handoff = try #require(state.chatPendingAdminHandoff)
        let successor = try #require(handoff.candidates.first)

        await state.confirmChatAdminHandoff(handoff, successor: successor)

        #expect(runtime.promotedAdminRef == "npub1alyce")
        #expect(runtime.groupMutationOrder == ["promote", "selfDemote", "leave"])
        #expect(runtime.leftGroupIdHex == chat.id)
        #expect(state.chatActionAlert == nil)
        // Every marker released, so neither the picker nor the leave can be re-offered as in flight.
        #expect(state.chatPendingAdminHandoff == nil)
        #expect(state.handingOffAdminChatId == nil)
        #expect(state.leavingChatId == nil)
        #expect(!state.hasInFlightGroupCommit)
    }

    /// A promotion that fails must leave the account exactly where it was — still admin, still a
    /// member — and say so as its own failure. Reporting it as a failed *leave* would be a lie, and
    /// carrying on to the removal would be the self-removal MIP-03 forbids.
    @MainActor
    @Test func failedHandoffNeverAttemptsTheLeaveItWouldHaveUnblocked() async throws {
        let state = try await soleAdminWithSuccessorState()
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)
        runtime.promoteAdminError = FakeMarmotRuntimeError.unused

        await state.prepareChatLeave(for: chat)
        let handoff = try #require(state.chatPendingAdminHandoff)

        await state.confirmChatAdminHandoff(handoff, successor: try #require(handoff.candidates.first))

        #expect(runtime.selfDemoteAdminDetailedCallCount == 0)
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(runtime.groupMutationOrder.isEmpty)
        #expect(state.chatActionAlert == ChatActionAlert.adminHandoffFailed())
        #expect(state.chatPendingAdminHandoff == nil)
        #expect(state.handingOffAdminChatId == nil)
        #expect(state.activeChats.contains { $0.id == chat.id })
    }

    /// The re-entrancy guard. `confirmChatAdminHandoff` finishes through `confirmChatLeave`, which
    /// re-reads eligibility; a core that still calls this account the last admin after the promotion
    /// committed must produce a report, not the picker the user just used — which would reopen
    /// forever.
    @MainActor
    @Test func handoffWhoseLeaveStillReportsSoleAdminDoesNotReopenThePicker() async throws {
        let state = try await soleAdminWithSuccessorState()
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)
        runtime.keepsManagementStateAfterPromote = true

        await state.prepareChatLeave(for: chat)
        let handoff = try #require(state.chatPendingAdminHandoff)

        await state.confirmChatAdminHandoff(handoff, successor: try #require(handoff.candidates.first))

        #expect(runtime.promoteAdminDetailedCallCount == 1)
        #expect(runtime.selfDemoteAdminDetailedCallCount == 0)
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(state.chatPendingAdminHandoff == nil)
        #expect(state.chatActionAlert?.message == ChatDestructiveActions.LeaveBlocker.lastAdmin.message)
        #expect(state.handingOffAdminChatId == nil)
    }

    /// A handoff claims `leavingChatId` only once its promotion commits, so between the confirmation
    /// and that commit the leave is in progress with none of the usual markers set. A second attempt
    /// in that window must be ignored: it would otherwise resolve eligibility, still find the
    /// sole-admin block, and report a blocker for a leave that is about to succeed.
    @MainActor
    @Test func leaveIsNotRePreparedWhileTheHandoffPromotionIsStillInFlight() async throws {
        let state = try await soleAdminWithSuccessorState()
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)

        await state.prepareChatLeave(for: chat)
        let handoff = try #require(state.chatPendingAdminHandoff)
        let successor = try #require(handoff.candidates.first)

        runtime.groupMutationGateEnabled = true
        async let handoffRun: Void = state.confirmChatAdminHandoff(handoff, successor: successor)
        while !(state.handingOffAdminChatId == chat.id && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        await state.prepareChatLeave(for: chat)
        #expect(state.chatActionAlert == nil)
        #expect(state.chatPendingLeave == nil)
        #expect(state.chatPendingAdminHandoff == nil)

        runtime.releaseGroupMutationGate()
        await handoffRun

        // The one handoff still completes, and exactly once.
        #expect(runtime.promoteAdminDetailedCallCount == 1)
        #expect(runtime.groupMutationOrder == ["promote", "selfDemote", "leave"])
        #expect(state.chatActionAlert == nil)
    }

    /// The last one out of a DM or group: alone, and refused the leave for being the last admin.
    ///
    /// Before this existed the row menu's Leave landed on an alert telling the user to invite
    /// someone before leaving — advice with nobody to follow it about, and no way out of the chat.
    /// The leave genuinely cannot happen, so the local delete takes its place: with no one else in
    /// the group there is nobody the departure would have informed and nobody left to strand.
    @MainActor
    @Test func lastMemberBlockedAsLastAdminIsOfferedTheLocalDeleteInsteadOfADeadEnd() async throws {
        let state = try await leavableChatState(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            isLastAdmin: true,
            selfIsAdmin: true,
            soleMember: true
        )
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)

        await state.prepareChatLeave(for: chat)

        // No dead-end alert, and no successor picker with nobody to put in it.
        #expect(state.chatActionAlert == nil)
        #expect(state.chatPendingAdminHandoff == nil)
        #expect(state.chatPendingLeave == nil)
        let target = try #require(state.chatPendingLocalDelete)
        #expect(target.groupIdHex == chat.id)
        #expect(target.subject == chat.confirmationSubject)

        // Nothing was sent on the user's behalf while resolving the block.
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(runtime.selfDemoteAdminDetailedCallCount == 0)
        #expect(runtime.promoteAdminDetailedCallCount == 0)

        await state.confirmChatLocalDelete(target)
        #expect(runtime.locallyDeletedGroupIds == [chat.id])
        #expect(state.chatActionAlert == nil)
    }

    /// The inspector holds the roster up front, so it must not offer a Leave whose only outcome is an
    /// explanation — it offers the delete directly, with a footer saying why.
    @MainActor
    @Test func inspectorOffersTheLocalDeleteToTheLastMemberOfAChatItCannotLeave() async throws {
        let state = try await leavableChatState(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            isLastAdmin: true,
            selfIsAdmin: true,
            openingInspector: true,
            soleMember: true
        )
        let snapshot = try #require(state.groupDetailsSnapshot)

        #expect(snapshot.members.count == 1)
        #expect(snapshot.leaveBlocker == .lastAdmin)
        #expect(snapshot.lastAdminResolution == .deleteLocally)
        #expect(snapshot.destructiveAction == .deleteLocally)
        #expect(snapshot.leaveGuidance == .localDeleteInstead)
    }

    /// The sole admin of a fixture group in which Alice — and only Alice — may be promoted.
    @MainActor
    private func soleAdminWithSuccessorState() async throws -> WorkspaceState {
        try await leavableChatState(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            isLastAdmin: true,
            selfIsAdmin: true,
            memberActions: [
                GroupMemberActionStateFfi(
                    memberIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
                    isSelf: false,
                    isAdmin: false,
                    canRemove: true,
                    canPromote: true,
                    canDemote: false
                )
            ]
        )
    }

    @MainActor
    @Test func nonLastAdminLeaveStepsDownBeforeLeaving() async throws {
        let state = try await leavableChatState(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            isLastAdmin: false,
            selfIsAdmin: true
        )
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)

        await state.prepareChatLeave(for: chat)
        let target = try #require(state.chatPendingLeave)
        #expect(target.requiresSelfDemote)
        await state.confirmChatLeave(target)

        #expect(runtime.selfDemoteAdminDetailedCallCount == 1)
        #expect(runtime.leaveGroupCallCount == 1)
        #expect(runtime.groupMutationOrder == ["selfDemote", "leave"])
        #expect(state.leavingChatId == nil)
    }

    @MainActor
    @Test func ordinaryMemberLeaveDoesNotSelfDemote() async throws {
        let state = try await leavableChatState(canLeave: true)
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)

        await state.prepareChatLeave(for: chat)
        await state.confirmChatLeave(try #require(state.chatPendingLeave))

        #expect(runtime.selfDemoteAdminDetailedCallCount == 0)
        #expect(runtime.groupMutationOrder == ["leave"])
        #expect(runtime.leftGroupIdHex == chat.id)
        #expect(state.chatActionAlert == nil)
    }

    /// A leave the core already recorded is a success. Re-requesting inside the same epoch raises
    /// `LeaveAlreadyRequested`, and surfacing that as a failure would tell the user the leave did
    /// not happen when in fact it did.
    @MainActor
    @Test func alreadyRequestedLeaveIsTreatedAsSuccess() async throws {
        let state = try await leavableChatState(canLeave: true)
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)
        runtime.leaveGroupError = MarmotKitError.LeaveAlreadyRequested(groupIdHex: chat.id)

        await state.prepareChatLeave(for: chat)
        await state.confirmChatLeave(try #require(state.chatPendingLeave))

        #expect(runtime.leaveGroupCallCount == 1)
        #expect(state.chatActionAlert == nil)
        #expect(state.leavingChatId == nil)
    }

    @MainActor
    @Test func genuineLeaveFailureIsReportedInTheChatActionAlert() async throws {
        let state = try await leavableChatState(canLeave: true)
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.activeChats.first)
        runtime.leaveGroupError = FakeMarmotRuntimeError.unused

        await state.prepareChatLeave(for: chat)
        await state.confirmChatLeave(try #require(state.chatPendingLeave))

        #expect(runtime.leaveGroupCallCount == 1)
        #expect(state.chatActionAlert?.title == L10n.string("Couldn't leave chat"))
        #expect(state.chatPendingLocalDelete == nil)
        #expect(state.leavingChatId == nil)
    }

    /// Deleting the chat you are looking at has to tear the conversation down too. The primitive
    /// already does this; this asserts the confirmation path still routes through it.
    @MainActor
    @Test func confirmedLocalDeleteOfSelectedChatClearsTheConversation() async throws {
        let state = try await leavableChatState(canLeave: true)
        let runtime = try #require(state.client as? FakeMarmotRuntime)
        let chat = try #require(state.selectedChat)

        state.requestChatLocalDelete(for: chat)
        let target = try #require(state.chatPendingLocalDelete)
        await state.confirmChatLocalDelete(target)

        #expect(runtime.locallyDeletedGroupIds == [chat.id])
        #expect(state.chatPendingLocalDelete == nil)
        #expect(state.selection != .chat(chat.id))
        #expect(state.chatActionAlert == nil)
    }

    /// Group ids only mean something within the account that produced them, so a confirmation must
    /// never outlive the account switch — otherwise confirming would act on a different identity's
    /// chat, or on nothing at all.
    @MainActor
    @Test func accountSwitchDiscardsPendingDestructiveConfirmations() async throws {
        let second = AccountSummaryFfi(
            label: "Second Account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount(), second])
        runtime.installGroups([messageGroup()])
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        UserDefaults.standard.set("Desktop Account", forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let chat = try #require(state.activeChats.first)

        state.requestChatLocalDelete(for: chat)
        state.chatPendingLeave = ChatLeaveTarget(
            groupIdHex: chat.id,
            subject: chat.confirmationSubject,
            requiresSelfDemote: false
        )
        state.chatActionAlert = .leaveFailed()
        #expect(state.chatPendingLocalDelete != nil)

        let target = try #require(state.accounts.first { $0.id == "Second Account" })
        state.switchActiveAccount(target, finalSelection: nil)

        #expect(state.chatPendingLeave == nil)
        #expect(state.chatPendingLocalDelete == nil)
        #expect(state.chatActionAlert == nil)
    }

    /// Signing out the last account reaches onboarding without going through
    /// `prepareForActiveAccountSwitch`, so the switch-time clear does not run — the teardown itself
    /// has to drop the dialogs, or one survives into onboarding still naming the old account's group.
    @MainActor
    @Test func signingOutTheLastAccountDiscardsPendingDestructiveConfirmations() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.installGroups([messageGroup()])
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        UserDefaults.standard.set("Desktop Account", forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let chat = try #require(state.activeChats.first)
        let account = try #require(state.accounts.first)

        state.requestChatLocalDelete(for: chat)
        state.chatPendingLeave = ChatLeaveTarget(
            groupIdHex: chat.id,
            subject: chat.confirmationSubject,
            requiresSelfDemote: false
        )
        state.chatActionAlert = .leaveFailed()

        await state.signOutAccount(account)

        #expect(state.chatPendingLeave == nil)
        #expect(state.chatPendingLocalDelete == nil)
        #expect(state.chatActionAlert == nil)
    }

    @MainActor
    @Test func mutateGroupMemberDropsOverlappingDuplicateInvocation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let member = try #require(state.groupDetailsSnapshot?.members.first(where: { !$0.isSelf }))

        runtime.groupMutationGateEnabled = true
        async let firstPromote: Void = state.promoteGroupMember(member)
        while !(state.mutatingGroupMemberId == member.id && runtime.didReachGroupMutationGate) {
            await Task.yield()
        }

        await state.promoteGroupMember(member)
        #expect(runtime.promoteAdminDetailedCallCount == 1)

        runtime.releaseGroupMutationGate()
        await firstPromote

        #expect(runtime.promoteAdminDetailedCallCount == 1)
        #expect(state.mutatingGroupMemberId == nil)
    }

    @MainActor
    @Test func secureDeleteExpiredMessagesDropsOverlappingDuplicateInvocation() async throws {
        // Issue #216: secure-delete is destructive, so overlapping invocations must be dropped
        // before they issue duplicate FFI calls.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        runtime.secureDeleteExpiredGateEnabled = true
        async let firstDelete: Void = state.secureDeleteExpiredMessages(groupIdHex: "group")
        while !(state.isSecureDeletingExpired && runtime.didReachSecureDeleteExpiredGate) {
            await Task.yield()
        }

        // The overlapping call should return at the WorkspaceState guard before suspending
        // in the fake FFI gate, so the runtime invocation count must stay unchanged.
        await state.secureDeleteExpiredMessages(groupIdHex: "group")
        #expect(runtime.secureDeleteExpiredCallCount == 1)

        runtime.releaseSecureDeleteExpiredGate()
        await firstDelete

        #expect(runtime.secureDeleteExpiredCallCount == 1)
        #expect(!state.isSecureDeletingExpired)
    }

    @MainActor
    @Test func groupDetailsSelfDemoteUsesDetailedMutation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(
                selfAccountIdHex: account.accountIdHex,
                otherIsAdmin: true
            ))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.showGroupDetails(for: groupChat)
        #expect(state.groupDetailsSnapshot?.isSelfAdmin == true)
        #expect(state.groupDetailsSnapshot?.isLastAdmin == false)

        await state.selfDemoteSelectedGroupAdmin()

        #expect(runtime.selfDemotedGroupIdHex == "group")
        #expect(state.groupDetailsSnapshot?.isSelfAdmin == false)
        #expect(state.groupDetailsSnapshot?.members.first(where: \.isSelf)?.isAdmin == false)
    }

    @MainActor
    @Test func groupDetailsTranscriptExportWritesPagedTimelineJSONOffMain() async throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.installMessages(
            (0..<205).map { index in
                appMessage(
                    id: String(format: "%064x", index + 1),
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "message \(index)",
                    kind: 9,
                    recordedAt: UInt64(index + 1)
                )
            },
            groupIdHex: "group"
        )

        var copiedText: String?
        var suggestedFilename: String?
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let state = WorkspaceState(
            copyTextHandler: { text, _ in copiedText = text },
            transcriptExportDestinationPicker: { filename in
                suggestedFilename = filename
                return files.destination
            },
            nowProvider: { exportedAt },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        runtime.clearTimelineMessageQueries()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.showGroupDetails(for: groupChat)
        runtime.clearSyncCallThreadRecords()
        state.startExportSelectedGroupTranscript()
        let exportTask = try #require(state.groupTranscriptExportTask)
        await exportTask.value

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: files.destination)) as? [String: Any]
        )
        let events = try #require(json["events"] as? [[String: Any]])
        #expect(json["group_id_hex"] as? String == "group")
        #expect(json["group_name"] as? String == "Test Group")
        #expect(json["event_count"] as? Int == 205)
        #expect(events.first?["content"] as? String == "message 0")
        #expect(events.last?["content"] as? String == "message 204")
        #expect(runtime.timelineMessageQueries.count >= 2)
        #expect(runtime.timelineMessageQueries.first?.limit == ConversationTranscriptExport.pageLimit)
        #expect(runtime.timelineMessageQueries.dropFirst().first?.before != nil)
        #expect(runtime.syncCallThreadRecord("timelineMessages").allSatisfy { !$0 })
        #expect(suggestedFilename == "White Noise Transcript 2023-11-14T22-13-20Z.json")
        #expect(copiedText == nil)
        #expect(
            state.groupTranscriptExportStatus
                == "Exported 205 transcript events to \(files.destination.path)."
        )
    }

    @MainActor
    @Test func groupDetailsTranscriptExportCancelsTrackedTaskBeforeNextPage() async throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))

        let firstId = String(repeating: "1", count: 64)
        let firstPageGate = BlockingFfiGate()
        firstPageGate.isEnabled = true
        runtime.timelineMessagesHandler = { query in
            if query.before == nil {
                firstPageGate.passIfArmed()
                return TimelinePageFfi(
                    messages: [
                        timelineMessage(
                            id: firstId,
                            groupIdHex: "group",
                            sender: account.accountIdHex,
                            plaintext: "newest",
                            recordedAt: 10
                        )
                    ],
                    hasMoreBefore: true,
                    hasMoreAfter: false
                )
            }
            return TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
        }

        let state = WorkspaceState(
            transcriptExportDestinationPicker: { _ in files.destination },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        runtime.clearTimelineMessageQueries()
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected a group chat")
            return
        }

        await state.showGroupDetails(for: groupChat)
        state.startExportSelectedGroupTranscript()
        let exportTask = try #require(state.groupTranscriptExportTask)
        let deadline = Date().addingTimeInterval(2)
        while !firstPageGate.didReach && Date() < deadline {
            await Task.yield()
        }
        if !firstPageGate.didReach {
            firstPageGate.isEnabled = false
        }
        #expect(firstPageGate.didReach)

        state.closeGroupDetails()
        firstPageGate.release()
        await exportTask.value

        #expect(runtime.timelineMessageQueries.count == 1)
        #expect(!FileManager.default.fileExists(atPath: files.destination.path))
        #expect(state.lastError == nil)
        #expect(!state.isExportingGroupTranscript)
        #expect(state.groupTranscriptExportTask == nil)
    }

    @MainActor
    @Test func groupDetailsTranscriptExportReportsSuccessAfterSameGroupRefresh() async throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))

        let exportGate = BlockingFfiGate()
        exportGate.isEnabled = true
        defer { exportGate.release() }
        runtime.timelineMessagesHandler = { _ in
            exportGate.passIfArmed()
            return TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: String(repeating: "1", count: 64),
                        groupIdHex: "group",
                        sender: account.accountIdHex,
                        plaintext: "message",
                        recordedAt: 10
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        let state = WorkspaceState(
            transcriptExportDestinationPicker: { _ in files.destination },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        let groupChat = try #require(state.activeChats.first)
        await state.showGroupDetails(for: groupChat)
        let initialDetailsGeneration = state.groupDetailsLoadGeneration
        state.startExportSelectedGroupTranscript()
        let exportTask = try #require(state.groupTranscriptExportTask)
        let deadline = Date().addingTimeInterval(2)
        while !exportGate.didReach && Date() < deadline {
            await Task.yield()
        }
        if !exportGate.didReach {
            exportGate.isEnabled = false
        }
        #expect(exportGate.didReach)

        await state.reloadSelectedGroupDetails()
        #expect(state.groupDetailsLoadGeneration > initialDetailsGeneration)
        #expect(state.groupDetailsSnapshot?.groupIdHex == "group")

        exportGate.release()
        await exportTask.value

        #expect(FileManager.default.fileExists(atPath: files.destination.path))
        #expect(
            state.groupTranscriptExportStatus
                == "Exported 1 transcript event to \(files.destination.path)."
        )
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func groupDetailsTranscriptExportSuppressesLateErrorAfterTeardown() async throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))

        let exportGate = BlockingFfiGate()
        exportGate.isEnabled = true
        defer { exportGate.release() }
        runtime.timelineMessagesHandler = { _ in
            exportGate.passIfArmed()
            throw FakeMarmotRuntimeError.unused
        }

        let state = WorkspaceState(
            transcriptExportDestinationPicker: { _ in files.destination },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        let groupChat = try #require(state.activeChats.first)
        await state.showGroupDetails(for: groupChat)
        state.startExportSelectedGroupTranscript()
        let exportTask = try #require(state.groupTranscriptExportTask)
        let deadline = Date().addingTimeInterval(2)
        while !exportGate.didReach && Date() < deadline {
            await Task.yield()
        }
        if !exportGate.didReach {
            exportGate.isEnabled = false
        }
        #expect(exportGate.didReach)

        state.closeGroupDetails()
        exportGate.release()
        await exportTask.value

        #expect(state.lastError == nil)
        #expect(!FileManager.default.fileExists(atPath: files.destination.path))
        #expect(!state.isExportingGroupTranscript)
        #expect(state.groupTranscriptExportTask == nil)
    }

    @MainActor
    @Test func marmotDeepLinkDoesNotCancelInProgressTranscriptExport() async throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))

        let firstPageGate = BlockingFfiGate()
        firstPageGate.isEnabled = true
        runtime.timelineMessagesHandler = { _ in
            firstPageGate.passIfArmed()
            return TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: String(repeating: "1", count: 64),
                        groupIdHex: "group",
                        sender: account.accountIdHex,
                        plaintext: "message",
                        recordedAt: 10
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        let state = WorkspaceState(
            transcriptExportDestinationPicker: { _ in files.destination },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        let groupChat = try #require(state.activeChats.first)
        await state.showGroupDetails(for: groupChat)
        state.startExportSelectedGroupTranscript()
        let exportTask = try #require(state.groupTranscriptExportTask)
        let deadline = Date().addingTimeInterval(2)
        while !firstPageGate.didReach && Date() < deadline {
            await Task.yield()
        }
        if !firstPageGate.didReach {
            firstPageGate.isEnabled = false
        }
        #expect(firstPageGate.didReach)

        let blockedStatus = "Finish exporting the current transcript before opening this link."
        state.handleDeepLinkURL(URL(string: "marmot://profile/npub1p0p")!)
        let deepLinkHandled = await waitFor {
            state.backgroundStatus == blockedStatus || state.isNewChatComposerVisible
        }

        #expect(deepLinkHandled)
        #expect(state.backgroundStatus == blockedStatus)
        #expect(!state.isNewChatComposerVisible)
        #expect(state.isGroupDetailsPresented)
        #expect(state.isExportingGroupTranscript)
        #expect(state.groupTranscriptExportTask != nil)

        firstPageGate.release()
        await exportTask.value

        #expect(FileManager.default.fileExists(atPath: files.destination.path))
        #expect(
            state.groupTranscriptExportStatus
                == "Exported 1 transcript event to \(files.destination.path)."
        )
        #expect(state.groupTranscriptExportTask == nil)
    }

    @MainActor
    @Test func startingNewChatCreatesAndSelectsConversation() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1alyce"
        state.newChatName = "Project Room"
        state.newChatDescription = "planning space"
        await state.createNewChat()

        #expect(runtime.createdGroupMemberRefs == ["npub1alyce"])
        #expect(runtime.createdGroupName == "Project Room")
        #expect(runtime.createdGroupDescription == "planning space")
        #expect(state.selection == .chat("created-group"))
        #expect(!state.isNewChatComposerVisible)
        #expect(state.activeChats.map(\.id) == ["created-group"])
    }

    @MainActor
    @Test func groupDraftNamesTheMemberWithoutAKeyPackageInsteadOfShowingTheCoreError() async throws {
        // The core stops at the first member it can't resolve and throws `MissingKeyPackage`,
        // whose `errorDescription` is `String(reflecting:)`. Letting that reach `lastError`
        // printed a Swift enum dump at the user and never said who was at fault.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [Self.aliceDraftRecipient(), Self.bobDraftRecipient()]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()

        #expect(state.lastError == nil)
        #expect(state.unreachableDraftMembers.map(\.accountIdHex) == [Self.bobAccountIdHex])
        #expect(state.reachableDraftMembers.map(\.accountIdHex) == [Self.aliceAccountIdHex])
        // Nothing was created, and the draft is still on screen for a second, informed attempt.
        #expect(runtime.createdGroupMemberRefs.isEmpty)
        #expect(state.isNewChatComposerVisible)
        // The refusal named the last member of the roster, so everyone else had already resolved
        // and there was nothing left to check: one refusal still costs exactly one attempt.
        #expect(runtime.createGroupAttempts == [["npub1alyce", "npub1p0p"]])
    }

    @MainActor
    @Test func groupDraftNamesEveryMemberWithoutAKeyPackageInOneAttempt() async throws {
        // The core reports only the *first* member it can't resolve, so a draft with two of them
        // used to reveal one per press — the panel claimed a complete answer while naming half of
        // it. One press now chases every refusal down before anything is created.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1carol"] = Self.carolAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [
            Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient(),
        ]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()

        #expect(state.lastError == nil)
        #expect(
            state.unreachableDraftMembers.map(\.accountIdHex)
                == [Self.bobAccountIdHex, Self.carolAccountIdHex])
        #expect(state.reachableDraftMembers.map(\.accountIdHex) == [Self.aliceAccountIdHex])
        // Bob was refused first; the follow-up carries him at the end, which keeps it failing —
        // so Carol's refusal is learned without any attempt being able to create the group.
        #expect(
            runtime.createGroupAttempts == [
                ["npub1alyce", "npub1p0p", "npub1carol"],
                ["npub1alyce", "npub1carol", "npub1p0p"],
            ])
        #expect(runtime.createdGroupMemberRefs.isEmpty)
        #expect(state.selection == nil)
        #expect(state.isNewChatComposerVisible)
    }

    @MainActor
    @Test func groupDraftNamesAMemberWhoseRefusalNamesNobody() async throws {
        // Four picked, three unreachable, and the middle one refused over a KeyPackage that exists
        // but can't be used — a refusal that names no account. That one used to land on the red
        // error line while the notice above it counted the two the core *had* named, so the panel
        // stated two different things about one draft. It is now asked about member by member.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.invalidKeyPackageMemberRefs = ["npub1carol"]
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1dave"] = Self.daveAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [
            Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient(),
            Self.daveDraftRecipient(),
        ]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()

        #expect(
            state.unreachableDraftMembers.map(\.accountIdHex)
                == [Self.bobAccountIdHex, Self.carolAccountIdHex, Self.daveAccountIdHex])
        #expect(state.reachableDraftMembers.map(\.accountIdHex) == [Self.aliceAccountIdHex])
        // One notice, one account of the draft: no red line, and nothing left unexplained.
        #expect(state.lastError == nil)
        #expect(!state.hasUnnamedGroupDraftRefusal)
        #expect(runtime.createdGroupMemberRefs.isEmpty)
        #expect(state.isNewChatComposerVisible)

        await state.createGroupFromDraft()
        #expect(runtime.createdGroupMemberRefs == ["npub1alyce"])
        #expect(state.selection == .chat("created-group"))
    }

    @MainActor
    @Test func groupDraftSaysSomeoneRatherThanNothingWhenTheFirstRefusalNamesNobody() async throws {
        // Nothing has been refused yet, so there is no known-unreachable member to ask alongside —
        // and asking about one member alone would create a chat with them. The panel says what it
        // knows in the notice it always uses, and never on a second, contradictory line.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.invalidKeyPackageMemberRefs = ["npub1carol"]
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [Self.carolDraftRecipient(), Self.aliceDraftRecipient()]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()

        #expect(state.hasUnnamedGroupDraftRefusal)
        #expect(state.unreachableDraftMembers.isEmpty)
        #expect(state.lastError == nil)
        #expect(runtime.createGroupAttempts.count == 1)
        #expect(runtime.createdGroupMemberRefs.isEmpty)

        // Editing the roster is what the notice asks for, so the claim doesn't outlive the draft
        // it was made about.
        state.removeNewChatRecipient(Self.carolDraftRecipient())
        #expect(!state.hasUnnamedGroupDraftRefusal)
    }

    @MainActor
    @Test func groupDraftNamesAMemberWhoFailsForSomeOtherReason() async throws {
        // Not every unreachable member fails as a missing KeyPackage: one with no relay list to
        // fetch one from fails in a way that reads as a group-wide error. That stopped the search
        // at the first member, so the panel named one and went quiet about the rest.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.unresolvableMemberRefs = ["npub1carol"]
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [
            Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient(),
        ]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()

        #expect(
            state.unreachableDraftMembers.map(\.accountIdHex)
                == [Self.bobAccountIdHex, Self.carolAccountIdHex])
        #expect(state.reachableDraftMembers.map(\.accountIdHex) == [Self.aliceAccountIdHex])
        #expect(state.lastError == nil)
        #expect(!state.hasUnnamedGroupDraftRefusal)
        #expect(runtime.createdGroupMemberRefs.isEmpty)
    }

    @MainActor
    @Test func groupDraftKeepsARealErrorOnTheErrorLineWhenNoMemberOwnsIt() async throws {
        // The same kind of failure, but this one is about the send rather than a member: asking
        // about each member reproduces it every time and names no one, so it stays what it is —
        // an error on the error line, with nobody marked for it.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.createGroupFailure = MarmotKitError.Publish(details: "relay refused")
        runtime.createGroupFailureAfterAttempts = 1
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [
            Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient(),
        ]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()

        #expect(state.unreachableDraftMembers.map(\.accountIdHex) == [Self.bobAccountIdHex])
        #expect(
            state.reachableDraftMembers.map(\.accountIdHex)
                == [Self.aliceAccountIdHex, Self.carolAccountIdHex])
        #expect(state.lastError?.contains("relay refused") == true)
        #expect(!state.hasUnnamedGroupDraftRefusal)
    }

    @MainActor
    @Test func groupDraftBlamesNobodyWhenAFailureIsNotAboutAnyMember() async throws {
        // A refusal that starts *after* the roster resolves — this account, not these people. Every
        // member-by-member question then comes back unnamed, and marking each one would empty the
        // group of people who are perfectly reachable.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.createGroupFailure = MarmotKitError.InvalidIdentity(details: "identity rejected")
        runtime.createGroupFailureAfterAttempts = 1
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [
            Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient(),
        ]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()

        // Bob was named before the account-level failure began; Alice and Carol keep their place,
        // and the notice reports someone it cannot name rather than convicting them both.
        #expect(state.hasUnnamedGroupDraftRefusal)
        #expect(state.unreachableDraftMembers.map(\.accountIdHex) == [Self.bobAccountIdHex])
        #expect(
            state.reachableDraftMembers.map(\.accountIdHex)
                == [Self.aliceAccountIdHex, Self.carolAccountIdHex])
        #expect(state.lastError == nil)
        #expect(runtime.createdGroupMemberRefs.isEmpty)
    }

    @MainActor
    @Test func groupDraftShowsWhoCantBeAddedOnceRatherThanCountingUpToIt() async throws {
        // Discovery spends an attempt per refusal, so publishing each one as it lands rendered the
        // answer growing on screen — one name, then two — which reads as the panel correcting
        // itself. The press has a single answer and says it when it has all of it.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1carol"] = Self.carolAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [
            Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient(),
        ]
        state.newChatName = "Project Room"

        // What the panel would have been rendering at the start of each attempt.
        let visible = MidPressMarkCounts()
        runtime.onMemberResolutionAttempt = { @Sendable in
            await MainActor.run { visible.counts.append(state.unreachableDraftMembers.count) }
        }
        await state.createGroupFromDraft()

        #expect(visible.counts == [0, 0])
        #expect(
            state.unreachableDraftMembers.map(\.accountIdHex)
                == [Self.bobAccountIdHex, Self.carolAccountIdHex])
    }

    @MainActor
    @Test func addMembersSheetShowsWhoCantBeAddedOnceRatherThanCountingUpToIt() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1carol"] = Self.carolAccountIdHex
        let state = try await openInstalledGroupDetails(runtime: runtime)
        let staged = [Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient()]

        let visible = MidPressMarkCounts()
        runtime.onMemberResolutionAttempt = { @Sendable in
            await MainActor.run { visible.counts.append(state.unreachableInviteRecipients(staged).count) }
        }
        await state.inviteMembers(staged)

        #expect(visible.counts == [0, 0])
        #expect(
            state.unreachableInviteRecipients(staged).map(\.accountIdHex)
                == [Self.bobAccountIdHex, Self.carolAccountIdHex])
    }

    @MainActor
    @Test func groupDraftCreatesTheGroupOnTheNextPressAfterEveryRefusalIsShown() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1carol"] = Self.carolAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [
            Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient(),
        ]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()
        await state.createGroupFromDraft()

        #expect(runtime.createdGroupMemberRefs == ["npub1alyce"])
        #expect(state.selection == .chat("created-group"))
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func groupDraftWhereNobodyIsReachableMarksThemAllAndCreatesNothing() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1carol"] = Self.carolAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [Self.bobDraftRecipient(), Self.carolDraftRecipient()]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()

        #expect(
            state.unreachableDraftMembers.map(\.accountIdHex)
                == [Self.bobAccountIdHex, Self.carolAccountIdHex])
        #expect(state.reachableDraftMembers.isEmpty)
        #expect(runtime.createdGroupMemberRefs.isEmpty)
        #expect(state.lastError == nil)
        #expect(state.isNewChatComposerVisible)
    }

    @MainActor
    @Test func groupDraftKeepsAMemberWhoBecomesReachableWhileTheRestAreBeingChecked() async throws {
        // The pinned member is what keeps a follow-up attempt failing, so the one way a follow-up
        // can succeed is that they published a KeyPackage between two attempts. They are then in
        // the group the core just created, and the mark taken moments earlier is stale.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1carol"] = Self.carolAccountIdHex
        runtime.forgetsMissingKeyPackagesAfterAttempts = 1
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [
            Self.aliceDraftRecipient(), Self.bobDraftRecipient(), Self.carolDraftRecipient(),
        ]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()

        // Everyone the user picked is in the group, Bob included — a follow-up that goes through
        // carries the pinned member, so it creates the roster the draft asked for rather than one
        // missing whoever was refused a moment earlier.
        #expect(runtime.createdGroupMemberRefs == ["npub1alyce", "npub1carol", "npub1p0p"])
        #expect(state.selection == .chat("created-group"))
        #expect(state.unreachableDraftMembers.isEmpty)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func groupDraftRetryExcludesTheNamedMemberAndCreatesTheGroup() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [Self.aliceDraftRecipient(), Self.bobDraftRecipient()]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()
        await state.createGroupFromDraft()

        #expect(runtime.createdGroupMemberRefs == ["npub1alyce"])
        #expect(state.selection == .chat("created-group"))
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func aMemberAddedAfterARefusalIsCheckedOnTheNextAttempt() async throws {
        // The core names one refused member per attempt, so the split has to keep up with a draft
        // that is still being edited. Someone added *after* an earlier refusal carries no mark, so
        // the next attempt must include them — and refuse them in turn — rather than treating the
        // roster as settled once the first refusal landed.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1carol"] = Self.carolAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [Self.aliceDraftRecipient(), Self.bobDraftRecipient()]
        state.newChatName = "Project Room"

        await state.createGroupFromDraft()
        #expect(state.unreachableDraftMembers.map(\.accountIdHex) == [Self.bobAccountIdHex])

        // Add Carol, who is also unreachable, after Bob was already marked.
        state.appendNewChatRecipient(Self.carolDraftRecipient())
        #expect(state.reachableDraftMembers.map(\.accountIdHex) == [Self.aliceAccountIdHex, Self.carolAccountIdHex])

        await state.createGroupFromDraft()
        #expect(
            Set(state.unreachableDraftMembers.map(\.accountIdHex))
                == [Self.bobAccountIdHex, Self.carolAccountIdHex])
        #expect(runtime.createdGroupMemberRefs.isEmpty)

        // Only once every refusal is known does the attempt go through, with the roster the panel
        // has been showing all along.
        await state.createGroupFromDraft()
        #expect(runtime.createdGroupMemberRefs == ["npub1alyce"])
        #expect(state.selection == .chat("created-group"))
    }

    @MainActor
    @Test func removingARefusedMemberDropsItsMarkWithIt() async throws {
        // The split is derived from the live roster, so a mark can never outlive the recipient
        // it belongs to and reappear against someone re-added later.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        let bob = Self.bobDraftRecipient()
        state.newChatRecipients = [Self.aliceDraftRecipient(), bob]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()
        #expect(state.unreachableDraftMembers.count == 1)

        state.removeNewChatRecipient(bob)

        #expect(state.unreachableDraftMembers.isEmpty)
        #expect(state.reachableDraftMembers.map(\.accountIdHex) == [Self.aliceAccountIdHex])
    }

    @MainActor
    @Test func closingTheComposerClearsTheRefusedDraftMembers() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [Self.aliceDraftRecipient(), Self.bobDraftRecipient()]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()
        #expect(!state.unreachableDraftMemberIdHexes.isEmpty)

        state.closeNewChatComposer()

        #expect(state.unreachableDraftMemberIdHexes.isEmpty)
        #expect(state.startChatInvitePrompt == nil)
    }

    @MainActor
    @Test func editingTheQueryHidesAStaleInvitePrompt() async throws {
        // The prompt names the person a previous attempt failed on and renders above the results,
        // so leaving it up while the user searches for someone else pins "Bob isn't on White
        // Noise yet" over Alice's row.
        //
        // Asserted on the *derived* property with no await in between: the only clear hook
        // available is the 250 ms debounced resolution, which cancels itself on every keystroke,
        // so a prompt cleared imperatively would stay on screen for as long as the user keeps
        // typing — the case that matters most.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        await state.startDirectChat(with: Self.bobDraftRecipient())
        #expect(state.visibleStartChatInvitePrompt?.accountIdHex == Self.bobAccountIdHex)

        // Mid-typing, before any debounce could fire.
        state.newChatQuery = "a"
        #expect(state.visibleStartChatInvitePrompt == nil)
        state.newChatQuery = "alice"
        #expect(state.visibleStartChatInvitePrompt == nil)

        // Clearing the field puts the user back where the prompt was raised, and the recipient is
        // still unreachable, so showing it again is accurate rather than stale.
        state.newChatQuery = ""
        #expect(state.visibleStartChatInvitePrompt?.accountIdHex == Self.bobAccountIdHex)
    }

    @MainActor
    @Test func aTypedIdentifierInvitePromptBelongsToThatIdentifier() async throws {
        // Raised from the identifier branch rather than a contact row, so the prompt is scoped to
        // the npub that produced it and must not survive into a different one.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1p0p"
        await state.startDirectChat(with: Self.bobDraftRecipient())
        #expect(state.visibleStartChatInvitePrompt?.query == "npub1p0p")

        state.newChatQuery = "npub1carol"
        #expect(state.visibleStartChatInvitePrompt == nil)
    }

    @MainActor
    @Test func groupCreateFailureUnderASupersededAccountStaysOutOfTheNewAccount() async throws {
        // Issue #229's rule applied to the failure path: `createGroupFromDraft()` suspends across
        // `createGroup`, so a mid-await A→B switch must not land account A's failure in account
        // B's context. Asserted on `lastError` specifically because it is the one field the
        // switch does *not* clear — `closeNewChatComposer()` resets the draft and the prompt, so
        // only this one can prove the call-site guard is doing the work.
        let accountA = desktopAccount()
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.createGroupFailure = MarmotKitError.Publish(details: "relay refused")
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        state.showNewChat()
        state.newChatRecipients = [Self.aliceDraftRecipient(), Self.bobDraftRecipient()]
        state.newChatName = "Project Room"

        runtime.createGroupGateEnabled = true
        async let pendingCreate: Void = state.createGroupFromDraft()
        while !runtime.didReachCreateGroupGate {
            await Task.yield()
        }

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")

        runtime.releaseCreateGroupGate()
        _ = await pendingCreate

        #expect(state.lastError == nil)
        #expect(state.startChatInvitePrompt == nil)
        #expect(state.unreachableDraftMemberIdHexes.isEmpty)
    }

    @MainActor
    @Test func directChatWithSomeoneNotOnWhiteNoiseOffersAnInviteInsteadOfAnError() async throws {
        // One recipient means there is no composition left to fix, so the panel drops the error
        // line entirely and offers the only useful next step.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        await state.startDirectChat(with: Self.bobDraftRecipient())

        #expect(state.lastError == nil)
        #expect(state.startChatInvitePrompt?.accountIdHex == Self.bobAccountIdHex)
        #expect(state.startChatInvitePrompt?.recipientName == "Bob")
        #expect(state.startChatInvitePrompt?.detail.contains("Bob") == true)
    }

    @MainActor
    @Test func groupCreateFailureThatNamesNobodyFallsBackToAnUnnamedMessage() async throws {
        // `InvalidKeyPackageEvent` carries a detail string, not an account. Marking nobody would
        // leave the panel unchanged and make the press look like a no-op, so it is reported — in
        // the notice the panel already uses for this, never as a red line beside it, and never as
        // the raw `MarmotKitError` dump.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.createGroupFailure = MarmotKitError.InvalidKeyPackageEvent(details: "unsupported ciphersuite")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [Self.aliceDraftRecipient(), Self.bobDraftRecipient()]
        state.newChatName = "Project Room"
        await state.createGroupFromDraft()

        #expect(state.unreachableDraftMembers.isEmpty)
        #expect(state.hasUnnamedGroupDraftRefusal)
        #expect(state.lastError == nil)
    }

    @Test func chatCreationFailureKeepsUnrelatedCoreErrorsIntact() {
        let failure = ChatCreationFailure(MarmotKitError.Publish(details: "relay refused"))
        guard case .other(let message) = failure else {
            Issue.record("expected .other, got \(failure)")
            return
        }
        #expect(message.contains("relay refused"))
    }

    @Test func chatCreationFailureMatchesTheRefusedRecipientByEitherIdentifier() {
        let alice = Self.aliceDraftRecipient()
        #expect(
            ChatCreationFailure.refusedRecipient(named: Self.aliceAccountIdHex.uppercased(), among: [alice])?
                .accountIdHex == Self.aliceAccountIdHex)
        #expect(ChatCreationFailure.refusedRecipient(named: "npub1alyce", among: [alice])?.npub == "npub1alyce")
        #expect(ChatCreationFailure.refusedRecipient(named: "someone else", among: [alice]) == nil)
        #expect(ChatCreationFailure.refusedRecipient(named: nil, among: [alice]) == nil)
    }

    private static let aliceAccountIdHex =
        "a11ce1234567890aa11ce1234567890aa11ce1234567890aa11ce1234567890a"

    private static let bobAccountIdHex =
        "b0b1234567890abb0b1234567890abb0b1234567890abb0b1234567890abb0b1"

    private static let carolAccountIdHex =
        "ca401234567890ddca401234567890ddca401234567890ddca401234567890dd"

    private static func aliceDraftRecipient() -> NewChatRecipient {
        NewChatRecipient(
            sourceQuery: "npub1alyce",
            memberRef: "npub1alyce",
            accountIdHex: aliceAccountIdHex,
            npub: "npub1alyce",
            displayName: "Alice",
            pictureURL: nil
        )
    }

    private static func bobDraftRecipient() -> NewChatRecipient {
        NewChatRecipient(
            sourceQuery: "npub1p0p",
            memberRef: "npub1p0p",
            accountIdHex: bobAccountIdHex,
            npub: "npub1p0p",
            displayName: "Bob",
            pictureURL: nil
        )
    }

    private static func carolDraftRecipient() -> NewChatRecipient {
        NewChatRecipient(
            sourceQuery: "npub1carol",
            memberRef: "npub1carol",
            accountIdHex: carolAccountIdHex,
            npub: "npub1carol",
            displayName: "Carol",
            pictureURL: nil
        )
    }

    private static let daveAccountIdHex =
        "da7e1234567890eeda7e1234567890eeda7e1234567890eeda7e1234567890ee"

    private static func daveDraftRecipient() -> NewChatRecipient {
        NewChatRecipient(
            sourceQuery: "npub1dave",
            memberRef: "npub1dave",
            accountIdHex: daveAccountIdHex,
            npub: "npub1dave",
            displayName: "Dave",
            pictureURL: nil
        )
    }

    @MainActor
    @Test func startingDirectChatReusesExistingConversation() async throws {
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installNormalizedMemberRef(query: "npub1alice", accountIdHex: aliceId, npub: "npub1alice")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1alice"
        await state.createNewChat()

        #expect(runtime.createdGroupMemberRefs.isEmpty)
        #expect(state.selection == .chat("direct-group"))
        #expect(!state.isNewChatComposerVisible)
    }

    @MainActor
    @Test func createNewChatIncludesPendingQueryAlongsideAddedMembers() async throws {
        // Regression: a pubkey typed into the input but not yet committed via
        // return/+ must not be silently dropped when confirmed members already
        // exist — createNewChat resolves the pending query and folds it in.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: "npub1alyce", accountIdHex: aliceId, npub: "npub1alyce")
        runtime.installNormalizedMemberRef(query: "npub1p0p", accountIdHex: bobId, npub: "npub1p0p")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()

        // Commit the first member the normal way (this clears the input).
        state.newChatQuery = "npub1alyce"
        _ = await state.addCurrentNewChatRecipient()
        #expect(state.newChatRecipients.map(\.accountIdHex) == [aliceId])
        #expect(state.newChatQuery.isEmpty)

        // Leave the second pubkey pending in the input, then create directly.
        state.newChatQuery = "npub1p0p"
        await state.createNewChat()

        #expect(runtime.createdGroupMemberRefs == ["npub1alyce", "npub1p0p"])
        #expect(state.selection == .chat("created-group"))
    }

    @MainActor
    @Test func createNewChatDoesNotGraftGroupOntoAccountSwitchedToMidCreate() async throws {
        // Issue #229: `createNewChat()` suspends across `createGroup`/`reloadChats`. If the active
        // account changes (e.g. a notification tap) while suspended, the group created under
        // account A must not be inserted into / selected / loaded under account B's context. The
        // post-await `activeAccountId == accountId` guard drops the stale UI mutations.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")

        state.showNewChat()
        state.newChatQuery = "npub1alyce"
        state.newChatName = "Project Room"

        // Arm the gate so the create suspends in-flight inside `createGroup`.
        runtime.createGroupGateEnabled = true
        async let pendingCreate: Void = state.createNewChat()
        while !runtime.didReachCreateGroupGate {
            await Task.yield()
        }

        // Switch to account B while the create is suspended. Drop the runtime's shared group
        // fixture so B's own `reloadChats()` does not legitimately surface the created group —
        // isolating the assertion to the cross-account contamination path under test.
        runtime.installGroups([])
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")

        // Release the stale create. Its post-await mutations must be dropped under B's context.
        runtime.releaseCreateGroupGate()
        _ = await pendingCreate

        #expect(state.activeAccountId == "Backup Account")
        #expect(state.selection != .chat("created-group"))
        #expect(!state.activeChats.contains { $0.id == "created-group" })
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func resolvingNewChatRecipientUsesProfilePicture() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1alyce"
        await state.resolveNewChatQuery()

        #expect(state.resolvedNewChatRecipient?.title == "Desktop Account")
        #expect(state.resolvedNewChatRecipient?.pictureURL == "https://example.com/avatar.png")
    }

    @Test func nip05IdentifierAcceptsCanonicalASCIIDomains() {
        // #527: domains must be stored as canonical lowercase ASCII hostnames.
        let alice = NIP05Identifier("alice@example.com")
        #expect(alice?.name == "alice")
        #expect(alice?.domain == "example.com")
        #expect(NIP05Identifier("bob@EXAMPLE.COM")?.domain == "example.com")
    }

    @Test func nip05IdentifierNormalizesInternationalDomainsToASCII() throws {
        // #527: valid IDNs must be converted to Foundation's canonical punycode host form.
        let identifier = NIP05Identifier("alice@münchen.de")
        #expect(identifier?.name == "alice")
        #expect(try #require(identifier?.domain) == "xn--mnchen-3ya.de")
    }

    @Test func nip05IdentifierCanonicalizesHomographDomains() throws {
        // #527: U+0261 is not mapped to LATIN SMALL LETTER G under UTS #46, so punycode is stable.
        let scriptG = "\u{0261}"
        let identifier = NIP05Identifier("alice@\(scriptG)oogle.com")
        #expect(identifier?.name == "alice")
        #expect(try #require(identifier?.domain) == "xn--oogle-qmc.com")
    }

    @Test func nip05IdentifierCanonicalizesUnicodeLabelSeparators() {
        // #527: UTS #46 label separators must IDNA-map to canonical ASCII dots.
        #expect(NIP05Identifier("alice@example\u{3002}com")?.domain == "example.com")
        #expect(NIP05Identifier("alice@example\u{FF0E}com")?.domain == "example.com")
        #expect(NIP05Identifier("alice@example\u{FF61}com")?.domain == "example.com")
    }

    @Test func nip05IdentifierCanonicalizesSingleTrailingRootSeparator() {
        // #527: at most one terminal root separator may be accepted and stripped.
        #expect(NIP05Identifier("alice@example.com.")?.domain == "example.com")
        #expect(NIP05Identifier("alice@example.com\u{3002}")?.domain == "example.com")
    }

    @Test func nip05IdentifierRejectsMultipleTrailingRootSeparators() {
        // #527: multiple terminal empty labels must be rejected.
        #expect(NIP05Identifier("alice@example.com..") == nil)
        #expect(NIP05Identifier("alice@example.com\u{3002}.") == nil)
        #expect(NIP05Identifier("alice@example.com.\u{FF0E}") == nil)
    }

    @Test func nip05IdentifierValidatesALabelRoundTrip() {
        // #527: reserved xn-- labels must decode/re-encode; malformed A-labels are rejected.
        #expect(NIP05Identifier("alice@xn--a.com") == nil)
        #expect(NIP05Identifier("alice@xn--abc.com") == nil)
        #expect(NIP05Identifier("alice@xn--mnchen-3ya.de")?.domain == "xn--mnchen-3ya.de")
        // Malformed A-labels must be rejected even when another label decodes via IDNA.
        #expect(NIP05Identifier("alice@münchen.xn--a.com") == nil)
        #expect(NIP05Identifier("alice@xn--mnchen-3ya.xn--a.com") == nil)
    }

    @Test func nip05IdentifierRejectsMalformedDomains() {
        // #527: malformed or non-LDH DNS hostnames must be rejected.
        #expect(NIP05Identifier("alice@foo..bar.com") == nil)
        #expect(NIP05Identifier("alice@-example.com") == nil)
        #expect(NIP05Identifier("alice@ex_ample.com") == nil)
        #expect(NIP05Identifier("alice@.example.com") == nil)
        #expect(NIP05Identifier("alice@example") == nil)
    }

    @Test func nip05IdentifierEnforcesLengthBounds() {
        // #527: overlong local names, labels, and domains must be rejected.
        let validName = String(repeating: "a", count: 64)
        let overlongName = String(repeating: "a", count: 65)
        #expect(validName.utf8.count == 64)
        #expect(NIP05Identifier("\(validName)@example.com") != nil)
        #expect(NIP05Identifier("\(overlongName)@example.com") == nil)

        let validLabel = String(repeating: "a", count: 63)
        let overlongLabel = String(repeating: "a", count: 64)
        #expect(NIP05Identifier("alice@\(validLabel).com") != nil)
        #expect(NIP05Identifier("alice@\(overlongLabel).com") == nil)

        let maxDomain =
            Array(repeating: String(repeating: "a", count: 42), count: 5).joined(separator: ".")
            + "." + String(repeating: "b", count: 38)
        #expect(maxDomain.count == 253)
        #expect(NIP05Identifier("alice@\(maxDomain)") != nil)
        #expect(NIP05Identifier("alice@\(maxDomain)x") == nil)
    }

    @Test func nip05IdentifierRejectsQueryMetacharactersInName() {
        // #527: local names must not be able to inject extra query parameters.
        #expect(NIP05Identifier("x&foo=bar@example.com") == nil)
        #expect(NIP05Identifier("x=1@example.com") == nil)
        #expect(NIP05Identifier("x+1@example.com") == nil)
        #expect(NIP05Identifier("x%41@example.com") == nil)
        #expect(NIP05Identifier("x/y@example.com") == nil)
        #expect(NIP05Identifier("x?y@example.com") == nil)
    }

    @Test func nip05WellKnownRequestURLUsesSingleStrictlyEncodedQueryItem() throws {
        // #527: the well-known lookup URL must contain exactly one strictly encoded name item.
        let identifier = try #require(NIP05Identifier("Alice.Smith_9-a@example.com"))
        let url = try #require(identifier.wellKnownRequestURL())
        #expect(url.host == "example.com")
        #expect(url.path == "/.well-known/nostr.json")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedQuery == "name=alice.smith_9-a")
        #expect(components.queryItems?.count == 1)
        #expect(components.queryItems?.first?.name == "name")
        #expect(components.queryItems?.first?.value == "alice.smith_9-a")
    }

    @Test func nip05RedirectPolicyRevalidatesRedirectTargets() throws {
        // #448: the resolver's session must re-check every redirect hop against the SSRF host
        // policy, so a public well-known host cannot 3xx the lookup to a private/loopback/
        // non-https target.
        let policy = NIP05RedirectPolicy()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let redirectResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 302, httpVersion: nil, headerFields: nil
        )!

        // A fresh task per decision — each target is an independent host-revalidation check, not a
        // hop of one lookup, so they must not share the per-task redirect-hop budget.
        func followedRequest(to target: String) -> URLRequest? {
            let task = session.dataTask(with: URL(string: "https://example.com/.well-known/nostr.json")!)
            var decided: URLRequest?
            policy.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: redirectResponse,
                newRequest: URLRequest(url: URL(string: target)!)
            ) { decided = $0 }
            return decided
        }

        // Blocked: loopback, link-local, private, IPv6 loopback, and scheme downgrade.
        #expect(followedRequest(to: "https://127.0.0.1:8080/x") == nil)
        #expect(followedRequest(to: "https://169.254.169.254/x") == nil)
        #expect(followedRequest(to: "https://10.0.0.5/x") == nil)
        #expect(followedRequest(to: "https://[::1]/x") == nil)
        #expect(followedRequest(to: "http://example.com/x") == nil)
        // Allowed: a public https target is followed unchanged.
        let allowed = followedRequest(to: "https://relay.example.com/x")
        #expect(allowed?.url?.absoluteString == "https://relay.example.com/x")
    }

    @Test func nip05ResolverStreamingCapRejectsOversizedBodyWithoutContentLength() async {
        // No advertised length, so the streaming cap (not the pre-check) is what must fire.
        NIP05URLProtocolStub.configure(body: Data(repeating: 0x20, count: 512 * 1024), sendContentLength: false)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NIP05URLProtocolStub.self]
        let resolver = NIP05Resolver(session: URLSession(configuration: config))
        do {
            _ = try await resolver.accountReference(for: "alyce@relay.example.com")
            Issue.record("expected responseTooLarge")
        } catch NIP05ResolutionError.responseTooLarge {
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func nip05ResolverPreCheckRejectsOversizedContentLength() async {
        NIP05URLProtocolStub.configure(body: Data(repeating: 0x20, count: 512 * 1024), sendContentLength: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NIP05URLProtocolStub.self]
        let resolver = NIP05Resolver(session: URLSession(configuration: config))
        do {
            _ = try await resolver.accountReference(for: "alyce@relay.example.com")
            Issue.record("expected responseTooLarge")
        } catch NIP05ResolutionError.responseTooLarge {
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func nip05ResolverStreamsAndDecodesSmallBody() async throws {
        let hex = String(repeating: "a", count: 64)
        NIP05URLProtocolStub.configure(body: Data("{\"names\":{\"alyce\":\"\(hex)\"}}".utf8), sendContentLength: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NIP05URLProtocolStub.self]
        let resolver = NIP05Resolver(session: URLSession(configuration: config))
        let reference = try await resolver.accountReference(for: "alyce@relay.example.com")
        #expect(reference == hex)
    }

    @MainActor
    @Test func resolvingNewChatRecipientUsesNIP05() async throws {
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: aliceId, accountIdHex: aliceId, npub: "npub1alyce")
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice NIP-05",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: "alice@example.com",
                lud16: nil
            )
        )
        let state = WorkspaceState(
            nip05Resolver: StubNIP05Resolver(accountReferences: ["alice@example.com": aliceId]),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "alice@example.com"
        await state.resolveNewChatQuery()

        #expect(state.looksLikeMemberRef("alice@example.com"))
        #expect(state.resolvedNewChatRecipient?.sourceQuery == "alice@example.com")
        #expect(state.resolvedNewChatRecipient?.accountIdHex == aliceId)
        #expect(state.resolvedNewChatRecipient?.npub == "npub1alyce")
        #expect(state.resolvedNewChatRecipient?.title == "Alice NIP-05")
        #expect(state.resolvedNewChatRecipient?.pictureURL == "https://example.com/alice.png")
    }

    @MainActor
    @Test func createNewChatResolvesPendingNIP05Query() async throws {
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: aliceId, accountIdHex: aliceId, npub: "npub1alyce")
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice NIP-05",
                about: nil,
                picture: nil,
                nip05: "alice@example.com",
                lud16: nil
            )
        )
        let state = WorkspaceState(
            nip05Resolver: StubNIP05Resolver(accountReferences: ["alice@example.com": aliceId]),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "alice@example.com"
        await state.createNewChat()

        #expect(runtime.createdGroupMemberRefs == [aliceId])
        #expect(runtime.createdGroupName == "Alice NIP-05")
        #expect(state.selection == .chat("created-group"))
    }

    @MainActor
    @Test func openingNostrProfileLinkShowsNewChatComposerAndResolvesRecipient() async throws {
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let nprofile = "nprofile1alyce"
        let query = "nostr:\(nprofile)"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: query, accountIdHex: aliceId, npub: "npub1alyce")
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Link",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.newChatQuery = "stale draft"
        state.newChatName = "Stale room"
        _ = state.handleMessageLinkOpen(URL(string: query)!)
        let resolved = await waitFor {
            state.resolvedNewChatRecipient?.sourceQuery == query
        }

        #expect(resolved)
        #expect(state.isNewChatComposerVisible)
        #expect(state.newChatQuery == query)
        #expect(state.newChatName.isEmpty)
        #expect(state.resolvedNewChatRecipient?.npub == "npub1alyce")
        #expect(state.resolvedNewChatRecipient?.title == "Alice Link")
    }

    @MainActor
    @Test func openingProfileLinkPreservesInProgressNewChatComposition() async throws {
        // Issue #421: profile autolinks/deep links must not wipe an in-progress New Chat
        // draft (recipients, group name, description) when the composer is already visible.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1234567890"
        let carolId = "carol1234567890carol1234567890carol1234567890carol1234567890"
        let nprofile = "nprofile1p0p"
        let query = "nostr:\(nprofile)"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: "npub1alyce", accountIdHex: aliceId, npub: "npub1alyce")
        runtime.installNormalizedMemberRef(query: query, accountIdHex: bobId, npub: "npub1p0p")
        runtime.installNormalizedMemberRef(query: "npub1car0l", accountIdHex: carolId, npub: "npub1car0l")
        runtime.installProfile(
            accountIdHex: bobId,
            profile: UserProfileMetadataFfi(
                name: "bob",
                displayName: "Bob Link",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1alyce"
        _ = await state.addCurrentNewChatRecipient()
        state.newChatName = "Project Room"
        state.newChatDescription = "planning space"
        state.newChatQuery = "npub1car0l"
        await state.resolveNewChatQuery()
        #expect(state.resolvedNewChatRecipient?.accountIdHex == carolId)

        _ = state.handleMessageLinkOpen(URL(string: query)!)
        let added = await waitFor {
            state.newChatRecipients.contains { $0.accountIdHex == bobId }
        }

        #expect(added)
        #expect(state.isNewChatComposerVisible)
        #expect(state.newChatRecipients.map(\.accountIdHex) == [aliceId, bobId])
        #expect(state.newChatName == "Project Room")
        #expect(state.newChatDescription == "planning space")
        #expect(state.newChatQuery == "npub1car0l")
        #expect(state.resolvedNewChatRecipient?.accountIdHex == carolId)
    }

    @MainActor
    @Test func profileLinkAppendDoesNotOverwriteMidLookupComposerEdits() async throws {
        // Regression for the #421 review finding: appending a profile link into an existing
        // draft must not borrow `newChatQuery` as scratch state and later restore stale input
        // over user edits made while the link lookup was in flight.
        let account = desktopAccount()
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1234567890"
        let carolId = "carol1234567890carol1234567890carol1234567890carol1234567890"
        let daveId = "dave1234567890dave1234567890dave1234567890dave1234567890"
        let bobReference = "nprofile1p0p"
        let bobQuery = "nostr:\(bobReference)"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: bobQuery, accountIdHex: bobId, npub: "npub1p0p")
        runtime.installNormalizedMemberRef(query: "npub1car0l", accountIdHex: carolId, npub: "npub1car0l")
        runtime.installNormalizedMemberRef(query: "npub1dave", accountIdHex: daveId, npub: "npub1dave")
        runtime.profileRefreshDelaysByAccountId[bobId] = 200_000_000
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatName = "Project Room"
        state.newChatQuery = "npub1car0l"
        await state.resolveNewChatQuery()
        #expect(state.resolvedNewChatRecipient?.accountIdHex == carolId)

        async let appendProfileLink: Void = state.openProfileReference(bobReference)
        let bobLookupStarted = await waitFor {
            runtime.refreshedProfileIds.contains(bobId)
        }
        #expect(bobLookupStarted)

        state.newChatQuery = "npub1dave"
        state.newChatRecipient = nil
        await state.resolveNewChatQuery()
        #expect(state.resolvedNewChatRecipient?.accountIdHex == daveId)

        _ = await appendProfileLink

        #expect(state.isNewChatComposerVisible)
        #expect(state.newChatRecipients.map(\.accountIdHex) == [bobId])
        #expect(state.newChatName == "Project Room")
        #expect(state.newChatQuery == "npub1dave")
        #expect(state.resolvedNewChatRecipient?.accountIdHex == daveId)
    }

    @MainActor
    @Test func marmotDeepLinkDoesNotMutateInProgressNewChatComposition() async throws {
        // Issue #510: OS-delivered marmot:// links are untrusted and must not silently append
        // an attacker-chosen recipient to a draft that the user is already composing.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1234567890"
        let routedQuery = "nostr:npub1p0p"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: "npub1alyce", accountIdHex: aliceId, npub: "npub1alyce")
        runtime.installNormalizedMemberRef(query: routedQuery, accountIdHex: bobId, npub: "npub1p0p")
        let activationRecorder = AppActivationRecorder()
        let state = WorkspaceState(
            appActivationHandler: activationRecorder.record,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1alyce"
        _ = await state.addCurrentNewChatRecipient()
        state.newChatName = "Project Room"
        state.newChatDescription = "planning space"

        state.handleDeepLinkURL(URL(string: "marmot://profile/npub1p0p?from=qr")!)
        let blocked = await waitFor {
            state.backgroundStatus == "Finish or discard the current New Chat draft before opening this link."
        }

        #expect(blocked)
        #expect(state.isNewChatComposerVisible)
        #expect(state.newChatRecipients.map(\.accountIdHex) == [aliceId])
        #expect(state.newChatName == "Project Room")
        #expect(state.newChatDescription == "planning space")
        #expect(!runtime.refreshedProfileIds.contains(bobId))
        #expect(activationRecorder.requests == [false])
    }

    @MainActor
    @Test func marmotDeepLinkDoesNotCancelInProgressVoiceRecording() async throws {
        // Issue #510: an unsolicited external link must not discard plaintext audio that the
        // user is still recording or hide the recording controls by opening New Chat.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let activationRecorder = AppActivationRecorder()
        let state = WorkspaceState(
            appActivationHandler: activationRecorder.record,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        let recordingURL = try armInProgressVoiceRecording(on: state)
        defer { state.cancelVoiceRecording() }

        state.handleDeepLinkURL(URL(string: "marmot://profile/npub1p0p")!)
        let blocked = await waitFor {
            state.backgroundStatus == "Finish the current voice recording before opening this link."
        }

        #expect(blocked)
        #expect(state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingURL == recordingURL)
        #expect(state.voiceRecordingMeterTask != nil)
        #expect(FileManager.default.fileExists(atPath: recordingURL.path))
        #expect(!state.isNewChatComposerVisible)
        #expect(state.resolvedNewChatRecipient == nil)
        #expect(activationRecorder.requests == [false])
    }

    @MainActor
    @Test func marmotDeepLinkDoesNotInterruptVoiceRecordingPreparation() async throws {
        // The microphone-permission await is part of the recording flow too. Navigating during
        // it could let recording begin after the New Chat composer has hidden the stop controls.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let activationRecorder = AppActivationRecorder()
        let state = WorkspaceState(
            appActivationHandler: activationRecorder.record,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.isPreparingVoiceRecording = true
        defer { state.isPreparingVoiceRecording = false }

        state.handleDeepLinkURL(URL(string: "marmot://profile/npub1p0p")!)
        let blocked = await waitFor {
            state.backgroundStatus == "Finish the current voice recording before opening this link."
        }

        #expect(blocked)
        #expect(state.isPreparingVoiceRecording)
        #expect(!state.isNewChatComposerVisible)
        #expect(state.resolvedNewChatRecipient == nil)
        #expect(activationRecorder.requests == [false])
    }

    @MainActor
    @Test func openingMarmotProfileAutolinkShowsNewChatComposerAndResolvesRecipient() async throws {
        // Kit-emitted marmot://profile/... autolinks in message text route through the same
        // in-app profile flow as nostr: links (mdk#725 / #340); the FFI receives the
        // extracted reference in nostr: form.
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let routedQuery = "nostr:nprofile1alyce"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: routedQuery, accountIdHex: aliceId, npub: "npub1alyce")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        _ = state.handleMessageLinkOpen(URL(string: "marmot://profile/nprofile1alyce")!)
        let resolved = await waitFor {
            state.resolvedNewChatRecipient?.sourceQuery == routedQuery
        }

        #expect(resolved)
        #expect(state.isNewChatComposerVisible)
        #expect(state.resolvedNewChatRecipient?.npub == "npub1alyce")
    }

    @MainActor
    @Test func marmotDeepLinkWhenReadyOpensComposerAndResolvesRecipient() async throws {
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let routedQuery = "nostr:npub1alyce"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: routedQuery, accountIdHex: aliceId, npub: "npub1alyce")
        let activationRecorder = AppActivationRecorder()
        let state = WorkspaceState(
            appActivationHandler: activationRecorder.record,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.handleDeepLinkURL(URL(string: "marmot://profile/npub1alyce?from=qr")!)
        let resolved = await waitFor {
            state.resolvedNewChatRecipient?.sourceQuery == routedQuery
        }

        #expect(resolved)
        #expect(state.isNewChatComposerVisible)
        #expect(state.pendingDeepLinkProfileReference == nil)
        #expect(state.resolvedNewChatRecipient?.npub == "npub1alyce")
        #expect(activationRecorder.requests == [false])
    }

    @MainActor
    @Test func marmotDeepLinkWhenSignedOutQueuesWithoutActivatingApp() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let activationRecorder = AppActivationRecorder()
        let state = WorkspaceState(
            appActivationHandler: activationRecorder.record,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.handleDeepLinkURL(URL(string: "marmot://profile/npub1alyce?from=qr")!)

        #expect(state.phase == .onboarding)
        #expect(state.pendingDeepLinkProfileReference == "npub1alyce")
        #expect(state.backgroundStatus == "Sign in to start a chat from this link.")
        #expect(!state.isNewChatComposerVisible)
        #expect(activationRecorder.requests.isEmpty)
    }

    @MainActor
    @Test func marmotDeepLinkBeforeBootstrapIsQueuedAndFlushedWhenReady() async throws {
        // Cold start: .onOpenURL fires before bootstrap() finishes, so the reference must be
        // queued and flushed by activateReadyState().
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let routedQuery = "nostr:npub1alyce"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: routedQuery, accountIdHex: aliceId, npub: "npub1alyce")
        let activationRecorder = AppActivationRecorder()
        let state = WorkspaceState(
            appActivationHandler: activationRecorder.record,
            clientFactory: { runtime }
        )

        state.handleDeepLinkURL(URL(string: "marmot://profile/npub1alyce?from=qr")!)
        #expect(state.pendingDeepLinkProfileReference == "npub1alyce")
        #expect(state.resolvedNewChatRecipient == nil)
        #expect(activationRecorder.requests.isEmpty)

        await state.bootstrap()
        let resolved = await waitFor {
            state.resolvedNewChatRecipient?.sourceQuery == routedQuery
        }

        #expect(resolved)
        #expect(state.isNewChatComposerVisible)
        #expect(state.pendingDeepLinkProfileReference == nil)
        #expect(activationRecorder.requests.isEmpty)
    }

    @MainActor
    @Test func marmotDeepLinkWithUnsupportedFormSetsStatusAndQueuesNothing() async throws {
        // The scheme is not exclusive to this app; anything but the strict profile form is
        // untrusted input and must be dropped without touching the composer or the queue.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.handleDeepLinkURL(URL(string: "marmot://group/abc")!)

        #expect(state.backgroundStatus == "This link type is not supported.")
        #expect(state.pendingDeepLinkProfileReference == nil)
        #expect(!state.isNewChatComposerVisible)
        #expect(state.resolvedNewChatRecipient == nil)
    }

    @MainActor
    @Test func pastedMarmotProfileLinkResolvesThroughNormalizeMemberRef() async throws {
        // The raw pasted marmot://profile/... string reaches the FFI verbatim; the vendored
        // bindings parse it since the mdk#725 bump (clean break: darkmatter:// is dead).
        let account = desktopAccount()
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let pasted = "marmot://profile/npub1alyce?from=qr"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: pasted, accountIdHex: aliceId, npub: "npub1alyce")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.looksLikeMemberRef(pasted))
        #expect(!state.looksLikeMemberRef("darkmatter://profile/npub1alyce"))

        state.showNewChat()
        state.newChatQuery = pasted
        await state.resolveNewChatQuery()

        #expect(state.resolvedNewChatRecipient?.npub == "npub1alyce")
    }

    @MainActor
    @Test func staleNewChatRecipientLookupDoesNotReplaceCurrentResult() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let slowId = "1111111111111111111111111111111111111111111111111111111111111111"
        let fastId = "2222222222222222222222222222222222222222222222222222222222222222"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: "npub1sl0w", accountIdHex: slowId, npub: "npub1sl0w")
        runtime.installNormalizedMemberRef(query: "npub1fast", accountIdHex: fastId, npub: "npub1fast")
        runtime.installProfile(
            accountIdHex: slowId,
            profile: UserProfileMetadataFfi(
                name: "slow",
                displayName: "Slow Recipient",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installProfile(
            accountIdHex: fastId,
            profile: UserProfileMetadataFfi(
                name: "fast",
                displayName: "Fast Recipient",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.profileRefreshDelaysByAccountId[slowId] = 150_000_000
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1sl0w"
        let slowLookup = Task { @MainActor in
            await state.resolveNewChatQueryIfReady()
        }
        let slowLookupStarted = await waitFor {
            runtime.refreshedProfileIds.contains(slowId)
        }
        #expect(slowLookupStarted)

        state.newChatQuery = "npub1fast"
        await state.resolveNewChatQueryIfReady()
        await slowLookup.value

        #expect(state.resolvedNewChatRecipient?.accountIdHex == fastId)
        #expect(state.resolvedNewChatRecipient?.title == "Fast Recipient")
    }

    @MainActor
    @Test func newChatLookupQueryEditedMidFlightClearsSpinnerWithoutCommitting() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let slowId = "1111111111111111111111111111111111111111111111111111111111111111"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installNormalizedMemberRef(query: "npub1sl0w", accountIdHex: slowId, npub: "npub1sl0w")
        runtime.installProfile(
            accountIdHex: slowId,
            profile: UserProfileMetadataFfi(
                name: "slow",
                displayName: "Slow Recipient",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.profileRefreshDelaysByAccountId[slowId] = 150_000_000
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showNewChat()
        state.newChatQuery = "npub1sl0w"
        let slowLookup = Task { @MainActor in
            await state.resolveNewChatQueryIfReady()
        }
        let slowLookupStarted = await waitFor {
            runtime.refreshedProfileIds.contains(slowId)
        }
        #expect(slowLookupStarted)
        #expect(state.isResolvingNewChat)

        // Edit the query mid-flight WITHOUT starting a newer lookup: the in-flight
        // lookup still owns the generation, so when it resumes its defer must clear
        // the spinner (keyed on generation ownership) even though the stricter
        // generation+query commit guard now fails and blocks the stale result.
        state.newChatQuery = "npub1edyted"
        await slowLookup.value

        #expect(!state.isResolvingNewChat)
        #expect(state.resolvedNewChatRecipient == nil)
        #expect(state.lastError == nil)
    }

    // MARK: - User discovery (web-of-trust people search)

    @MainActor
    @Test func userDiscoveryAccumulatesAcrossUpdatesThenClearsTheSpinner() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        runtime.userSearchUpdates = [
            userSearchUpdate(.resultsFound(radius: 1), [searchResult(hex: "b", radius: 1)]),
            userSearchUpdate(.resultsFound(radius: 2), [searchResult(hex: "c", radius: 2)]),
            userSearchUpdate(.searchCompleted, []),
        ]
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        #expect(await pollUserDiscovery(until: { !state.isSearchingPeople && !state.discoveredPeople.isEmpty }))

        #expect(state.discoveredPeople.map(\.accountIdHex) == [discoveryHex("b"), discoveryHex("c")])
        #expect(state.discoveredPeople.map(\.accountIdHex) == sortedDiscoveryHexes(state.discoveredPeople))
        #expect(!state.discoveryIsPartial)
        #expect(!state.discoveryDidFail)
        // No unit test can prove the traversal reached a relay, so pin the arguments instead. Note
        // `searchUsers` takes an `accountIdHex` where almost every neighbouring call takes an
        // `accountRef`, and the radius window is 1...2 (0 is the searcher, excluded not searched).
        #expect(
            runtime.userSearchCalls == [
                FakeMarmotRuntime.UserSearchCall(
                    accountIdHex: discoverySearcherAccount.accountIdHex,
                    query: "al",
                    radiusStart: 1,
                    radiusEnd: 2
                )
            ]
        )
    }

    @MainActor
    @Test func userDiscoveryRendersProgressivelyWhileTheTraversalIsStillRunning() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        runtime.userSearchUpdates = [
            userSearchUpdate(.resultsFound(radius: 1), [searchResult(hex: "b", radius: 1)]),
            userSearchUpdate(.searchCompleted, []),
        ]
        runtime.userSearchUpdateDelayNanoseconds = 150_000_000
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        #expect(await pollUserDiscovery(until: { !state.discoveredPeople.isEmpty }))

        // The first batch is on screen while the search is still going: the spinner and results
        // coexist, and "No matches" must not have flashed in between.
        #expect(state.isSearchingPeople)
        #expect(state.discoveredPeople.count == 1)
        #expect(state.userDiscoveryStatus == .searching)
    }

    @MainActor
    @Test func userDiscoveryReSortsTheAggregateWhenALaterUpdateDeliversACloserPerson() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        // The far result arrives first. `newResults` is pre-sorted only *within* a batch, so a host
        // that sorts once at the end (or appends blindly) renders these in arrival order.
        runtime.userSearchUpdates = [
            userSearchUpdate(.resultsFound(radius: 2), [searchResult(hex: "z", radius: 2)]),
            userSearchUpdate(.resultsFound(radius: 1), [searchResult(hex: "a", radius: 1)]),
            userSearchUpdate(.searchCompleted, []),
        ]
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        #expect(await pollUserDiscovery(until: { state.discoveredPeople.count == 2 }))

        #expect(state.discoveredPeople.map(\.accountIdHex) == [discoveryHex("a"), discoveryHex("z")])
    }

    @MainActor
    @Test func userDiscoveryDebounceCoalescesRapidKeystrokesIntoOneTraversal() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        runtime.userSearchUpdates = [userSearchUpdate(.searchCompleted, [])]
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        for query in ["a", "al", "ali"] {
            state.newChatQuery = query
            state.scheduleUserDiscovery()
        }
        #expect(await pollUserDiscovery(until: { !state.isSearchingPeople }))

        #expect(runtime.userSearchCalls.count == 1)
        #expect(runtime.userSearchCalls.first?.query == "ali")
    }

    @MainActor
    @Test func userDiscoveryNeverTraversesForAnIdentifierOrEmptyQuery() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        runtime.userSearchUpdates = [
            userSearchUpdate(.resultsFound(radius: 1), [searchResult(hex: "b", radius: 1)]),
            userSearchUpdate(.searchCompleted, []),
        ]
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        // A real search first, so the "no traversal" assertions below cannot pass by accident.
        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        #expect(await pollUserDiscovery(until: { !state.discoveredPeople.isEmpty }))
        #expect(runtime.userSearchCalls.count == 1)

        // A pasted identifier already names one person: the resolver owns that branch, and a graph
        // traversal for it would be pure waste.
        state.newChatQuery = String(repeating: "f", count: 64)
        state.scheduleUserDiscovery()
        #expect(state.discoveredPeople.isEmpty)
        #expect(!state.isSearchingPeople)

        state.newChatQuery = "   "
        state.scheduleUserDiscovery()
        #expect(state.discoveredPeople.isEmpty)
        #expect(!state.isSearchingPeople)

        try await Task.sleep(for: .milliseconds(500))
        #expect(runtime.userSearchCalls.count == 1)
    }

    @MainActor
    @Test func userDiscoveryDropsSupersededUpdatesWithoutStrandingTheSpinner() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        runtime.userSearchUpdates = [
            userSearchUpdate(.resultsFound(radius: 2), [searchResult(hex: "z", radius: 2)]),
            userSearchUpdate(.resultsFound(radius: 1), [searchResult(hex: "a", radius: 1)]),
            userSearchUpdate(.searchCompleted, []),
        ]
        runtime.userSearchUpdateDelayNanoseconds = 150_000_000
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        #expect(await pollUserDiscovery(until: { state.discoveredPeople.count == 1 }))

        // Edit the query mid-stream *without* resubmitting, exactly as typing another character
        // does before the view's `.task(id:)` fires.
        state.newChatQuery = "alx"
        try await Task.sleep(for: .milliseconds(500))

        #expect(state.discoveredPeople.count == 1, "the superseded search's later update must not land")
        #expect(state.discoveredPeopleForCurrentQuery.isEmpty, "old results must not render under a new query")
        // Spinner ownership is keyed on the generation alone, so abandoning mid-stream still clears
        // it. This is the shape of #110 and #255.
        #expect(!state.isSearchingPeople)
    }

    @MainActor
    @Test func userDiscoveryReleasesAnAbandonedSubscriptionWithoutDrainingIt() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        runtime.userSearchUpdates = [
            userSearchUpdate(.resultsFound(radius: 1), [searchResult(hex: "b", radius: 1)]),
            userSearchUpdate(.resultsFound(radius: 2), [searchResult(hex: "c", radius: 2)]),
            userSearchUpdate(.searchCompleted, []),
        ]
        runtime.userSearchUpdateDelayNanoseconds = 150_000_000
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        #expect(await pollUserDiscovery(until: { state.discoveredPeople.count == 1 }))

        state.invalidateUserDiscovery()
        try await Task.sleep(for: .milliseconds(600))

        // Dropping the subscription is what cancels the relay traversal. Looping on to
        // `searchCompleted` instead would keep a traversal alive for a query nobody is looking at,
        // and this counter is the only observable consequence of getting it wrong. Three updates are
        // scripted; one call fetched the first and one more was in flight when the search was
        // abandoned, so a host that drained instead of releasing would reach 3 or 4.
        #expect(
            runtime.userSearchNextUpdateCount <= 2,
            "abandoned search must be released, not drained to searchCompleted"
        )
        #expect(state.discoveredPeople.isEmpty)
        #expect(!state.isSearchingPeople)
    }

    @MainActor
    @Test func userDiscoveryLandsNoResultsUnderANewlySwitchedAccount() async throws {
        let secondary = AccountSummaryFfi(
            label: "Secondary Account",
            accountIdHex: String(repeating: "7", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount, secondary])
        runtime.userSearchUpdates = [
            userSearchUpdate(.resultsFound(radius: 1), [searchResult(hex: "b", radius: 1)]),
            userSearchUpdate(.searchCompleted, []),
        ]
        runtime.userSearchUpdateDelayNanoseconds = 250_000_000
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        try await Task.sleep(for: .milliseconds(350))
        let target = try #require(state.accounts.first { $0.accountIdHex == secondary.accountIdHex })
        state.selectAccount(target)
        try await Task.sleep(for: .milliseconds(600))

        #expect(state.activeAccountId == target.id)
        #expect(state.discoveredPeople.isEmpty)
        #expect(!state.isSearchingPeople)
    }

    @MainActor
    @Test func userDiscoveryRadiusTimeoutKeepsResultsAndReportsPartialNotFailed() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        runtime.userSearchUpdates = [
            userSearchUpdate(.resultsFound(radius: 1), [searchResult(hex: "b", radius: 1)]),
            userSearchUpdate(.radiusTimeout(radius: 2), []),
            userSearchUpdate(.searchCompleted, []),
        ]
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        #expect(await pollUserDiscovery(until: { !state.isSearchingPeople }))

        // A timeout (or truncation) is partial, not failed: everything already delivered is correct.
        #expect(state.discoveredPeople.count == 1)
        #expect(state.discoveryIsPartial)
        #expect(!state.discoveryDidFail)
        #expect(state.userDiscoveryStatus == .partial)
    }

    @MainActor
    @Test func userDiscoveryErrorTriggerReportsFailureAndKeepsDeliveredResults() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        runtime.userSearchUpdates = [
            userSearchUpdate(.resultsFound(radius: 1), [searchResult(hex: "b", radius: 1)]),
            userSearchUpdate(.error(message: "relay unreachable"), []),
            userSearchUpdate(.searchCompleted, []),
        ]
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        #expect(await pollUserDiscovery(until: { !state.isSearchingPeople }))

        // `error` is always followed by `searchCompleted`, so the loop keeps going and the failure
        // is reported only once the search actually ends — never alongside a live spinner.
        #expect(state.discoveredPeople.count == 1)
        #expect(state.discoveryDidFail)
        #expect(state.userDiscoveryStatus == .failed)
    }

    @MainActor
    @Test func userDiscoverySearchUsersThrowReportsFailureAndClearsTheSpinner() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        runtime.searchUsersError = FakeMarmotRuntimeError.unused
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        #expect(await pollUserDiscovery(until: { state.discoveryDidFail }))

        #expect(!state.isSearchingPeople)
        #expect(state.discoveredPeople.isEmpty)
        #expect(state.userDiscoveryStatus == .failed)
    }

    @MainActor
    @Test func userDiscoveryNeverRendersTheSearcherAndNeverPromotesResults() async throws {
        let runtime = FakeMarmotRuntime(accounts: [discoverySearcherAccount])
        runtime.userSearchUpdates = [
            userSearchUpdate(
                .resultsFound(radius: 1),
                [
                    // The searcher matching their own query must never render.
                    searchResult(hex: discoverySearcherAccount.accountIdHex, radius: 1),
                    searchResult(hex: "b", radius: 1),
                ]
            ),
            userSearchUpdate(.searchCompleted, []),
        ]
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let profileLookups = ProfileLookupLog()
        runtime.onUserProfileLookup = { profileLookups.record($0) }
        runtime.clearRefreshedProfileIds()
        state.newChatQuery = "al"
        state.scheduleUserDiscovery()
        #expect(await pollUserDiscovery(until: { !state.isSearchingPeople }))

        let rendered = state.composeSearchResults(matching: "al")
        #expect(rendered.discovered.map(\.accountIdHex) == [discoveryHex("b")])

        // A search result is not a relationship: `user_profile` must keep answering only for
        // accounts the user has actually interacted with. The tempting implementation (routing rows
        // through `resolveNewChatRecipient`) refreshes the profile over the network and invalidates
        // the cache — i.e. it promotes the stranger — so assert on the runtime's own call log.
        #expect(state.composeContacts.isEmpty)
        #expect(rendered.known.isEmpty)
        #expect(!runtime.refreshedProfileIds.contains(discoveryHex("b")))
        #expect(!profileLookups.recorded.contains(discoveryHex("b")))
        #expect(state.peerProfileFFICache[discoveryHex("b")] == nil)
    }
}
