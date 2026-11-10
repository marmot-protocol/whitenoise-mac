import AppKit
import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// NIP-51 emoji sets: what the browser offers, installs with progress and cancel, and the images
/// it loads (installed bytes from MDK, previews only for a set the person opened).
struct EmojiSetTests {
    private static let coordinate = "30030:author:blobs"
    private static let eventId = String(repeating: "e", count: 64)

    private static func set(
        _ coordinate: String = coordinate, title: String? = "Blobs", shortcodes: [String] = ["blob", "wave"],
        installed: Bool = false, updateAvailable: Bool = false, skippedCount: UInt32 = 0
    ) -> EmojiSetFfi {
        EmojiSetFfi(
            coordinate: coordinate, kind: 30030, authorPubkeyHex: String(repeating: "a", count: 64),
            identifier: "blobs", eventIdHex: eventId, createdAt: 0, title: title, description: nil, imageUrl: nil,
            emoji: shortcodes.map { EmojiSetEmojiFfi(shortcode: $0, url: "https://x.invalid/\($0).png") },
            skipped: [], skippedCount: skippedCount,
            installed: installed
                ? InstalledEmojiSetStateFfi(
                    eventIdHex: eventId, createdAt: 0, installedAt: 1, emojiCount: UInt32(shortcodes.count),
                    byteLen: 0, updateAvailable: updateAvailable)
                : nil)
    }

    private static func png() throws -> Data {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    // MARK: - Presentation

    @Test func aBlankTitleFallsBackToTheIdentifierThenAGenericName() {
        #expect(EmojiSetPresentation.title(Self.set(title: " \n")) == "blobs")
        #expect(EmojiSetPresentation.title(Self.set(title: "Party")) == "Party")
    }

    @Test func discoveryOffersOnlyUninstalledSetsWithEmoji() {
        let sets = [
            Self.set("a", installed: true),
            Self.set("b"),
            Self.set("c", shortcodes: []),
            Self.set("d"),
        ]

        #expect(EmojiSetPresentation.discoverable(sets, installed: ["d"]).map(\.coordinate) == ["b"])
    }

    @Test func theSetsActionFollowsTheLibraryAndAnAvailableUpdate() {
        #expect(EmojiSetPresentation.action(for: Self.set(installed: true), isInstalled: false) == .install)
        #expect(EmojiSetPresentation.action(for: Self.set(installed: true), isInstalled: true) == .remove)
        #expect(
            EmojiSetPresentation.action(for: Self.set(installed: true, updateAvailable: true), isInstalled: true)
                == .update)
    }

    @Test func onlyACompleteKeyCountsAsAnAuthorSearch() {
        #expect(EmojiSetPresentation.searchNamesAuthor(String(repeating: "ab", count: 32)))
        #expect(EmojiSetPresentation.searchNamesAuthor("npub1" + String(repeating: "q", count: 58)))
        #expect(!EmojiSetPresentation.searchNamesAuthor("npub1qqq"))
        #expect(!EmojiSetPresentation.searchNamesAuthor("cats"))
    }

    @Test func notesCountSkippedAndUnsendableEmoji() {
        let set = Self.set(shortcodes: ["ok", String(repeating: "x", count: 63)], skippedCount: 2)

        #expect(EmojiSetPresentation.skippedNote(set) != nil)
        #expect(EmojiSetPresentation.skippedNote(Self.set()) == nil)
        #expect(EmojiSetPresentation.unsendableCount(set) == 1)
    }

