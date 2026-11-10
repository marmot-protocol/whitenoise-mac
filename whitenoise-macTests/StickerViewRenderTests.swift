import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The sticker picker, the pack browser, a pack's page and a received sticker, hosted in a window
/// so their own `.task`s run against a `FakeMarmotRuntime` and clicks reach their buttons.
///
/// Loading a sticker image contacts the server its pack's author chose, so most of these pair what
/// was drawn with what was fetched. Every fixture image is solid magenta, which nothing else in
/// the app draws: magenta in the drawing means a sticker image was drawn.
///
/// `.serialized` and `@MainActor` because hosting draws through AppKit, which off the main thread
/// takes the test host down.
@Suite(.serialized) @MainActor struct StickerViewRenderTests {
    // MARK: - Received stickers

    @Test func aReceivedStickerFromAnUninstalledPackLoadsOnlyWhenClicked() async throws {
        let runtime = try Self.runtime(packs: [Self.pack(installed: false)])
        let library = StickerLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(
            MessageStickerView(library: library, sticker: Self.wave, isOutgoing: false), size: Self.messageSize)
        defer { host.close() }

        #expect(await host.settle { library.hasLoadedInstalled })
        let waiting = try #require(host.snapshot())
        #expect(runtime.fetchStickerAssetRequests.isEmpty)
        #expect(DrawnPixels.fixturePixels(in: waiting) == 0)
        // The click-to-load placeholder: its glyph and "Click to load sticker".
        #expect(DrawnPixels.inkedRows(waiting) > 40)

        host.click(at: CGPoint(x: Self.messageSize.width / 2, y: Self.messageSize.height / 2))

        #expect(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 } != nil)
        #expect(runtime.fetchStickerAssetRequests.map(\.shortcode) == ["wave"])
    }

    /// The person's own stickers were loaded to send them, and an installed pack was chosen: both
    /// load without a click.
    @Test(arguments: [(isOutgoing: true, installed: false), (isOutgoing: false, installed: true)])
    func ownStickersAndInstalledPacksLoadByThemselves(isOutgoing: Bool, installed: Bool) async throws {
        let runtime = try Self.runtime(packs: [Self.pack(installed: installed)])
        let library = StickerLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(
            MessageStickerView(library: library, sticker: Self.wave, isOutgoing: isOutgoing), size: Self.messageSize)
        defer { host.close() }

        let drawn = try #require(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 })

        // The image fills the sticker's square, not a corner of it. Sampling every other pixel
        // of a 2x drawing counts one sample per point.
        let side = Int(StickerMetrics.messageSide)
        #expect(DrawnPixels.fixturePixels(in: drawn) > side * side / 2)
        #expect(runtime.fetchStickerAssetRequests.map(\.shortcode) == ["wave"])
    }

    @Test func aStickerThatFailedToLoadWaitsForARetryClick() async throws {
        let runtime = try Self.runtime(packs: [Self.pack(installed: true)])
        runtime.fetchStickerAssetError = MarmotKitError.StickerNetwork(details: "offline")
        let library = StickerLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(
            MessageStickerView(library: library, sticker: Self.wave, isOutgoing: false), size: Self.messageSize)
        defer { host.close() }

        #expect(await host.settle { library.assets.hasFailed(Self.wave) })
        // Redrawing a failed sticker never re-dials its server.
        _ = await host.settle(timeout: .milliseconds(100)) { false }
        #expect(runtime.fetchStickerAssetRequests.count == 1)
        #expect(DrawnPixels.fixturePixels(in: try #require(host.snapshot())) == 0)

        runtime.fetchStickerAssetError = nil
        host.click(at: CGPoint(x: Self.messageSize.width / 2, y: Self.messageSize.height / 2))

        #expect(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 } != nil)
        #expect(runtime.fetchStickerAssetRequests.count == 2)
    }

    // MARK: - Picker

