import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Settings → Storage → Manage Storage, ported from whitenoise-ios#1200: how MDK's storage figures
/// read, which cutoff a removal confirmation names, and largest-first paging.
@MainActor
struct ManageStoragePresentationTests {
    private static func usage(
        media: UInt64 = 0, legacy: UInt64 = 0, count: UInt64 = 0,
        database: UInt64 = 0, databaseFree: UInt64 = 0,
        migration: AttachmentMigrationStateFfi = .notNeeded,
        migrationBytes: UInt64 = 0, cache: UInt64 = 0
    ) -> AttachmentStorageUsageFfi {
        AttachmentStorageUsageFfi(
            mediaBytes: media, legacyBytes: legacy, attachmentCount: count,
            databaseBytes: database, databaseFreeBytes: databaseFree,
            migration: migration, migrationBytes: migrationBytes, cacheBytes: cache)
    }

    static func attachment(
        group: String = "g1", message: String = "m1", source: String = "s1",
        index: UInt32 = 0, bytes: UInt64 = 1_024, mediaType: String = "image/jpeg",
        fileName: String = "beach.jpg", receivedAt: UInt64 = 0
    ) -> RetainedAttachmentSummaryFfi {
        RetainedAttachmentSummaryFfi(
            groupIdHex: group,
            target: AttachmentLocalTargetFfi(messageIdHex: message, sourceMessageIdHex: source, attachmentIndex: index),
            byteCount: bytes, mediaType: mediaType, fileName: fileName, receivedAt: receivedAt
        )
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static var losAngeles: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private static func midnight(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: Usage

    /// Attachments live in both layouts until the background move finishes, so both count as
    /// attachments; the legacy part is not counted again as chat data.
    @Test func attachmentsCountBothLayoutsAndChatDataExcludesLegacyBodies() {
        let usage = ManageStoragePresentation.Usage(
            Self.usage(media: 700, legacy: 300, count: 12, database: 1_000, cache: 50))
        #expect(usage.attachmentBytes == 1_000)
        #expect(usage.attachmentCount == 12)
        #expect(usage.chatDataBytes == 700)
        #expect(usage.cacheBytes == 50)
    }

    @Test func figuresNeverWrapAround() {
        let usage = ManageStoragePresentation.Usage(Self.usage(media: .max, legacy: 10, database: 5))
        #expect(usage.attachmentBytes == .max)
        #expect(usage.chatDataBytes == 0)
    }

    @Test func onlyUnfinishedMigrationStatesShowANotice() {
        #expect(ManageStoragePresentation.migrationNotice(.notNeeded, bytes: 0) == nil)
        #expect(ManageStoragePresentation.migrationNotice(.complete, bytes: 0) == nil)
        #expect(ManageStoragePresentation.migrationNotice(.running, bytes: 4_096) == .moving(remainingBytes: 4_096))
        #expect(ManageStoragePresentation.migrationNotice(.paused, bytes: 9_000) == .paused(neededBytes: 9_000))
        #expect(ManageStoragePresentation.migrationNotice(.compacting, bytes: 0) == .compacting)
        #expect(
            ManageStoragePresentation.Usage(Self.usage(migration: .paused, migrationBytes: 77)).migration
                == .paused(neededBytes: 77))
    }

    /// MDK rechecks free space for a paused move on its 15-second tick, so a paused move can
    /// resume without anything happening on this page.
    @Test func usageIsReReadWhileItCanChangeOnItsOwn() {
        #expect(ManageStoragePresentation.usageRefreshDelay(for: .moving(remainingBytes: 1)) == .seconds(15))
        #expect(ManageStoragePresentation.usageRefreshDelay(for: .paused(neededBytes: 1)) == .seconds(15))
        #expect(ManageStoragePresentation.usageRefreshDelay(for: .compacting) == .seconds(2))
        #expect(ManageStoragePresentation.usageRefreshDelay(for: nil) == nil)
    }

    @Test func pausedMoveKeepsPollingUntilItResumesAndFinishes() {
        var refresh = ManageStoragePresentation.UsageRefresh()
        #expect(refresh.nextDelay == nil)

        refresh.succeeded(.init(Self.usage(migration: .paused, migrationBytes: 9_000)))
        #expect(refresh.usage?.migration == .paused(neededBytes: 9_000))
        #expect(refresh.nextDelay == .seconds(15))

        refresh.succeeded(.init(Self.usage(migration: .running, migrationBytes: 4_000)))
        #expect(refresh.usage?.migration == .moving(remainingBytes: 4_000))
        #expect(refresh.nextDelay == .seconds(15))

        refresh.succeeded(.init(Self.usage(migration: .complete)))
        #expect(refresh.usage?.migration == nil)
        #expect(refresh.nextDelay == nil)
    }

    /// A failed read keeps the last figures but says so, and the poll goes on because those
    /// figures were still changing.
    @Test func failedRefreshKeepsPollingAndIsShownUntilAReadSucceeds() {
        var refresh = ManageStoragePresentation.UsageRefresh()
        refresh.succeeded(.init(Self.usage(media: 10, migration: .running, migrationBytes: 4_000)))
        let revision = refresh.revision

        refresh.failedToRefresh()
        #expect(refresh.failed)
        #expect(refresh.revision != revision)
        #expect(refresh.usage?.attachmentBytes == 10)
        #expect(refresh.nextDelay == .seconds(15))

        refresh.failedToRefresh()
        refresh.succeeded(.init(Self.usage(media: 10, migration: .compacting)))
        #expect(!refresh.failed)
        #expect(refresh.nextDelay == .seconds(2))
    }

    @Test func failedFirstReadHasNothingToPoll() {
        var refresh = ManageStoragePresentation.UsageRefresh()
        refresh.failedToRefresh()
        #expect(refresh.failed)
        #expect(refresh.usage == nil)
        #expect(refresh.nextDelay == nil)
    }

    // MARK: Removal ages

    /// Cutoffs start the named day, so attachments received on it stay.
    @Test func removalCutoffsStartTheNamedDay() {
        let calendar = Self.losAngeles
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 21, minute: 30))!
        typealias Age = ManageStoragePresentation.RemovalAge
        #expect(Age.oneWeek.cutoffDate(now: now, calendar: calendar) == Self.midnight(2026, 3, 24, in: calendar))
        #expect(Age.oneMonth.cutoffDate(now: now, calendar: calendar) == Self.midnight(2026, 2, 28, in: calendar))
        #expect(Age.threeMonths.cutoffDate(now: now, calendar: calendar) == Self.midnight(2025, 12, 31, in: calendar))
        #expect(Age.sixMonths.cutoffDate(now: now, calendar: calendar) == Self.midnight(2025, 9, 30, in: calendar))
        #expect(Age.oneYear.cutoffDate(now: now, calendar: calendar) == Self.midnight(2025, 3, 31, in: calendar))
    }

    /// The confirmation's day and the instant passed to MDK come from one capture, late in the
    /// evening and across a daylight-saving change alike.
    @Test func capturedCutoffNamesTheInstantItRemovesBefore() {
        let calendar = Self.losAngeles
        let locale = Locale(identifier: "en_US")
        let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 23, minute: 59))!
        let cutoff = ManageStoragePresentation.RemovalCutoff(age: .oneWeek, now: lateEvening, calendar: calendar)
        #expect(cutoff.text(locale: locale) == "October 15, 2026")
        #expect(cutoff.receivedBefore == UInt64(Self.midnight(2026, 10, 15, in: calendar).timeIntervalSince1970))

        let afterSpringForward = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 21))!
        let acrossChange = ManageStoragePresentation.RemovalCutoff(
            age: .oneWeek, now: afterSpringForward, calendar: calendar)
        #expect(acrossChange.text(locale: locale) == "March 5, 2026")
        let removedBefore = Date(timeIntervalSince1970: TimeInterval(acrossChange.receivedBefore))
        #expect(
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: removedBefore)
                == DateComponents(year: 2026, month: 3, day: 5, hour: 0, minute: 0))
    }

    @Test func receivedBeforeIsNeverNegative() {
        let cutoff = ManageStoragePresentation.RemovalCutoff(
            age: .oneYear, now: Date(timeIntervalSince1970: 0), calendar: Self.utc)
        #expect(cutoff.receivedBefore == 0)
    }

    @Test func everyAgeHasItsOwnTitle() {
        let titles = ManageStoragePresentation.RemovalAge.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    // MARK: Attachment rows

    /// Identity follows the original message and slot, so pages and removals never collapse two
    /// attachments of one message.
    @Test func attachmentIDKeepsMessageAndSlotIdentity() {
        let first = ManageStoragePresentation.attachmentID(Self.attachment(index: 0))
        let second = ManageStoragePresentation.attachmentID(Self.attachment(index: 1))
        let otherSource = ManageStoragePresentation.attachmentID(Self.attachment(source: "s2"))
        let otherChat = ManageStoragePresentation.attachmentID(Self.attachment(group: "g2"))
        #expect(Set([first, second, otherSource, otherChat]).count == 4)
        #expect(first == ManageStoragePresentation.attachmentID(Self.attachment(bytes: 99, fileName: "renamed.jpg")))
    }

    @Test func titleSanitizesPeerFileNames() {
        let title = ManageStoragePresentation.attachmentTitle(Self.attachment(fileName: "  trip\n\u{202E}gpj.exe  "))
        #expect(!title.contains("\n"))
        #expect(!title.contains("\u{202E}"))
        #expect(title.hasPrefix("trip"))
    }

    @Test func blankFileNamesFallBackToTheKind() {
        #expect(
            ManageStoragePresentation.attachmentTitle(Self.attachment(mediaType: "image/png", fileName: " "))
                == L10n.string("Photo"))
        #expect(
            ManageStoragePresentation.attachmentTitle(Self.attachment(mediaType: "video/mp4", fileName: ""))
                == L10n.string("Video"))
        #expect(
            ManageStoragePresentation.attachmentTitle(Self.attachment(mediaType: "audio/mp4", fileName: ""))
                == L10n.string("Audio"))
        #expect(
            ManageStoragePresentation.attachmentTitle(Self.attachment(mediaType: "", fileName: ""))
                == L10n.string("Attachment"))
    }

    @Test func subtitleLeadsWithTheChatOnlyWhenGiven() {
        let locale = Locale(identifier: "en_US")
        let received = Self.attachment(receivedAt: 1_800_000_000)
        let dateOnly = ManageStoragePresentation.attachmentSubtitle(received, chatTitle: nil, locale: locale)
        #expect(!dateOnly.isEmpty)
        #expect(
            ManageStoragePresentation.attachmentSubtitle(received, chatTitle: "Hiking", locale: locale)
                == "Hiking · \(dateOnly)")
        #expect(
            ManageStoragePresentation.attachmentSubtitle(
                Self.attachment(receivedAt: 0), chatTitle: "Hiking", locale: locale) == "Hiking")
        #expect(
            ManageStoragePresentation.attachmentSubtitle(Self.attachment(receivedAt: 0), chatTitle: nil, locale: locale)
                .isEmpty)
    }

    // MARK: Paging

    @Test func pageListAsksForTheFirstPageThenFollowsTheCursor() {
        var list = StoragePageList<String, Int>(id: { $0 })
        #expect(list.hasMore)
        #expect(list.cursor == nil)

        list.append(["a", "b"], next: 1)
        #expect(list.items == ["a", "b"])
        #expect(list.cursor == 1)
        #expect(list.hasMore)

        list.append(["c"], next: nil)
        #expect(list.items == ["a", "b", "c"])
        #expect(!list.hasMore)
    }

    /// MDK may end with an empty page; it still counts so a visible load-more row asks again or
    /// stops.
    @Test func emptyPagesAdvanceAndEndTheListing() {
        var list = StoragePageList<String, Int>(id: { $0 })
        list.append(["a"], next: 1)
        list.append([], next: 2)
        #expect(list.pageCount == 2)
        #expect(list.hasMore)
        list.append([], next: nil)
        #expect(list.pageCount == 3)
        #expect(!list.hasMore)
        #expect(list.items == ["a"])
    }

    @Test func pageListKeepsTheFirstCopyOfARepeatedItem() {
        var list = StoragePageList<(id: String, size: Int), Int>(id: { $0.id })
        list.append([("a", 3), ("b", 2)], next: 1)
        list.append([("b", 1), ("c", 1)], next: nil)
        #expect(list.items.map(\.id) == ["a", "b", "c"])
        #expect(list.items[1].size == 2)
    }
}

