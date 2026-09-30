//
//  GroupDetailsPresentationTests.swift
//  whitenoise-macTests
//
//  The decisions group info makes before it draws anything: which members the roster shows,
//  what the reader may edit, and how a custom disappearing timer parses.
//

import MarmotKit
import Testing

@testable import whitenoise_mac

@MainActor
struct GroupMemberListTests {
    @Test func aShortRosterShowsEveryoneWithoutSearch() {
        let list = GroupMemberList(members: members(count: GroupMemberList.previewCount))

        #expect(!list.showsSearchField)
        #expect(list.visible.count == GroupMemberList.previewCount)
        #expect(!list.isTruncated)
    }

    @Test func aLongRosterPreviewsSixUntilExpanded() {
        var list = GroupMemberList(members: members(count: 9))

        #expect(list.showsSearchField)
        #expect(list.visible.map(\.id) == (1...6).map { "member-\($0)" })
        #expect(list.isTruncated)

        list.isExpanded = true
        #expect(list.visible.count == 9)
        #expect(!list.isTruncated)
    }

    @Test func searchShowsEveryMatchEvenWhenCollapsed() {
        // All twelve match — twice the preview — and a search never cuts its results short.
        let list = GroupMemberList(members: members(count: 12), query: "member")

        #expect(list.isSearching)
        #expect(list.visible.count == 12)
        #expect(!list.isTruncated)
    }

    @Test func searchMatchesPublishedNameAndNpubCaseInsensitively() {
        let nicknamed = member(id: "a", displayName: "Bestie", publishedDisplayName: "Alice Liddell")
        let byKey = member(id: "b", displayName: "Bob", npub: "npub1xyzbob")
        let other = member(id: "c", displayName: "Carol")
        let roster = [nicknamed, byKey, other]

        #expect(GroupMemberList(members: roster, query: "alice").matching.map(\.id) == ["a"])
        #expect(GroupMemberList(members: roster, query: "XYZ").matching.map(\.id) == ["b"])
        #expect(GroupMemberList(members: roster, query: "zzz").visible.isEmpty)
    }

    @Test func aBlankQueryIsNotASearch() {
        let list = GroupMemberList(members: members(count: 9), query: "   ")

        #expect(!list.isSearching)
        #expect(list.visible.count == GroupMemberList.previewCount)
    }

    private func members(count: Int) -> [GroupMemberItem] {
        (1...count).map { member(id: "member-\($0)", displayName: "member-\($0)") }
    }
}

@MainActor
struct SharedMediaGridPreviewTests {
    @Test func aShortGridShowsEveryTileWithNoExpander() {
        let grid = SharedMediaGridPreview(items: Array(1...SharedMediaGridPreview<Int>.previewCount))

        #expect(grid.visible.count == 9)
        #expect(!grid.isTruncated)
        #expect(!grid.canCollapse)
    }

    @Test func aLongGridPreviewsNineUntilExpandedAndCollapsesBack() {
        var grid = SharedMediaGridPreview(items: Array(1...40))

        #expect(grid.visible == Array(1...9))
        #expect(grid.isTruncated)
        #expect(!grid.canCollapse)

        grid.isExpanded = true
        #expect(grid.visible.count == 40)
        #expect(!grid.isTruncated)
        #expect(grid.canCollapse)
    }

    @Test func loadMoreWaitsUntilEveryLoadedTileIsShown() {
        var grid = SharedMediaGridPreview(items: Array(1...12))

        #expect(!grid.showsLoadMore(hasMore: true))

        grid.isExpanded = true
        #expect(grid.showsLoadMore(hasMore: true))
        #expect(!grid.showsLoadMore(hasMore: false))

        // A grid too short to truncate pages in older history straight away.
        #expect(SharedMediaGridPreview(items: [1, 2]).showsLoadMore(hasMore: true))
    }
}

@MainActor
struct GroupDetailsPermissionsTests {
    @Test func theCoreCapabilityDecidesEditingOverTheAdminFlag() {
        let admin = snapshot(isSelfAdmin: true)

        let refused = GroupDetailsPermissions(
            snapshot: admin, capabilities: capabilities(canEditGroup: false), isDirect: false)
        #expect(!refused.canEditGroup)
        #expect(!refused.canEditProfile)

        let granted = GroupDetailsPermissions(
            snapshot: snapshot(isSelfAdmin: false), capabilities: capabilities(canEditGroup: true), isDirect: false)
        #expect(granted.canEditGroup)
        #expect(granted.canEditProfile)
    }