    @Test func thePickerDrawsTheInstalledPackAndSendsTheStickerClicked() async throws {
        let party = Self.pack(installed: true)
        let other = Self.pack("30031:author:other", title: "Other", installed: true, shortcodes: ["cat"])
        let runtime = try Self.runtime(packs: [party, other])
        let library = StickerLibrary(accountRef: "account", runtime: runtime)
        var sent: [String] = []
        var dismissed = false
        let host = HostedViewWindow(
            StickerPickerPopover(
                library: library, send: { sent.append($0.shortcode) }, onDismiss: { dismissed = true }),
            size: Self.popoverSize)
        defer { host.close() }

        #expect(await host.settle { library.assets.images.count == 3 })
        let drawn = try #require(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 })

        // Opening the picker refreshes packs from relays once, and loads the first pack's stickers
        // and the other pack's tab cover, nothing more.
        #expect(runtime.syncStickerPacksCallCount == 1)
        #expect(Set(runtime.fetchStickerAssetRequests.map(\.shortcode)) == ["wave", "dance", "cat"])

        // The tab row's covers come first; the grid's first sticker is the first one below them.
        let tabCover = try #require(DrawnPixels.firstFixturePoint(in: drawn))
        let sticker = try #require(
            DrawnPixels.firstFixturePoint(in: drawn, below: tabCover.y + StickerMetrics.packTabSide))
        host.click(at: sticker)

