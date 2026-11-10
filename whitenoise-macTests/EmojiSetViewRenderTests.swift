import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The emoji-set browser, a set's page, and custom emoji in the emoji picker, hosted in a window so
/// their own `.task`s run against a `FakeMarmotRuntime` and clicks reach their buttons.
///
/// Browsing sets is text only; opening or installing one downloads its images from hosts the
/// set's author chose, and an installed emoji is read back from MDK rather than downloaded again.
/// So these pair what was drawn with where each image came from. Every fixture image is solid
/// magenta, which nothing else in the app draws: magenta in the drawing means an emoji was drawn.
///
/// `.serialized` and `@MainActor` because hosting draws through AppKit, which off the main thread
/// takes the test host down.
@Suite(.serialized) @MainActor struct EmojiSetViewRenderTests {
    // MARK: - Browser

    @Test func theBrowserListsSetsAsTextAndLoadsNoImages() async throws {
        let none = try await Self.browserRows(Self.runtime(sets: []))

        let runtime = try Self.runtime(sets: [
            Self.set(installed: true, updateAvailable: true), Self.set("30030:author:birds", title: "Birds"),
        ])
        runtime.userEmojiListSets = [Self.set("30030:author:cats", title: "Cats")]
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(EmojiSetBrowser(library: library, onBack: {}), size: Self.pageSize)
        defer { host.close() }

        // Installed, From Your Emoji List and Discover each add a titled section and a row.
        let listed = try #require(await host.settleDrawing { DrawnPixels.inkedRows($0) > none + 120 })
        #expect(runtime.syncEmojiSetsCallCount == 1)
        #expect(library.installedSets.map(\.coordinate) == [Self.coordinate])
        #expect(library.images.images.isEmpty)
        #expect(library.images.failures.isEmpty)
        #expect(DrawnPixels.fixturePixels(in: listed) == 0)
    }

    /// While relays are still being asked, the list waits rather than claiming there are none; a
    /// failed refresh explains itself rather than reading as an empty relay. Each state is told
    /// apart by where the page ends: the egress disclosure sits under Discover's list.
    @Test func discoverShowsLoadingThenNoneOrTheFailure() async throws {
        let runtime = try Self.runtime(sets: [])
        runtime.syncEmojiSetsGate.isEnabled = true
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(EmojiSetBrowser(library: library, onBack: {}), size: Self.pageSize)
        defer { host.close() }

        try #require(await host.settle { runtime.syncEmojiSetsGate.didReach })
        #expect(await host.settle { library.isSyncing })
        let loadingEnd = DrawnPixels.lastInkedRow(try #require(host.snapshot()))
        runtime.syncEmojiSetsGate.release()
        #expect(await host.settle { !library.isSyncing })
        // "Your relays don't have any emoji sets yet…" is two lines where the spinner was one.
        let none = try #require(
            await host.settleDrawing { DrawnPixels.lastInkedRow($0) > loadingEnd + 20 })
        let noneEnd = DrawnPixels.lastInkedRow(none)
        // The egress disclosure stays under the list: browsing is public and the author's servers
        // see the address of whoever opens a set.
        #expect(DrawnText.contains("reviewed by White Noise", in: none))
        #expect(DrawnText.contains("which can see your IP address", in: none))

        let failing = try Self.runtime(sets: [])
        failing.emojiSetActionError = MarmotKitError.EmojiSetNetwork(details: "offline")
        let failingLibrary = EmojiSetLibrary(accountRef: "account", runtime: failing)
        let failed = HostedViewWindow(EmojiSetBrowser(library: failingLibrary, onBack: {}), size: Self.pageSize)
        defer { failed.close() }
        // The failure's heading, its reason and Try Again.
        #expect(await failed.settleDrawing { DrawnPixels.lastInkedRow($0) > noneEnd + 40 } != nil)
    }

    @Test func theBrowsersBackButtonLeavesIt() async throws {
        var left = false
        let host = HostedViewWindow(
            EmojiSetBrowser(library: EmojiSetLibrary(accountRef: "account", runtime: nil), onBack: { left = true }),
            size: Self.pageSize)
        defer { host.close() }

        host.clickHeaderBack()

        #expect(await host.settle { left })
    }

    // MARK: - A set's page