    @Test func progressHasNoFractionUntilMDKCountsTheSet() {
        #expect(
            EmojiSetPresentation.fraction(
                EmojiSetInstallProgressFfi(completedEmoji: 0, totalEmoji: 0, transferredBytes: 0)) == nil)
        #expect(
            EmojiSetPresentation.fraction(
                EmojiSetInstallProgressFfi(completedEmoji: 1, totalEmoji: 4, transferredBytes: 0)) == 0.25)
        #expect(EmojiSetPresentation.isCancellation(MarmotKitError.EmojiSetInstallCancelled))
        #expect(EmojiSetPresentation.changedVersion(MarmotKitError.EmojiSetChanged(currentEventIdHex: "n")) == "n")
    }

    // MARK: - Library

    @MainActor
    @Test func installingASetAddsItsEmojiAndRemovingDropsThem() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.emojiSetStore = [Self.set()]
        runtime.emojiSetAssetBytes = ["blob": Data("b".utf8), "wave": Data("w".utf8)]
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)

        await library.loadInstalledIfNeeded()
        #expect(library.installedEmoji.isEmpty)
        #expect(try await library.discover(search: nil).map(\.coordinate) == [Self.coordinate])

        try await library.install(Self.set())
        #expect(library.isInstalled(Self.coordinate))
        #expect(library.installedEmoji.map(\.shortcode) == ["blob", "wave"])
        #expect(library.installProgress.isEmpty)
        #expect(try await library.discover(search: nil).isEmpty)

        try await library.uninstall(Self.coordinate)
        #expect(!library.isInstalled(Self.coordinate))
        #expect(library.installedEmoji.isEmpty)
    }

    @MainActor
    @Test func aCancelledInstallStoresNothingAndClearsItsProgress() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.emojiSetStore = [Self.set()]
        runtime.installEmojiSetGate.isEnabled = true
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)

        let install = Task { try await library.install(Self.set()) }
        await runtime.installEmojiSetGate.waitUntilReached()
        #expect(library.installProgress[Self.coordinate]?.totalEmoji == 2)
        library.cancelInstall(Self.coordinate)
        runtime.installEmojiSetGate.release()

        await #expect(throws: MarmotKitError.self) { try await install.value }
        #expect(library.installProgress.isEmpty)
        #expect(!library.isInstalled(Self.coordinate))
    }

    @MainActor
    @Test func relaysAreSyncedOnceUnlessForcedButAnAuthorSearchAlwaysFetches() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)

        try await library.sync()
        try await library.sync()
        #expect(runtime.syncEmojiSetsCallCount == 1)

        try await library.sync(search: String(repeating: "ab", count: 32))
        try await library.sync(force: true)
        #expect(runtime.syncEmojiSetsCallCount == 3)
    }

    @MainActor
    @Test func suggestionsAreTheEmojiListsSetsNotYetInstalled() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.emojiSetStore = [Self.set("installed", installed: true)]
        runtime.userEmojiListSets = [Self.set("installed"), Self.set("new"), Self.set("new")]
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        await library.reloadInstalled()

        #expect(try await library.suggestions().map(\.coordinate) == ["new"])
    }

    // MARK: - Images

    @MainActor
    @Test func anInstalledEmojiImageIsReadFromMDKOnce() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.emojiSetStore = [Self.set()]
        runtime.emojiSetAssetBytes = ["blob": try Self.png(), "wave": try Self.png()]
        let library = EmojiSetLibrary(accountRef: "account", runtime: runtime)
        try await library.install(Self.set())
        let source = EmojiSetImageStore.Source.installed(try #require(library.installedEmoji.first))

        library.images.load(source)
        library.images.load(source)

        #expect(await waitFor { library.images.image(for: source) != nil })
        #expect(!library.images.hasFailed(source))
    }

    @MainActor
    @Test func aFailedPreviewStaysFailedUntilAnExplicitRetry() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.emojiSetStore = [Self.set()]
        let store = EmojiSetImageStore(accountRef: "account", runtime: runtime)
        let source = EmojiSetImageStore.Source.preview(
            coordinate: Self.coordinate, eventIdHex: Self.eventId, shortcode: "blob")

        store.load(source)
        #expect(await waitFor { store.hasFailed(source) })
        runtime.emojiSetAssetBytes["blob"] = try Self.png()
        store.load(source)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.image(for: source) == nil)

        store.retry(source)
        #expect(await waitFor { store.image(for: source) != nil })
    }
}
