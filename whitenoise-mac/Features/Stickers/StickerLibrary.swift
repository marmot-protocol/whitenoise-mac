import AppKit
import Foundation
import MarmotKit
import Observation

/// The account's sticker packs, as the picker, the pack browser and the timeline need them.
///
/// Owned by `AccountScope`, so an account switch discards every pack, image and in-flight read with
/// it instead of checking an account id after each await.
@MainActor
@Observable
final class StickerLibrary {
    private(set) var installed: [StickerPackFfi] = []
    private(set) var installedCoordinates: Set<String> = []
    private(set) var hasLoadedInstalled = false
    private(set) var isSyncing = false

    /// Decoded sticker images for this account.
    let assets: StickerAssetStore

    @ObservationIgnored private let accountRef: String
    /// Nil only for previews: nothing then reaches MDK.
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private var loadingInstalled: Task<Void, Never>?
    @ObservationIgnored private var syncing: Task<Void, Error>?
    @ObservationIgnored private var hasSynced = false

    init(accountRef: String, runtime: (any MarmotRuntime)?) {
        self.accountRef = accountRef
        self.runtime = runtime
        self.assets = StickerAssetStore(accountRef: accountRef, runtime: runtime)
    }

    /// A library with fixed installed packs and no runtime, for previews.
    static func preview(installed: [StickerPackFfi] = []) -> StickerLibrary {
        let library = StickerLibrary(accountRef: "preview", runtime: nil)
        library.installed = installed
        library.installedCoordinates = Set(installed.map(\.coordinate))
        library.hasLoadedInstalled = true
        return library
    }

    func isInstalled(_ coordinate: String) -> Bool {
        installedCoordinates.contains(coordinate)
    }

    /// Reads the installed packs once.
    func loadInstalledIfNeeded() async {
        if hasLoadedInstalled { return }
        if let loadingInstalled { return await loadingInstalled.value }
        let task = Task { await reloadInstalled() }
        loadingInstalled = task
        await task.value
        loadingInstalled = nil
    }

    func reloadInstalled() async {
        guard let packs = try? await readPacks(installedOnly: true, search: nil), !Task.isCancelled else { return }
        installed = packs
        installedCoordinates = Set(packs.map(\.coordinate))
        hasLoadedInstalled = true
    }

    /// Refreshes discovery and the installed list from relays: once per account unless `force`.
    /// The installed packs on screen stay usable if it fails. A caller arriving while a sync runs
    /// waits for that one and gets its outcome.
    func sync(force: Bool = false) async throws {
        if let syncing {
            try await syncing.value
            if !force { return }
        }
        guard force || !hasSynced, let runtime else { return }
        let task = Task { [accountRef] in
            _ = try await runtime.syncStickerPacks(accountRef: accountRef)
        }
        syncing = task
        isSyncing = true
        defer {
            if syncing == task {
                syncing = nil
                isSyncing = false
            }
        }
        try await task.value
        hasSynced = true
        await reloadInstalled()
    }

    /// Stored packs not yet installed, optionally matching `search`.
    func discover(search: String?) async throws -> [StickerPackFfi] {
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = try await readPacks(installedOnly: false, search: query?.isEmpty == false ? query : nil)
        return StickerPackPresentation.discoverable(found, installed: installedCoordinates)
    }

    func lookUp(_ input: String) async throws -> StickerPackFfi {
        try await requireRuntime().fetchStickerPack(accountRef: accountRef, input: input)
    }

    func install(_ pack: StickerPackFfi) async throws {
        _ = try await requireRuntime().installStickerPack(accountRef: accountRef, input: pack.coordinate)
        await reloadInstalled()
    }

    func uninstall(_ pack: StickerPackFfi) async throws {
        try await requireRuntime().uninstallStickerPack(accountRef: accountRef, input: pack.coordinate)
        await reloadInstalled()
    }

    /// Sends `sticker` to the group as its own kind-9 message.
    func send(_ sticker: StickerFfi, groupIdHex: String) async throws {
        _ = try await requireRuntime().sendSticker(
            accountRef: accountRef, groupIdHex: groupIdHex, stickerRef: StickerKey(sticker).ref)
    }

