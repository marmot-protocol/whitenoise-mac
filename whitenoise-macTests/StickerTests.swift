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

    // MARK: - Default packs

    private static func defaultPacks() -> [StickerPackFfi] {
        StickerDefaultPacks.coordinates.map { pack($0, title: "Default") }
    }

    private static func isolatedLedger() throws -> StickerDefaultPackLedger {
        StickerDefaultPackLedger(defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    }

    @Test func defaultPackInstallsAskWhiteNoiseRelaysWhateverTheAccountUses() throws {
        for coordinate in StickerDefaultPacks.coordinates {
            let link = try #require(URLComponents(string: StickerDefaultPacks.installInput(for: coordinate)))
            let items = link.queryItems ?? []
            #expect(link.scheme == "https")
            #expect(items.filter { $0.name == "a" }.map(\.value) == [coordinate])
            #expect(Set(items.filter { $0.name == "relay" }.compactMap(\.value)) == Set(MarmotClient.seedRelays))
        }
    }

    @MainActor
    @Test func defaultPacksInstallOnceAfterTheFirstSync() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.stickerPackStore = Self.defaultPacks()
        let library = StickerLibrary(
            accountRef: "account", runtime: runtime, defaultPackLedger: try Self.isolatedLedger())

        // Before a sync, packs on the account's own relay list could still be on their way.
        await library.installDefaultPacksIfNeeded()
        #expect(runtime.installStickerPackInputs.isEmpty)

        try await library.sync()
        await library.installDefaultPacksIfNeeded()
        #expect(
            runtime.installStickerPackInputs
                == StickerDefaultPacks.coordinates.map { StickerDefaultPacks.installInput(for: $0) })
        #expect(StickerDefaultPacks.coordinates.allSatisfy { library.isInstalled($0) })
        #expect(!library.isInstallingDefaults)

        await library.installDefaultPacksIfNeeded()
        #expect(runtime.installStickerPackInputs.count == StickerDefaultPacks.coordinates.count)
    }

    @MainActor
    @Test func aRemovedDefaultPackStaysRemoved() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.stickerPackStore = Self.defaultPacks()
        let ledger = try Self.isolatedLedger()
        let library = StickerLibrary(accountRef: "account", runtime: runtime, defaultPackLedger: ledger)
        try await library.sync()
        await library.installDefaultPacksIfNeeded()

        let removed = try #require(library.installed.first)
        try await library.uninstall(removed)
        let relaunched = StickerLibrary(accountRef: "account", runtime: runtime, defaultPackLedger: ledger)
        try await relaunched.sync()
        await relaunched.installDefaultPacksIfNeeded()

        #expect(!relaunched.isInstalled(removed.coordinate))
        #expect(runtime.installStickerPackInputs.count == StickerDefaultPacks.coordinates.count)
    }

    @MainActor
    @Test func aDefaultPackThatFailedToInstallIsTriedAgainNextTime() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.stickerPackStore = Self.defaultPacks()
        let failing = try #require(StickerDefaultPacks.coordinates.first)
        runtime.failingStickerInstalls = [failing]
        let ledger = try Self.isolatedLedger()
        let library = StickerLibrary(accountRef: "account", runtime: runtime, defaultPackLedger: ledger)
        try await library.sync()
        await library.installDefaultPacksIfNeeded()
        #expect(!library.isInstalled(failing))
        #expect(!ledger.offered(accountRef: "account").contains(failing))

        runtime.failingStickerInstalls = []
        await library.installDefaultPacksIfNeeded()
        #expect(library.isInstalled(failing))
        #expect(ledger.offered(accountRef: "account") == Set(StickerDefaultPacks.coordinates))
    }

    @MainActor
    @Test func aDefaultPackAlreadyOnTheAccountIsRecordedNotReinstalled() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        var packs = Self.defaultPacks()
        packs[0].installed = true
        runtime.stickerPackStore = packs
        let ledger = try Self.isolatedLedger()
        let library = StickerLibrary(accountRef: "account", runtime: runtime, defaultPackLedger: ledger)
        try await library.sync()
        await library.installDefaultPacksIfNeeded()

        #expect(runtime.installStickerPackInputs == [StickerDefaultPacks.installInput(for: packs[1].coordinate)])
        #expect(ledger.offered(accountRef: "account") == Set(StickerDefaultPacks.coordinates))
        #expect(ledger.offered(accountRef: "other").isEmpty)
    }

    @Test func eraseAppDataForgetsEveryAccountsDefaultPacks() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let ledger = StickerDefaultPackLedger(defaults: defaults)
        ledger.record(Set(StickerDefaultPacks.coordinates), accountRef: "one")
        ledger.record(Set(StickerDefaultPacks.coordinates), accountRef: "two")
        defaults.set(true, forKey: "unrelated")

        ledger.reset()
        #expect(ledger.offered(accountRef: "one").isEmpty)
        #expect(ledger.offered(accountRef: "two").isEmpty)
        #expect(defaults.bool(forKey: "unrelated"))
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
        #expect(runtime.sentStickers.first?.tags == [])
    }

    @MainActor
    @Test func aStickerSentWhileReplyingCarriesTheReplyTags() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let library = StickerLibrary(accountRef: "account", runtime: runtime)

        try await library.send(Self.sticker(), groupIdHex: "group", replyingTo: "target")

        #expect(runtime.sentStickers.first?.tags == [["e", "target"], ["q", "target"]])
    }

    @MainActor
    @Test func aPackShareLinkComesFromMDKForThatPack() throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let library = StickerLibrary(accountRef: "account", runtime: runtime)
        let pack = StickerPackFfi(
            coordinate: "30031:author:party", authorPubkeyHex: String(repeating: "a", count: 64), identifier: "party",
            eventIdHex: String(repeating: "b", count: 64), createdAt: 0, title: "Party", description: nil, cover: nil,
            stickers: [], license: nil, installed: true)

        #expect(try library.shareLink(for: pack) == "https://sonar.example/pack/30031:author:party")
        runtime.stickerPackShareLinkError = MarmotKitError.StickerNetwork(details: "no hints")
        #expect(throws: MarmotKitError.self) { try library.shareLink(for: pack) }
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
