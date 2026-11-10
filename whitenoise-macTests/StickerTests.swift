import AppKit
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Sonar stickers: a public pack reference on a kind-9, drawn on its own. Loading an image
/// contacts the pack author's server, so received stickers load only from installed packs.
struct StickerTests {
    private static let coordinate = "30031:author:party"

    private static func sticker(_ shortcode: String = "wave", sha: String = "aa") -> StickerFfi {
        StickerFfi(
            packCoordinate: coordinate, shortcode: shortcode, url: "https://example.invalid/\(shortcode).png",
            plaintextSha256: sha, mime: "image/png", width: 8, height: 8, alt: nil, emoji: nil)
    }

    private static func pack(
        _ coordinate: String = coordinate, title: String = "Party", installed: Bool = false,
        stickers: [StickerFfi] = [sticker()]
    ) -> StickerPackFfi {
        StickerPackFfi(
            coordinate: coordinate, authorPubkeyHex: String(repeating: "a", count: 64), identifier: "party",
            eventIdHex: String(repeating: "b", count: 64), createdAt: 0, title: title, description: nil,
            cover: nil, stickers: stickers, license: nil, installed: installed)
    }

    private static func png() throws -> Data {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    // MARK: - Presentation

    @Test func onlyOwnStickersAndInstalledPacksLoadWithoutAClickUnlessEveryStickerDoes() {
        #expect(StickerLoadPolicy.loadsAutomatically(isFromMe: true, packInstalled: false, loadsEverySticker: false))
        #expect(StickerLoadPolicy.loadsAutomatically(isFromMe: false, packInstalled: true, loadsEverySticker: false))
        #expect(!StickerLoadPolicy.loadsAutomatically(isFromMe: false, packInstalled: false, loadsEverySticker: false))
        #expect(StickerLoadPolicy.loadsAutomatically(isFromMe: false, packInstalled: false, loadsEverySticker: true))
    }

    @MainActor
    @Test func theStickerLoadingChoiceIsOffByDefaultPersistsAndErases() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        #expect(!StickerLoadingPreference(defaults: defaults).automaticallyLoads)

        StickerLoadingPreference(defaults: defaults).setAutomaticallyLoads(true)
        let relaunched = StickerLoadingPreference(defaults: defaults)
        #expect(relaunched.automaticallyLoads)

        relaunched.reset()
        #expect(!relaunched.automaticallyLoads)
        #expect(!StickerLoadingPreference(defaults: defaults).automaticallyLoads)
    }

