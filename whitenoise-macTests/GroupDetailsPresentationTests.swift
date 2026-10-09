//
//  GroupDetailsPresentationTests.swift
//  whitenoise-macTests
//
//  The decisions group info makes before it draws anything: which members the roster shows,
//  what the reader may edit, and how a custom disappearing timer parses.
//

import Foundation
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
struct SharedMediaStripPreviewTests {
    @Test func theStripCarriesTheNewestNineInHistoryOrder() {
        #expect(SharedMediaStripPreview.visible(Array(1...40)) == Array(1...9))
        #expect(SharedMediaStripPreview.visible([3, 1, 2]) == [3, 1, 2])
    }
}

@MainActor
struct SharedMediaViewerPresentationTests {
    private func entry(
        _ messageIdHex: String,
        category: AttachmentCategoryFfi = .image,
        rejected: Bool = false
    ) -> RetainedAttachmentItem {
        let outcome: MediaAttachmentOutcomeFfi =
            rejected
            ? .rejected(
                attachmentIndex: 0,
                rejection: MediaAttachmentRejectionFfi(kind: .unsupportedFormat, detail: "future format"))
            : .accepted(
                attachmentIndex: 0,
                reference: mediaAttachmentReference(mediaType: "image/jpeg", fileName: "\(messageIdHex).jpg"))
        return RetainedAttachmentItem(
            entry: AttachmentEntryFfi(
                messageIdHex: messageIdHex,
                sourceMessageIdHex: messageIdHex,
                sender: "alice",
                timelineAt: 10,
                receivedAt: 10,
                sourceEpoch: 0,
                category: category,
                attachment: outcome
            )
        )
    }

    @Test func theViewerPagesEveryLoadedItemNotOnlyTheStrip() throws {
        let items = (1...20).map { entry("m\($0)") }

        let viewer = try #require(SharedMediaViewerPresentation(items: items, initial: items[14]))

        #expect(viewer.items.count == 20)
        #expect(viewer.initialIndex == 14)
    }

    @Test func itemsTheViewerCannotShowAreSkippedAndTheIndexFollows() throws {
        let rejected = entry("broken", category: .rejected, rejected: true)
        let file = entry("doc", category: .file)
        let photo = entry("photo")
        let video = entry("clip", category: .video)

        let viewer = try #require(
            SharedMediaViewerPresentation(items: [rejected, file, photo, video], initial: video))

        #expect(viewer.items.map(\.id) == [photo.id, video.id])
        #expect(viewer.initialIndex == 1)
        #expect(SharedMediaViewerPresentation(items: [rejected, photo], initial: rejected) == nil)
    }
}

@MainActor
struct SharedMediaMonthGroupingTests {
    private struct Tile: Identifiable {
        let id: String
        let timestamp: UInt64
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // 2026-09-15, 2026-09-02 and 2026-08-20, all at noon UTC.
    private let midSeptember: UInt64 = 1_789_473_600
    private let earlySeptember: UInt64 = 1_788_350_400
    private let lateAugust: UInt64 = 1_787_227_200

    @Test func consecutiveItemsOfOneMonthShareASection() {
        let sections = SharedMediaMonthGrouping.sections(
            [
                Tile(id: "a", timestamp: midSeptember),
                Tile(id: "b", timestamp: earlySeptember),
                Tile(id: "c", timestamp: lateAugust),
            ],
            timestamp: \.timestamp,
            calendar: utc,
            locale: Locale(identifier: "en_US")
        )

        #expect(sections.map(\.title) == ["September 2026", "August 2026"])
        #expect(sections.map { $0.items.map(\.id) } == [["a", "b"], ["c"]])
    }

    @Test func aMonthThatRecursAfterAnotherStaysInHistoryOrder() {
        let sections = SharedMediaMonthGrouping.sections(
            [
                Tile(id: "a", timestamp: midSeptember),
                Tile(id: "b", timestamp: lateAugust),
                Tile(id: "c", timestamp: earlySeptember),
            ],
            timestamp: \.timestamp,
            calendar: utc,
            locale: Locale(identifier: "en_US")
        )

        #expect(sections.map { $0.items.map(\.id) } == [["a"], ["b"], ["c"]])
        #expect(Set(sections.map(\.id)).count == 3)
    }

    @Test func undatedItemsLandUnderRecent() {
        let sections = SharedMediaMonthGrouping.sections(
            [Tile(id: "a", timestamp: 0), Tile(id: "b", timestamp: 0)],
            timestamp: \.timestamp,
            calendar: utc,
            locale: Locale(identifier: "en_US")
        )

        #expect(sections.count == 1)
        #expect(sections.first?.title == L10n.string("Recent"))
        #expect(sections.first?.items.count == 2)
    }

    @Test func theTitleFollowsTheAppLocale() {
        let sections = SharedMediaMonthGrouping.sections(
            [Tile(id: "a", timestamp: midSeptember)],
            timestamp: \.timestamp,
            calendar: utc,
            locale: Locale(identifier: "es")
        )

        #expect(sections.first?.title.lowercased() == "septiembre de 2026")
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
        profileName: publishedDisplayName ?? displayName,
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