    @Test func theAdminFlagStandsInUntilTheHeaderLoads() {
        #expect(
            GroupDetailsPermissions(snapshot: snapshot(isSelfAdmin: true), capabilities: nil, isDirect: false)
                .canEditGroup)
        #expect(
            !GroupDetailsPermissions(snapshot: snapshot(isSelfAdmin: false), capabilities: nil, isDirect: false)
                .canEditGroup)
    }

    @Test func aDirectChatNeverOffersAProfileEdit() {
        // In mdk a name makes a conversation a group, so a renamed DM would stop being one.
        let permissions = GroupDetailsPermissions(
            snapshot: snapshot(isSelfAdmin: true), capabilities: capabilities(canEditGroup: true), isDirect: true)

        #expect(permissions.canEditGroup)
        #expect(!permissions.canEditProfile)
        #expect(!permissions.showsAdminOnlyNote)
    }

    @Test func aFormerMemberCanChangeNothingAndIsToldNothingAboutAdmins() {
        let permissions = GroupDetailsPermissions(
            snapshot: snapshot(isSelfAdmin: true, canInvite: true, membership: .removed),
            capabilities: capabilities(canEditGroup: true),
            isDirect: false
        )

        #expect(!permissions.canEditGroup)
        #expect(!permissions.canInvite)
        #expect(!permissions.showsAdminOnlyNote)
    }

    @Test func aMemberWhoCannotInviteIsToldWhy() {
        let permissions = GroupDetailsPermissions(
            snapshot: snapshot(isSelfAdmin: false, canInvite: false), capabilities: nil, isDirect: false)

        #expect(!permissions.canInvite)
        #expect(permissions.showsAdminOnlyNote)
    }

    private func snapshot(
        isSelfAdmin: Bool,
        canInvite: Bool = false,
        membership: ChatSelfMembership = .member
    ) -> GroupDetailsSnapshot {
        GroupDetailsSnapshot(
            groupIdHex: "group",
            endpoint: "",
            name: "Planning",
            customName: "Planning",
            description: "",
            avatarURL: nil,
            sanitizedAvatarURL: nil,
            avatarDimension: nil,
            nostrGroupIdHex: "",
            relays: [],
            adminIds: [],
            archived: false,
            pendingConfirmation: false,
            selfMembership: membership,
            members: [],
            isSelfAdmin: isSelfAdmin,
            isLastAdmin: false,
            canInvite: canInvite,
            canLeave: true,
            requiresSelfDemoteBeforeLeave: false,
            disappearingMessageSecs: 0
        )
    }

    private func capabilities(canEditGroup: Bool) -> ConversationCapabilitiesFfi {
        ConversationCapabilitiesFfi(
            participation: .active,
            isSelfAdmin: canEditGroup,
            isLastAdmin: false,
            canSend: true,
            canInvite: false,
            canEditGroup: canEditGroup,
            canLeave: true,
            requiresSelfDemoteBeforeLeave: false,
            canEnableDisbanding: false,
            canDisband: false
        )
    }
}

struct DisappearingCustomDurationTests {
    @Test func opensOnTheLargestWholeUnitOfTheCurrentTimer() {
        let fourWeeks = DisappearingCustomDuration(seconds: 4 * 604_800)
        #expect(fourWeeks.text == "4")
        #expect(fourWeeks.unit == .weeks)

        let off = DisappearingCustomDuration(seconds: 0)
        #expect(off.text == "1")
        #expect(off.unit == .days)
    }

    @Test func rejectsWhatIsNotAPositiveWholeCount() {
        for text in ["", "0", "-1", "1.5", "abc"] {
            var duration = DisappearingCustomDuration(seconds: 0)
            duration.text = text
            #expect(duration.seconds == nil, "\(text)")
        }
    }

    @Test func rejectsATotalThatOverflowsRatherThanClamping() {
        var duration = DisappearingCustomDuration(seconds: 0)
        duration.text = String(UInt64.max)
        duration.unit = .weeks
        #expect(duration.seconds == nil)

        duration.unit = .seconds
        #expect(duration.seconds == UInt64.max)
    }

    @Test func stepsSaturateAtTheirBounds() {
        var duration = DisappearingCustomDuration(seconds: 0)
        duration.decrement()
        #expect(duration.text == "1")

        duration.text = String(UInt64.max)
        duration.increment()
        #expect(duration.text == String(UInt64.max))

        duration.text = "7"
        duration.increment()
        #expect(duration.text == "8")
    }
}

@MainActor
private func member(
    id: String,
    displayName: String,
    publishedDisplayName: String? = nil,
    npub: String? = nil
) -> GroupMemberItem {
    GroupMemberItem(
        id: id,
        displayName: displayName,
        publishedDisplayName: publishedDisplayName,
        npub: npub ?? "npub1\(id)",
        accountLabel: nil,
        isLocal: false,
        isAdmin: false,
        isSelf: false,
        canRemove: false,
        canPromote: false,
        canDemote: false
    )
}