    @Test func openingASetPreviewsItsImagesAndMarksTheOneThatFailed() async throws {
        let set = Self.set(shortcodes: ["blob", "wave", "broken"])
        let runtime = try Self.runtime(sets: [set])
        runtime.emojiSetAssetBytes["broken"] = nil
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(Self.page(library, set), size: Self.pageSize)
        defer { host.close() }

        let broken = Self.preview(set, "broken")
        #expect(await host.settle { library.images.images.count == 2 && library.images.hasFailed(broken) })
        #expect(library.images.image(for: Self.preview(set, "blob")) != nil)
        #expect(library.images.image(for: Self.preview(set, "wave")) != nil)
        // Two of the three cells draw their image; the third offers Try Again instead.
        let drawn = try #require(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 })
        #expect(DrawnPixels.isAbout(DrawnPixels.fixturePixels(in: drawn), 2 * Self.cellPixels))
        // The page that downloads the images says whose servers they come from.
        #expect(DrawnText.contains("which can see your IP address", in: drawn))
    }

    @Test func installingShowsProgressThenReadsTheEmojiBackFromMDK() async throws {
        let set = Self.set()
        let runtime = try Self.runtime(sets: [set])
        runtime.installEmojiSetGate.isEnabled = true
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(Self.page(library, set), size: Self.pageSize)
        defer { host.close() }
        let previewed = try #require(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 })
        let gridTop = try #require(DrawnPixels.firstFixturePoint(in: previewed)).y

        host.clickHeaderTrailingControl()

        try #require(await host.settle { runtime.installEmojiSetGate.didReach })
        #expect(library.installProgress[Self.coordinate]?.totalEmoji == 2)
        // The progress bar and its count and Cancel sit above the grid while the install runs.
        let installing = await host.settleDrawing { drawing in
            (DrawnPixels.firstFixturePoint(in: drawing)?.y ?? 0) > gridTop + 20
        }
        #expect(installing != nil)

        runtime.installEmojiSetGate.release()
        #expect(await host.settle { library.isInstalled(Self.coordinate) && library.installProgress.isEmpty })
        // Installed, the grid reads each emoji from MDK's store instead of the author's host.
        let installed = library.installedEmoji.map(EmojiSetImageStore.Source.installed)
        #expect(installed.count == 2)
        #expect(await host.settle { installed.allSatisfy { library.images.image(for: $0) != nil } })
        let settled = await host.settleDrawing { drawing in
            DrawnPixels.firstFixturePoint(in: drawing).map { abs($0.y - gridTop) < 2 } ?? false
        }
        #expect(settled != nil)
    }

    @Test func cancellingAnInstallLeavesTheSetUninstalledAndSaysNothing() async throws {
        let set = Self.set()
        let runtime = try Self.runtime(sets: [set])
        runtime.installEmojiSetGate.isEnabled = true
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(Self.page(library, set), size: Self.pageSize)
        defer { host.close() }
        let previewed = try #require(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 })
        let gridTop = try #require(DrawnPixels.firstFixturePoint(in: previewed)).y

        host.clickHeaderTrailingControl()
        try #require(await host.settle { runtime.installEmojiSetGate.didReach })
        library.cancelInstall(Self.coordinate)
        runtime.installEmojiSetGate.release()

        #expect(await host.settle { library.installProgress.isEmpty })
        // A cancelled install is the person's own choice: no error line pushes the grid down.
        let settled = await host.settleDrawing { drawing in
            DrawnPixels.firstFixturePoint(in: drawing).map { abs($0.y - gridTop) < 2 } ?? false
        }
        #expect(settled != nil)
        #expect(!library.isInstalled(Self.coordinate))
    }

    @Test func anInstalledSetDrawsItsStoredEmojiWithoutContactingTheHost() async throws {
        let set = Self.set(installed: true)
        let runtime = try Self.runtime(sets: [set])
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        await library.reloadInstalled()
        let host = HostedViewWindow(Self.page(library, set), size: Self.pageSize)
        defer { host.close() }

        let drawn = await host.settleDrawing {
            DrawnPixels.isAbout(DrawnPixels.fixturePixels(in: $0), 2 * Self.cellPixels)
        }
        #expect(drawn != nil)
        #expect(Set(library.images.images.keys) == Set(library.installedEmoji.map(EmojiSetImageStore.Source.installed)))
    }