        #expect(await host.settle { dismissed })
        #expect(sent == ["wave"])
    }

    @Test func aPickerWithNoPacksDrawsNoStickersAndOpensTheBrowser() async throws {
        let runtime = try Self.runtime(packs: [Self.pack("30031:author:new", title: "New")])
        let library = StickerLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(
            StickerPickerPopover(library: library, send: { _ in }, onDismiss: {}), size: Self.popoverSize)
        defer { host.close() }

        #expect(await host.settle { library.hasLoadedInstalled && runtime.syncStickerPacksCallCount == 1 })
        let empty = try #require(host.snapshot())
        #expect(DrawnPixels.fixturePixels(in: empty) == 0)

        // The header's Sticker Packs button opens the browser, which lists the pack as text: more
        // drawn than the empty state, still without loading any artwork.
        host.clickHeaderTrailingControl()
        let browser = await host.settleDrawing { DrawnPixels.inkedRows($0) > DrawnPixels.inkedRows(empty) + 40 }
        #expect(browser != nil)
        #expect(runtime.fetchStickerAssetRequests.isEmpty)

        // Back returns to the picker as it was.
        host.clickHeaderBack()
        let back = await host.settleDrawing {
            abs(DrawnPixels.inkedRows($0) - DrawnPixels.inkedRows(empty)) < 4
        }
        #expect(back != nil)
    }

    // MARK: - Pack browser

    /// Discover's states: cached packs, none on the relays, and relays that couldn't be reached.
    /// Browsing never loads a pack's artwork; only opening one does.
    @Test func theBrowserListsPacksAsTextAndExplainsAnEmptyOrFailedRefresh() async throws {
        let none = try await Self.browserDrawing(try Self.runtime(packs: [])) { $0 != $1 }
        let noneRows = DrawnPixels.inkedRows(none)

        let listedRuntime = try Self.runtime(packs: [
            Self.pack(installed: true), Self.pack("30031:author:b", title: "Birds"),
            Self.pack("30031:author:c", title: "Cats"),
        ])
        // An Installed section and two Discover rows.
        let listed = try await Self.browserDrawing(listedRuntime) { rows, _ in rows > noneRows + 60 }
        #expect(DrawnPixels.fixturePixels(in: listed) == 0)

        let failedRuntime = try Self.runtime(packs: [])
        failedRuntime.syncStickerPacksError = MarmotKitError.StickerNetwork(details: "offline")
        // The failure, its reason and Try Again replace the one-line "none yet" note.
        _ = try await Self.browserDrawing(failedRuntime) { rows, _ in rows > noneRows + 20 }
    }

    // MARK: - Pack page

    @Test func openingAPackDrawsItsStickersAndItsButtonAddsThenRemovesIt() async throws {
        let pack = Self.pack(installed: false)
        let runtime = try Self.runtime(packs: [pack])
        let library = StickerLibrary(accountRef: "account", runtime: runtime)
        await library.loadInstalledIfNeeded()
        let host = HostedViewWindow(
            StickerPackDetailPage(library: library, pack: pack, onBack: {}), size: Self.popoverSize)
        defer { host.close() }

        // Opening the pack is the deliberate action that loads its artwork: every sticker, drawn.
        #expect(await host.settle { library.assets.images.count == 2 })
        #expect(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 } != nil)
        #expect(Set(runtime.fetchStickerAssetRequests.map(\.shortcode)) == ["wave", "dance"])

        host.clickHeaderTrailingControl()
        #expect(await host.settle { library.isInstalled(pack.coordinate) })
        #expect(runtime.stickerPackStore.first?.installed == true)

        host.clickHeaderTrailingControl()
        #expect(await host.settle { !library.isInstalled(pack.coordinate) })
        #expect(runtime.stickerPackStore.first?.installed == false)
    }

    @Test func aFailedAddSaysWhyAboveTheStickers() async throws {
        let pack = Self.pack(installed: false)
        let runtime = try Self.runtime(packs: [pack])
        runtime.stickerPackActionError = MarmotKitError.StickerNetwork(details: "offline")
        let library = StickerLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(
            StickerPackDetailPage(library: library, pack: pack, onBack: {}), size: Self.popoverSize)
        defer { host.close() }
        let before = try #require(await host.settleDrawing { DrawnPixels.fixturePixels(in: $0) > 0 })
        let stickersTop = try #require(DrawnPixels.firstFixturePoint(in: before)).y

        host.clickHeaderTrailingControl()

        // The error is a line of its own above the grid, pushing the stickers down.
        let after = await host.settleDrawing { drawing in
            (DrawnPixels.firstFixturePoint(in: drawing)?.y ?? 0) > stickersTop + 8
        }
        #expect(after != nil)
        #expect(!library.isInstalled(pack.coordinate))
    }

    // MARK: - Fixtures

    private static let coordinate = "30031:author:party"
    private static let messageSize = CGSize(width: StickerMetrics.messageSide, height: StickerMetrics.messageSide)
    private static let popoverSize = CGSize(width: StickerMetrics.popoverWidth, height: StickerMetrics.popoverHeight)
    private static let wave = StickerKey(packCoordinate: coordinate, shortcode: "wave", plaintextSha256: "sha-wave")

    private static func pack(
        _ coordinate: String = coordinate, title: String = "Party Animals", installed: Bool = false,
        shortcodes: [String] = ["wave", "dance"]
    ) -> StickerPackFfi {
        StickerPackFfi(
            coordinate: coordinate, authorPubkeyHex: String(repeating: "a", count: 64), identifier: "party",
            eventIdHex: String(repeating: "b", count: 64), createdAt: 0, title: title,
            description: "A few animals having a good time.", cover: nil,
            stickers: shortcodes.map { shortcode in
                StickerFfi(
                    packCoordinate: coordinate, shortcode: shortcode, url: "https://example.invalid/\(shortcode).png",
                    plaintextSha256: "sha-\(shortcode)", mime: "image/png", width: 16, height: 16, alt: nil,
                    emoji: "🎉")
            },
            license: nil, installed: installed)
    }

    /// A runtime storing `packs`, with every sticker's image ready to serve.
    private static func runtime(packs: [StickerPackFfi]) throws -> FakeMarmotRuntime {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.stickerPackStore = packs
        let png = try #require(DrawnPixels.fixturePNG())
        for sticker in packs.flatMap(\.stickers) { runtime.stickerAssets[sticker.plaintextSha256] = png }
        return runtime
    }

    /// The pack browser, reached the way a person reaches it — the picker's Sticker Packs button —
    /// once `predicate` holds for its inked rows and those of the picker it replaced.
    private static func browserDrawing(
        _ runtime: FakeMarmotRuntime, until predicate: (_ rows: Int, _ pickerRows: Int) -> Bool
    ) async throws -> NSBitmapImageRep {
        let library = StickerLibrary(accountRef: "account", runtime: runtime)
        let host = HostedViewWindow(
            StickerPickerPopover(library: library, send: { _ in }, onDismiss: {}), size: popoverSize)
        defer { host.close() }
        #expect(await host.settle { library.hasLoadedInstalled && runtime.syncStickerPacksCallCount == 1 })
        _ = await host.settle { !library.isSyncing }
        let pickerRows = DrawnPixels.inkedRows(try #require(host.snapshot()))
        let fetched = runtime.fetchStickerAssetRequests.count
        host.clickHeaderTrailingControl()
        let drawing = try #require(await host.settleDrawing { predicate(DrawnPixels.inkedRows($0), pickerRows) })
        // Browsing lists packs as text: nothing beyond what the picker had already loaded.
        #expect(runtime.fetchStickerAssetRequests.count == fetched)
        return drawing
    }
}
