import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The Manage Storage page as drawn: hosting it is what starts its reads (the page and each
/// listing's load-more row own the `.task`s that page through MDK), and its rows change shape with
/// the model's state. Measured rather than inspected: the test host builds no accessibility tree.
///
/// `.serialized` and `@MainActor` because hosting switches `NSAppearance`-dependent drawing, which
/// off the main thread takes the test host down.
@Suite(.serialized) @MainActor
struct ManageStorageViewTests {
    private static let mebibyte: UInt64 = 1_048_576

    // MARK: - Page tasks

    @Test func openingThePageReadsUsageThenTheFirstPageOfChats() async throws {
        let runtime = Self.runtime(migration: .running)
        let model = Self.model(runtime)

        let window = Self.host(ManageStorageSettingsView(model: model, nicknames: .none))
        defer { window.close() }

        #expect(await Self.settle(window) { model.chats.items.count == 2 })
        #expect(runtime.attachmentStorageUsageReadCount == 1)
        #expect(runtime.chatStoragePageReadCount == 1)
        #expect(model.usage?.attachmentCount == 3)
        #expect(model.usage?.migration == .moving(remainingBytes: 640 * Self.mebibyte))
        // Every chat fitted on the first page, so the loading row is gone and asks for no more.
        #expect(!model.chats.hasMore)
        #expect(runtime.chatStoragePageReadCount == 1)
    }

    @Test func aFailedUsageReadStillDrawsThePageAndListsChats() async throws {
        let runtime = Self.runtime()
        runtime.attachmentStorageUsageError = FakeMarmotRuntimeError.unused
        let model = Self.model(runtime)

        let window = Self.host(ManageStorageSettingsView(model: model, nicknames: .none))
        defer { window.close() }

        #expect(await Self.settle(window) { model.chats.items.count == 2 })
        #expect(model.usage == nil)
        #expect(model.usageRefresh.failed)
    }

    @Test func aChatsPageListsOnlyThatChatsAttachments() async throws {
        let runtime = Self.runtime()
        let model = Self.model(runtime)
        await model.load()

        let window = Self.host(ManageStorageChatView(model: model, nicknames: .none, groupIdHex: "a1") {})
        defer { window.close() }

        #expect(await Self.settle(window) { !model.attachmentPages(.chat("a1")).hasMore })
        #expect(runtime.largestRetainedAttachmentReads == ["a1"])
        #expect(model.attachmentPages(.chat("a1")).items.map(\.groupIdHex) == ["a1", "a1"])
    }

    @Test func largestAttachmentsListsEveryChat() async throws {
        let runtime = Self.runtime()
        let model = Self.model(runtime)
        await model.load()

        let window = Self.host(ManageStorageLargestAttachmentsView(model: model, nicknames: .none) {})
        defer { window.close() }

        #expect(await Self.settle(window) { !model.attachmentPages(.account).hasMore })
        #expect(runtime.largestRetainedAttachmentReads == [nil])
        #expect(model.attachmentPages(.account).items.count == 3)
    }

    /// A chat with nothing left draws its empty state and does not page again.
    @Test func anEmptyChatAsksOnceAndStops() async throws {
        let runtime = Self.runtime()
        let model = Self.model(runtime)
        await model.load()

        let window = Self.host(ManageStorageChatView(model: model, nicknames: .none, groupIdHex: "gone") {})
        defer { window.close() }

        #expect(await Self.settle(window) { !model.attachmentPages(.chat("gone")).hasMore })
        #expect(model.attachmentPages(.chat("gone")).items.isEmpty)
        #expect(runtime.largestRetainedAttachmentReads == ["gone"])
    }

    /// Fixed figures, no runtime: every section draws in every migration state, and drawing the
    /// overview on its own neither re-reads nor pages, since the listing it was given is complete.
    @Test(arguments: [AttachmentMigrationStateFfi.running, .paused, .compacting, .complete])
    func theOverviewDrawsEveryMigrationStateWithoutPaging(migration: AttachmentMigrationStateFfi) async {
        let model = ManageStorageViewModel.fixture(
            usage: Self.usage(migration: migration), chats: Self.chats, attachments: Self.attachments)
        let epoch = model.epoch

        let window = Self.host(
            ManageStorageOverviewView(model: model, nicknames: .none, openLargestAttachments: {}, openChat: { _ in }))
        defer { window.close() }
        _ = await Self.settle(window, timeout: .milliseconds(200)) { false }

        #expect(model.epoch == epoch)
        #expect(model.chats.items.map(\.groupIdHex) == ["a1", "b2"])
        #expect(
            model.usage?.migration == ManageStoragePresentation.migrationNotice(migration, bytes: 640 * Self.mebibyte))
    }

    // MARK: - Rows

    @Test func everyMigrationNoticeDrawsItsOwnRow() {
        let notices: [ManageStoragePresentation.MigrationNotice] = [
            .moving(remainingBytes: 640 * Self.mebibyte), .paused(neededBytes: 2 * Self.mebibyte), .compacting,
        ]
        for notice in notices {
            #expect(Self.fittingSize(ManageStorageMigrationSection(notice: notice).frame(width: 520)).height > 0)
        }
    }

    /// A failed removal says so on its own row, under the subtitle.
    @Test func aFailedRemovalAddsALineToItsRow() {
        let ok = Self.fittingSize(Self.attachmentRow(failed: false))
        let failed = Self.fittingSize(Self.attachmentRow(failed: true))
        #expect(failed.height > ok.height)
    }

    /// Progress sits inside the control that started it, beside its label.
    @Test func progressWidensTheActionLabel() {
        let idle = Self.fittingSize(
            ManageStorageActionLabel(title: "Clear Cache", systemImage: "trash", inProgress: false))
        let busy = Self.fittingSize(
            ManageStorageActionLabel(title: "Clear Cache", systemImage: "trash", inProgress: true))
        #expect(busy.width > idle.width)
        #expect(Self.fittingSize(Self.attachmentRow(inProgress: true)).height > 0)
    }

    @Test func aChatRowDrawsWithAndWithoutItsChevron() {
        let usage = ChatAttachmentUsageFfi(groupIdHex: "a1", bytes: 185 * Self.mebibyte, attachmentCount: 2)
        let plain = Self.fittingSize(
            ManageStorageChatRow(chat: nil, groupIdHex: "a1", usage: usage, showsChevron: false).fixedSize())
        let chevron = Self.fittingSize(
            ManageStorageChatRow(chat: nil, groupIdHex: "a1", usage: usage, showsChevron: true).fixedSize())
        #expect(chevron.width > plain.width)
    }

    @Test func theSmallRowsDraw() {
        #expect(Self.fittingSize(ManageStorageLoadingRow().frame(width: 300)).height > 0)
        #expect(Self.fittingSize(ManageStorageRetryRow(message: "Couldn't load chats") {}).height > 0)
        #expect(Self.fittingSize(ManageStorageByteText(bytes: 1_234_567)).width > 0)
        #expect(
            Self.fittingSize(ManageStorageRemoveOlderMenu(pendingRemoval: .constant(nil), inProgress: true)).width > 0)
    }

    // MARK: - Helpers

    private static func usage(migration: AttachmentMigrationStateFfi = .notNeeded) -> AttachmentStorageUsageFfi {
        AttachmentStorageUsageFfi(
            mediaBytes: 209 * mebibyte, legacyBytes: 0, attachmentCount: 3,
            databaseBytes: 18 * mebibyte, databaseFreeBytes: 0,
            migration: migration, migrationBytes: 640 * mebibyte, cacheBytes: 6 * mebibyte)
    }

    private static let chats = [
        ChatAttachmentUsageFfi(groupIdHex: "a1", bytes: 185 * mebibyte, attachmentCount: 2),
        ChatAttachmentUsageFfi(groupIdHex: "b2", bytes: 24 * mebibyte, attachmentCount: 1),
    ]

    private static let attachments = [
        ManageStoragePresentationTests.attachment(
            group: "a1", message: "m1", source: "m1", bytes: 182 * mebibyte, mediaType: "video/mp4",
            fileName: "Trailhead.mov", receivedAt: 1_760_000_000),
        ManageStoragePresentationTests.attachment(
            group: "b2", message: "m2", source: "m2", bytes: 24 * mebibyte, mediaType: "application/pdf",
            fileName: "Itinerary.pdf", receivedAt: 1_759_000_000),
        ManageStoragePresentationTests.attachment(
            group: "a1", message: "m3", source: "m3", index: 1, bytes: 3 * mebibyte, fileName: "",
            receivedAt: 1_756_000_000),
    ]

    private static func runtime(migration: AttachmentMigrationStateFfi = .notNeeded) -> FakeMarmotRuntime {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentStorageUsageResult = usage(migration: migration)
        runtime.chatStorageUsage = chats
        runtime.retainedAttachmentSummaries = attachments
        return runtime
    }

    private static func model(_ runtime: FakeMarmotRuntime) -> ManageStorageViewModel {
        ManageStorageViewModel(
            accountRef: "account", activeAccountIdHex: String(repeating: "f", count: 64), runtime: runtime)
    }

    private static func attachmentRow(failed: Bool = false, inProgress: Bool = false) -> some View {
        ManageStorageAttachmentRow(
            attachment: attachments[0], chatTitle: "Weekend Hike", inProgress: inProgress, failed: failed,
            onRemove: {}
        )
        .frame(width: 520)
    }

    private static func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view.environment(WorkspaceState.preview()))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// A page needs a window and a real size: its grouped `Form` builds rows only for what is on
    /// screen, and the rows' `.task`s start only once they are.
    private static func host(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.environment(WorkspaceState.preview()))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// The page's reads run in the view's own tasks, which have no handle to await, so this waits
    /// on a wall-clock deadline and re-lays the page out as the model changes.
    private static func settle(
        _ window: NSWindow, timeout: Duration = .seconds(5), until predicate: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