    /// An installed set with a newer version stored offers Update in the header, previews the new
    /// version, and keeps a separate Remove Set below it.
    @Test func anOutdatedSetOffersUpdateAndKeepsRemoveBelow() async throws {
        let current = Self.set(installed: true)
        let outdated = Self.set(installed: true, updateAvailable: true)
        let runtime = try Self.runtime(sets: [current])
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        await library.reloadInstalled()

        let removeRows = try await Self.pageRows(library, current)
        let updateRows = try await Self.pageRows(library, outdated)
        // The Remove Set button under the grid.
        #expect(updateRows > removeRows + 20)
        #expect(library.images.image(for: Self.preview(outdated, "blob")) != nil)

        let host = HostedViewWindow(Self.page(library, outdated), size: Self.pageSize)
        defer { host.close() }
        _ = await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 }
        host.clickHeaderTrailingControl()
        #expect(await host.settle { runtime.installEmojiSetControls.count == 1 })
    }

    @Test func notesExplainSkippedAndUnsendableEmoji() async throws {
        let clean = Self.set(shortcodes: ["blob", "wave"])
        let noted = Self.set(shortcodes: ["blob", String(repeating: "x", count: 63)], skippedCount: 2)
        let runtime = try Self.runtime(sets: [clean])
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)

        let cleanRows = try await Self.pageRows(library, clean)
        runtime.emojiSetStore = [noted]
        let notedRows = try await Self.pageRows(library, noted)

        // "2 emoji in this set can't be used." and the unsendable shortcode's note.
        #expect(notedRows > cleanRows + 30)
    }

    // MARK: - Custom emoji in the picker

    @Test func thePickerDrawsInstalledEmojiFromMDKAndSendsTheShortcodePicked() async throws {
        let set = Self.set(installed: true)
        let runtime = try Self.runtime(sets: [set])
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        var picked: [String] = []
        let host = HostedViewWindow(
            ChatEmojiPicker(custom: Self.pickerContent(library), onPick: { picked.append($0) }), size: Self.pickerSize)
        defer { host.close() }

        #expect(await host.settle { library.hasLoadedInstalled && library.images.images.count == 2 })
        // Read from MDK's store, never previewed from the author's host.
        #expect(Set(library.images.images.keys) == Set(library.installedEmoji.map(EmojiSetImageStore.Source.installed)))
        let drawn = try #require(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 })

        host.click(at: try #require(DrawnPixels.firstFixturePoint(in: drawn)))

        #expect(await host.settle { picked == [":blob:"] })
    }

    @Test func aDisabledCustomEmojiIsDrawnFadedAndIgnoresClicks() async throws {
        let set = Self.set(installed: true)
        let runtime = try Self.runtime(sets: [set])
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        var picked: [String] = []
        let enabled = HostedViewWindow(
            ChatEmojiPicker(custom: Self.pickerContent(library), onPick: { _ in }), size: Self.pickerSize)
        defer { enabled.close() }
        #expect(await enabled.settle { library.images.images.count == 2 })
        let both = try #require(await enabled.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 })
        let blob = try #require(DrawnPixels.firstFixturePoint(in: both))
        let fullStrength = DrawnPixels.fixturePixels(in: both)

        let host = HostedViewWindow(
            ChatEmojiPicker(
                disabledEmoji: [":blob:"], custom: Self.pickerContent(library), onPick: { picked.append($0) }),
            size: Self.pickerSize)
        defer { host.close() }
        let faded = try #require(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 })

        // Only `:wave:` is still drawn at full strength.
        #expect(DrawnPixels.isAbout(DrawnPixels.fixturePixels(in: faded), fullStrength / 2))
        host.click(at: blob)
        _ = await host.settle(timeout: .milliseconds(150)) { !picked.isEmpty }
        #expect(picked.isEmpty)
    }

    @Test func thePickersEmojiSetsButtonOpensTheBrowser() async throws {
        let set = Self.set(installed: true)
        let runtime = try Self.runtime(sets: [set])
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(
            ChatEmojiPicker(custom: Self.pickerContent(library), onPick: { _ in }), size: Self.pickerSize)
        defer { host.close() }
        let picker = try #require(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 })
        let emoji = try #require(DrawnPixels.firstFixturePoint(in: picker))
        #expect(runtime.syncEmojiSetsCallCount == 0)

        // "Emoji Sets" follows the last custom group, below its one row of emoji.
        host.click(at: CGPoint(x: emoji.x + 30, y: emoji.y + 48))

        // The browser syncs relays and lists sets as text, so the emoji are gone from view.
        #expect(await host.settle { runtime.syncEmojiSetsCallCount == 1 })
        #expect(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) == 0 } != nil)
    }

    // MARK: - Send notice

    @Test func theSendNoticeWrapsItsMessageAndDismisses() async throws {
        var dismissed = false
        let short = HostedViewWindow(
            CustomEmojiSendNotice(message: "Not sent.", onDismiss: {}).frame(width: Self.noticeSize.width),
            size: Self.noticeSize)
        defer { short.close() }
        let long = HostedViewWindow(
            CustomEmojiSendNotice(message: CustomEmojiSendError.mixedWithAttachments.message) { dismissed = true }
                .frame(width: Self.noticeSize.width),
            size: Self.noticeSize)
        defer { long.close() }

        let shortRows = DrawnPixels.inkedRows(try #require(short.snapshot()))
        let longRows = DrawnPixels.inkedRows(try #require(long.snapshot()))
        // Wrapped rather than truncated: the explanation takes more lines than a short one.
        #expect(longRows > shortRows + 20)

        // The dismiss button is the trailing control, inside the notice's 12pt padding.
        long.click(at: CGPoint(x: Self.noticeSize.width - 12 - 11, y: Self.noticeSize.height / 2))
        #expect(await long.settle { dismissed })
    }

    // MARK: - Fixtures

    private static let coordinate = "30030:author:blobs"
    private static let eventId = String(repeating: "e", count: 64)
    private static let pageSize = CGSize(width: 420, height: 430)
    private static let pickerSize = CGSize(width: 420, height: 430)
    /// Narrow enough that a sentence-long explanation wraps.
    private static let noticeSize = CGSize(width: 240, height: 120)
    /// Magenta samples one 36pt grid cell's image draws: one per point, as `fixturePixels`
    /// samples every other pixel of a 2x drawing.
    private static let cellPixels = 36 * 36

    private static func set(
        _ coordinate: String = coordinate, title: String = "Blob Friends", shortcodes: [String] = ["blob", "wave"],
        installed: Bool = false, updateAvailable: Bool = false, skippedCount: UInt32 = 0
    ) -> EmojiSetFfi {
        EmojiSetFfi(
            coordinate: coordinate, kind: 30030, authorPubkeyHex: String(repeating: "a", count: 64),
            identifier: "blobs", eventIdHex: eventId, createdAt: 0, title: title,
            description: "Round friends for every mood.", imageUrl: nil,
            emoji: shortcodes.map { EmojiSetEmojiFfi(shortcode: $0, url: "https://example.invalid/\($0).png") },
            skipped: [], skippedCount: skippedCount,
            installed: installed
                ? InstalledEmojiSetStateFfi(
                    eventIdHex: eventId, createdAt: 0, installedAt: 1, emojiCount: UInt32(shortcodes.count),
                    byteLen: 0, updateAvailable: updateAvailable)
                : nil)
    }

    /// A runtime storing `sets`, with an image ready to serve for every emoji in them.
    private static func runtime(sets: [EmojiSetFfi]) throws -> FakeMarmotRuntime {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.emojiSetStore = sets
        let png = try #require(DrawnPixels.fixturePNG())
        for shortcode in sets.flatMap(\.emoji).map(\.shortcode) { runtime.emojiSetAssetBytes[shortcode] = png }
        runtime.emojiSetAssetBytes[String(repeating: "x", count: 63)] = png
        return runtime
    }

    private static func page(_ library: EmojiSetLibrary, _ set: EmojiSetFfi) -> some View {
        EmojiSetDetailPage(library: library, initialSet: set, onBack: {})
    }

    private static func preview(_ set: EmojiSetFfi, _ shortcode: String) -> EmojiSetImageStore.Source {
        .preview(coordinate: set.coordinate, eventIdHex: set.eventIdHex, shortcode: shortcode)
    }

    /// The picker's custom emoji as a conversation offers them: built-ins, then installed sets.
    private static func pickerContent(_ library: EmojiSetLibrary) -> CustomEmojiPickerContent {
        CustomEmojiPickerContent(
            sendables: {
                CustomEmojiSendCatalog.sendables(builtins: [], installed: library.installedEmoji, chat: [])
            },
            emojiSets: library, chatImages: nil)
    }

    /// Rows a set's page draws once every image it can load has loaded.
    private static func pageRows(_ library: EmojiSetLibrary, _ set: EmojiSetFfi) async throws -> Int {
        let host = HostedViewWindow(page(library, set), size: CGSize(width: pageSize.width, height: 600))
        defer { host.close() }
        let drawn = try #require(
            await host.settleDrawing {
                DrawnPixels.isAbout(DrawnPixels.fixturePixels(in: $0), set.emoji.count * cellPixels)
            })
        return DrawnPixels.inkedRows(drawn)
    }

    /// Rows the browser draws once its first sync has finished and `predicate` holds for them.
    private static func browserRows(
        _ runtime: FakeMarmotRuntime, until predicate: ((Int) -> Bool)? = nil
    ) async throws -> Int {
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(EmojiSetBrowser(library: library, onBack: {}), size: pageSize)
        defer { host.close() }
        #expect(await host.settle { runtime.syncEmojiSetsCallCount == 1 && !library.isSyncing })
        let drawn =
            if let predicate {
                await host.settleDrawing { predicate(DrawnPixels.inkedRows($0)) }
            } else {
                await host.steadyDrawing()
            }
        return DrawnPixels.inkedRows(try #require(drawn))
    }
}