/// The page's model against a fake core: every figure and listing is read through MDK, and any
/// removal starts every listing over and tells the shell its decrypted copies are stale.
@MainActor
struct ManageStorageViewModelTests {
    private final class Recorder {
        var attachmentsDidChangeCount = 0
    }

    private static func model(
        _ runtime: FakeMarmotRuntime,
        chatList: ChatListViewModel? = nil,
        recorder: Recorder = Recorder()
    ) -> ManageStorageViewModel {
        ManageStorageViewModel(
            accountRef: "account",
            activeAccountIdHex: String(repeating: "f", count: 64),
            runtime: runtime,
            chatList: chatList,
            attachmentsDidChange: { recorder.attachmentsDidChangeCount += 1 }
        )
    }

    private static func attachment(_ group: String, _ message: String, receivedAt: UInt64 = 1)
        -> RetainedAttachmentSummaryFfi
    {
        ManageStoragePresentationTests.attachment(
            group: group, message: message, source: message, receivedAt: receivedAt)
    }

    @Test func loadReadsUsageAndTheFirstPageOfChats() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentStorageUsageResult = AttachmentStorageUsageFfi(
            mediaBytes: 300, legacyBytes: 0, attachmentCount: 2, databaseBytes: 40, databaseFreeBytes: 0,
            migration: .running, migrationBytes: 99, cacheBytes: 7)
        runtime.chatStorageUsage = [
            ChatAttachmentUsageFfi(groupIdHex: "big", bytes: 200, attachmentCount: 1),
            ChatAttachmentUsageFfi(groupIdHex: "small", bytes: 100, attachmentCount: 1),
        ]
        let model = Self.model(runtime)