    /// The pack author as an abbreviated `npub`, or the abbreviated hex when it has none.
    func authorLabel(_ pack: StickerPackFfi) -> String {
        DisplayText.short(runtime?.npub(accountIdHex: pack.authorPubkeyHex) ?? pack.authorPubkeyHex)
    }

    private func requireRuntime() throws -> any MarmotRuntime {
        guard let runtime else { throw CancellationError() }
        return runtime
    }

    func stop() {
        loadingInstalled?.cancel()
        loadingInstalled = nil
        syncing?.cancel()
        syncing = nil
        isSyncing = false
        assets.cancelAll()
    }

    /// `stickerPacks` is a synchronous storage read, so it runs off the main actor.
    private func readPacks(installedOnly: Bool, search: String?) async throws -> [StickerPackFfi] {
        let runtime = try requireRuntime()
        let accountRef = accountRef
        return try await FFIExecutor.run {
            try runtime.stickerPacks(accountRef: accountRef, installedOnly: installedOnly, search: search, limit: 100)
        }
    }
}

/// Loads and caches decoded sticker images for one account.
///
/// MDK keeps no copy of a sticker image, so this keeps a bounded in-memory cache. Concurrent
/// requests for one sticker share one download. A failed load stays failed until an explicit
/// retry, so a broken sticker never re-dials its server from scrolling.
@MainActor
@Observable
final class StickerAssetStore {
    struct Loaded: Equatable {
        let image: NSImage
        let sticker: StickerFfi

        static func == (lhs: Loaded, rhs: Loaded) -> Bool {
            lhs.image === rhs.image && lhs.sticker == rhs.sticker
        }
    }

    /// How many decoded stickers stay in memory.
    static let imageLimit = 96
    /// Large enough for a timeline sticker at 2x.
    static let pixelSize: CGFloat = 320

    private(set) var images: [StickerKey: Loaded] = [:]
    private(set) var failures: Set<StickerKey> = []
    private(set) var loading: Set<StickerKey> = []

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private var order: [StickerKey] = []
    @ObservationIgnored private var tasks: [StickerKey: Task<Void, Never>] = [:]

    init(accountRef: String, runtime: (any MarmotRuntime)?) {
        self.accountRef = accountRef
        self.runtime = runtime
    }

    func image(for sticker: StickerKey) -> Loaded? {
        images[sticker]
    }

    func hasFailed(_ sticker: StickerKey) -> Bool {
        failures.contains(sticker)
    }

    func isLoading(_ sticker: StickerKey) -> Bool {
        loading.contains(sticker)
    }

    /// Downloads the sticker unless it is loaded, loading, or already failed.
    func load(_ sticker: StickerKey) {
        guard runtime != nil, images[sticker] == nil, !failures.contains(sticker), tasks[sticker] == nil else {
            return
        }
        loading.insert(sticker)
        tasks[sticker] = Task { [weak self] in
            await self?.fetch(sticker)
        }
    }

    /// Clears an earlier failure and downloads again, for an explicit click.
    func retry(_ sticker: StickerKey) {
        failures.remove(sticker)
        load(sticker)
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        loading.removeAll()
    }

    private func fetch(_ sticker: StickerKey) async {
        defer {
            tasks[sticker] = nil
            loading.remove(sticker)
        }
        let loaded: Loaded?
        do {
            guard let runtime else { throw CancellationError() }
            let asset = try await runtime.fetchStickerAsset(accountRef: accountRef, stickerRef: sticker.ref)
            let payload = DownloadedMediaPayload(id: "sticker-\(UUID().uuidString)", data: asset.bytes)
            loaded = await RemoteImageLoader.shared.image(for: payload, maxPixelSize: Self.pixelSize)
                .map { Loaded(image: $0.nsImage, sticker: asset.sticker) }
        } catch {
            loaded = nil
        }
        guard !Task.isCancelled else { return }
        guard let loaded else {
            failures.insert(sticker)
            return
        }
        if images.updateValue(loaded, forKey: sticker) == nil { order.append(sticker) }
        while order.count > Self.imageLimit {
            images[order.removeFirst()] = nil
        }
    }
}