    @Test func aStickerLabelUsesItsEmojiOnlyWhenItIsOne() {
        #expect(StickerLoadPolicy.label(emoji: nil) == L10n.string("Sticker"))
        #expect(StickerLoadPolicy.label(emoji: "not an emoji") == L10n.string("Sticker"))
        #expect(StickerLoadPolicy.label(emoji: "🎉") == String(format: L10n.string("%@ Sticker"), "🎉"))
        #expect(
            StickerLoadPolicy.accessibilityLabel(alt: "A waving cat", emoji: "👋")
                == String(format: L10n.string("Sticker: %@"), "A waving cat"))
    }

    @Test func discoveryOffersOnlyUninstalledPacksWithStickers() {
        let packs = [
            Self.pack("a", installed: true),
            Self.pack("b"),
            Self.pack("c", stickers: []),
            Self.pack("d"),
        ]
        let found = StickerPackPresentation.discoverable(packs, installed: ["d"])
        #expect(found.map(\.coordinate) == ["b"])
    }

    @Test func aFailedRefreshNeverReadsAsNoPacks() {
        #expect(
            StickerPackPresentation.discoveryState(isLoading: false, packCount: 2, search: "", syncError: "x")
                == .packs)
        #expect(
            StickerPackPresentation.discoveryState(isLoading: false, packCount: 0, search: "", syncError: "x")
                == .unreachable(message: "x"))
        #expect(
            StickerPackPresentation.discoveryState(isLoading: false, packCount: 0, search: "", syncError: nil)
                == .noneOnRelays)
        #expect(
            StickerPackPresentation.discoveryState(isLoading: false, packCount: 0, search: "cat", syncError: nil)
                == .noMatches)
        #expect(
            StickerPackPresentation.discoveryState(isLoading: true, packCount: 0, search: "", syncError: nil)
                == .loading)
    }

    @Test func aLookupIsTrimmedAndBounded() {
        #expect(StickerPackPresentation.lookupInput("  naddr1abc \n") == "naddr1abc")
        #expect(StickerPackPresentation.lookupInput("   ") == nil)
        #expect(StickerPackPresentation.lookupInput(String(repeating: "x", count: 2_049)) == nil)
    }

    @Test func aBlankPackTitleFallsBackToAGenericOne() {
        #expect(StickerPackPresentation.title(Self.pack(title: " \n")) == L10n.string("Sticker Pack"))
    }

    // MARK: - Library

    @MainActor
    @Test func installingAndRemovingAPackRereadsTheInstalledList() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.stickerPackStore = [Self.pack()]
        let library = StickerLibrary(accountRef: "account", runtime: runtime)

        await library.loadInstalledIfNeeded()
        #expect(library.hasLoadedInstalled)
        #expect(library.installed.isEmpty)
        #expect(try await library.discover(search: nil).map(\.coordinate) == [Self.coordinate])

        try await library.install(Self.pack())
        #expect(library.isInstalled(Self.coordinate))
        #expect(try await library.discover(search: nil).isEmpty)

        try await library.uninstall(Self.pack())
        #expect(!library.isInstalled(Self.coordinate))
    }

    @MainActor
    @Test func relaysAreSyncedOncePerAccountUnlessForced() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let library = StickerLibrary(accountRef: "account", runtime: runtime)

        try await library.sync()
        try await library.sync()
        #expect(runtime.syncStickerPacksCallCount == 1)

        try await library.sync(force: true)
        #expect(runtime.syncStickerPacksCallCount == 2)
    }

    @MainActor
    @Test func aFailedSyncIsRetriedByTheNextRequest() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.syncStickerPacksError = MarmotKitError.StickerNetwork(details: "offline")
        let library = StickerLibrary(accountRef: "account", runtime: runtime)

        await #expect(throws: MarmotKitError.self) { try await library.sync() }
        runtime.syncStickerPacksError = nil
        try? await library.sync()

        #expect(runtime.syncStickerPacksCallCount == 2)
    }

    @MainActor
    @Test func sendingAStickerSendsItsImmutableReference() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let library = StickerLibrary(accountRef: "account", runtime: runtime)
        let sticker = Self.sticker()

        try await library.send(sticker, groupIdHex: "group")

        #expect(runtime.sentStickers.count == 1)
        #expect(runtime.sentStickers.first?.groupIdHex == "group")
        #expect(runtime.sentStickers.first?.ref == StickerKey(sticker).ref)
    }

    // MARK: - Images

    @MainActor
    @Test func aStickerImageLoadsOnceAndIsServedFromTheStore() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.stickerPackStore = [Self.pack()]
        runtime.stickerAssets["aa"] = try Self.png()
        let store = StickerAssetStore(accountRef: "account", runtime: runtime)
        let key = StickerKey(Self.sticker())

        store.load(key)
        store.load(key)
        #expect(await waitFor { store.image(for: key) != nil })

        #expect(runtime.fetchStickerAssetRequests.count == 1)
        #expect(!store.hasFailed(key))
    }

    @MainActor
    @Test func aFailedStickerStaysFailedUntilAnExplicitRetry() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.stickerPackStore = [Self.pack()]
        runtime.fetchStickerAssetError = MarmotKitError.StickerNetwork(details: "offline")
        let store = StickerAssetStore(accountRef: "account", runtime: runtime)
        let key = StickerKey(Self.sticker())

        store.load(key)
        #expect(await waitFor { store.hasFailed(key) })
        store.load(key)
        try await Task.sleep(for: .milliseconds(50))
        #expect(runtime.fetchStickerAssetRequests.count == 1)

        runtime.fetchStickerAssetError = nil
        runtime.stickerAssets["aa"] = try Self.png()
        store.retry(key)
        #expect(await waitFor { store.image(for: key) != nil })
        #expect(runtime.fetchStickerAssetRequests.count == 2)
    }

    // MARK: - Mapping

    @Test func aStickerMessageCarriesItsStickerInsteadOfReadingAsUnsupported() throws {
        var record = timelineMessage(id: "m1", groupIdHex: "group", sender: "alice", plaintext: "", recordedAt: 1)
        record.sticker = StickerKey(Self.sticker()).ref
        let page = TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false)

        let message = try #require(MessageItem.timeline(from: page, activeAccountIdHex: "self").first)

        #expect(message.sticker == StickerKey(Self.sticker()))
        #expect(message.body.isEmpty)
        #expect(!message.hasBubbleContent)
    }

    @Test func aDeletedStickerMessageDropsItsSticker() throws {
        var record = timelineMessage(
            id: "m1", groupIdHex: "group", sender: "alice", plaintext: "", recordedAt: 1, deleted: true)
        record.sticker = StickerKey(Self.sticker()).ref
        let page = TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false)

        let message = try #require(MessageItem.timeline(from: page, activeAccountIdHex: "self").first)

        #expect(message.sticker == nil)
    }

    @Test func aStickerPreviewReadsAsSticker() {
        var row = chatListRow(groupIdHex: "dm", title: "Alice", preview: "", sender: "alice", timelineAt: 1)
        row.lastMessage?.sticker = StickerKey(Self.sticker()).ref

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.preview.contains(L10n.string("Sticker")))
        #expect(!chat.preview.contains(L10n.string("Unsupported message")))
    }
}