        await model.load()

        #expect(model.usage?.attachmentBytes == 300)
        #expect(model.usage?.cacheBytes == 7)
        #expect(model.usage?.migration == .moving(remainingBytes: 99))
        #expect(model.chats.items.map(\.groupIdHex) == ["big", "small"])
        #expect(!model.chats.hasMore)
        #expect(model.chatUsage("small")?.bytes == 100)
    }

    @Test func aFailedUsageReadIsShownRatherThanHidden() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentStorageUsageError = MarmotKitError.Io(details: "busy")
        let model = Self.model(runtime)

        await model.load()

        #expect(model.usage == nil)
        #expect(model.usageRefresh.failed)
    }

    @Test func accountAndChatListingsAreReadSeparately() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.retainedAttachmentSummaries = [Self.attachment("g1", "m1"), Self.attachment("g2", "m2")]
        let model = Self.model(runtime)
        await model.load()

        await model.loadMoreAttachments(.account)
        await model.loadMoreAttachments(.chat("g2"))

        #expect(model.attachmentPages(.account).items.count == 2)
        #expect(model.attachmentPages(.chat("g2")).items.map(\.groupIdHex) == ["g2"])
        #expect(runtime.largestRetainedAttachmentReads == [nil, "g2"])
    }

    @Test func removingAChatsAttachmentsStartsEveryListingOver() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.chatStorageUsage = [ChatAttachmentUsageFfi(groupIdHex: "g1", bytes: 10, attachmentCount: 1)]
        runtime.retainedAttachmentSummaries = [Self.attachment("g1", "m1")]
        let recorder = Recorder()
        let model = Self.model(runtime, recorder: recorder)
        await model.load()
        await model.loadMoreAttachments(.chat("g1"))
        let epoch = model.epoch

        await model.removeAllAttachments(inChat: "g1")

        #expect(runtime.removedChatAttachmentGroups == ["g1"])
        #expect(recorder.attachmentsDidChangeCount == 1)
        #expect(model.epoch != epoch)
        #expect(model.chats.items.isEmpty)
        // The old listing is gone; a visible row asks for its first page again.
        #expect(model.attachmentPages(.chat("g1")).pageCount == 0)
        #expect(model.failedOperation == nil)
        #expect(model.operation == nil)
    }

    /// The instant the confirmation named is the one MDK removes before.
    @Test func removeOlderPassesTheCapturedCutoff() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = Self.model(runtime)
        let cutoff = ManageStoragePresentation.RemovalCutoff(
            age: .oneMonth, now: Date(timeIntervalSince1970: 1_800_000_000), calendar: .current)

        await model.removeOlder(than: cutoff, in: .chat("g1"))
        await model.removeOlder(than: cutoff, in: .account)

        let cutoffs = runtime.removedAttachmentsOlderThan.map(\.receivedBefore)
        #expect(cutoffs == [cutoff.receivedBefore, cutoff.receivedBefore])
        #expect(runtime.removedAttachmentsOlderThan.map(\.groupIdHex) == ["g1", nil])
    }

    /// A failed bulk call may still have removed some, so the shell drops its copies anyway.
    @Test func aFailedRemovalIsShownBesideItsControlAndStillInvalidatesHostMedia() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.bulkAttachmentRemovalError = MarmotKitError.Io(details: "disk")
        let recorder = Recorder()
        let model = Self.model(runtime, recorder: recorder)

        await model.removeAllAttachments(inChat: "g1")

        #expect(model.failedOperation == .removeChat("g1"))
        #expect(recorder.attachmentsDidChangeCount == 1)
    }

    @Test func singleRemovalGoesThroughTheAttachmentsOwnRemove() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentLocalAssetResults = [AttachmentLocalAssetFfi(reference: "local-ref", byteCount: 10)]
        let model = Self.model(runtime)
        let attachment = Self.attachment("g1", "m1")

        await model.remove(attachment)

        #expect(runtime.controlledAttachments.map(\.reference) == ["local-ref"])
        #expect(runtime.controlledAttachments.map(\.control) == [.remove])
        #expect(model.failedOperation == nil)
    }

    /// An entry that no longer reads locally cannot be removed; the row says so, and the listing
    /// starting over drops it.
    @Test func anEntryNoLongerHeldReportsTheFailureOnItsRow() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = Self.model(runtime)
        let attachment = Self.attachment("g1", "m1")

        await model.remove(attachment)

        #expect(runtime.controlledAttachments.isEmpty)
        #expect(model.failedOperation == .removeAttachment(ManageStoragePresentation.attachmentID(attachment)))
    }

    /// Clearing the picture cache removes no attachment, so the host keeps its decrypted copies.
    @Test func clearingTheCacheLeavesHostMediaAlone() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let recorder = Recorder()
        let model = Self.model(runtime, recorder: recorder)

        await model.clearCache()

        #expect(runtime.didClearAvatarCache)
        #expect(recorder.attachmentsDidChangeCount == 0)
        #expect(model.failedOperation == nil)
    }

    /// Chats are named the way the sidebar names them, so a rename or a picture that arrives
    /// reaches this page through the live chat list.
    @Test func chatsAreNamedFromTheLiveChatList() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let row = chatListRow(groupIdHex: "g1", title: "Weekend Hike", preview: "", sender: "s", timelineAt: 1)
        runtime.presentedChatListSnapshot = PresentedChatListSnapshotFfi(
            rows: [Self.presented(row, title: "Weekend Hike")],
            presentationVersion: PresentationVersionFfi(accountStoreEpoch: Data(repeating: 1, count: 16), revision: 1)
        )
        let chatList = ChatListViewModel(account: AccountItem.samples[0], runtime: runtime)
        chatList.start()
        defer { chatList.stop() }
        // The subscription is the chat list's own task, with no handle to await.
        let deadline = ContinuousClock.now + .seconds(5)
        while chatList.presentedRows.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let model = Self.model(runtime, chatList: chatList)

        #expect(model.chat(for: "g1", nicknames: .none)?.title == "Weekend Hike")
        #expect(model.chat(for: "elsewhere", nicknames: .none) == nil)
    }

    /// A listed chat the chat list does not carry yet is read once from MDK.
    @Test func chatsMissingFromTheChatListAreReadOnce() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let row = chatListRow(groupIdHex: "g1", title: "Archived Trip", preview: "", sender: "s", timelineAt: 1)
        runtime.presentedChatListSnapshot = PresentedChatListSnapshotFfi(
            rows: [Self.presented(row, title: "Archived Trip")],
            presentationVersion: PresentationVersionFfi(accountStoreEpoch: Data(repeating: 1, count: 16), revision: 1)
        )
        runtime.chatStorageUsage = [ChatAttachmentUsageFfi(groupIdHex: "g1", bytes: 10, attachmentCount: 1)]
        let model = Self.model(runtime)

        await model.load()

        #expect(model.chat(for: "g1", nicknames: .none)?.title == "Archived Trip")
    }

    private static func presented(_ row: ChatListRowFfi, title: String) -> PresentedChatRowFfi {
        PresentedChatRowFfi(
            draftVersion: nil,
            preview: .message,
            actions: ChatListRowActionsFfi(
                canMarkRead: false, canMarkUnread: true, canPin: true, canUnpin: false,
                canMute: true, canUnmute: false, canArchive: true, canRestore: false,
                canStartLeave: true, canDeleteLocal: false
            ),
            row: row,
            presentation: ConversationPresentationFfi(
                title: .literal(text: title),
                avatar: .placeholder(stableSeed: row.groupIdHex, source: .group),
                titleSource: .group,
                avatarSource: .group,
                peerId: nil,
                resolution: .cached
            ),
            avatarAsset: nil
        )
    }
}
