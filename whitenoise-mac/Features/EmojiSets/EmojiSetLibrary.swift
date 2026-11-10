import AppKit
import Foundation
import MarmotKit
import Observation

// NIP-51 emoji sets (kind 30030) are public Nostr events listing NIP-30 shortcodes and image URLs.
// Browsing them is text only. Opening a set previews its images and installing downloads every
// image once; both reveal this device's IP address to the hosts the set's author chose, so neither
// happens until the person opens or installs a set. Installed bytes live in MDK; sending one
// re-encrypts it into the chat like any custom emoji.

nonisolated enum EmojiSetPresentation {
    static func title(_ set: EmojiSetFfi) -> String {
        title(raw: set.title, identifier: set.identifier)
    }

    /// A picker section title for an installed emoji's set.
    static func title(_ emoji: InstalledCustomEmojiFfi) -> String {
        title(raw: emoji.setTitle, identifier: nil)
    }

    private static func title(raw: String?, identifier: String?) -> String {
        for candidate in [raw, identifier] {
            if let text = PeerDisplayText.sanitize(candidate) { return String(text.prefix(80)) }
        }
        return L10n.string("Emoji Set")
    }

    static func description(_ set: EmojiSetFfi) -> String? {
        PeerDisplayText.sanitize(set.description).map { String($0.prefix(500)) }
    }

    static func summary(_ set: EmojiSetFfi) -> String {
        L10n.plural("%lld emoji", Int64(set.emoji.count))
    }

    /// Entries MDK set aside (bad shortcode or URL, duplicates, over the cap, failed downloads).
    /// Nil when every entry is usable.
    static func skippedNote(_ set: EmojiSetFfi) -> String? {
        let count = max(Int(set.skippedCount), set.skipped.count)
        guard count > 0 else { return nil }
        return L10n.plural("%lld emoji in this set can’t be used.", Int64(count))
    }

    /// Emoji in the set whose shortcode chat messages can't carry; they stay installed but are left
    /// out of the picker.
    static func unsendableCount(_ set: EmojiSetFfi) -> Int {
        set.emoji.count { !CustomEmojiSendPolicy.isSendable($0.shortcode) }
    }

    /// A pasted coordinate or `naddr`, trimmed and bounded. MDK validates it.
    static func lookupInput(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048 else { return nil }
        return trimmed
    }

    /// Whether a search names an author, which MDK can fetch from relays rather than only filter
    /// what is already stored. Only a complete npub or hex key counts, so typing one doesn't fetch
    /// at each keystroke.
    static func searchNamesAuthor(_ search: String) -> Bool {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("npub1") {
            let charset = Set("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
            return trimmed.count == 63 && trimmed.dropFirst(5).allSatisfy { charset.contains($0) }
        }
        return trimmed.utf8.count == 64
            && trimmed.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Sets to offer: not installed and with at least one usable emoji.
    static func discoverable(_ sets: [EmojiSetFfi], installed: Set<String>) -> [EmojiSetFfi] {
        sets.filter { $0.installed == nil && !installed.contains($0.coordinate) && !$0.emoji.isEmpty }
    }

    /// Sets the account's public emoji list (kind 10030) names that aren't installed here yet, in
    /// list order.
    static func suggestions(_ list: UserEmojiListFfi, installed: Set<String>) -> [EmojiSetFfi] {
        var seen = Set<String>()
        return discoverable(list.sets, installed: installed).filter { seen.insert($0.coordinate).inserted }
    }

    enum Action: Equatable {
        case install
        /// A newer version than the installed one is stored.
        case update
        case remove
    }

    /// `isInstalled` is the library's live answer; the set's own state can be stale after an
    /// uninstall elsewhere.
    static func action(for set: EmojiSetFfi, isInstalled: Bool) -> Action {
        guard isInstalled else { return .install }
        return set.installed?.updateAvailable == true ? .update : .remove
    }

    /// Install progress, or nil while MDK hasn't counted the set yet.
    static func fraction(_ progress: EmojiSetInstallProgressFfi) -> Double? {
        guard progress.totalEmoji > 0 else { return nil }
        return min(1, Double(progress.completedEmoji) / Double(progress.totalEmoji))
    }

    /// A cancelled install is the person's own choice, not an error to show.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? MarmotKitError, case .EmojiSetInstallCancelled = error { return true }
        return false
    }

    /// The version MDK says is stored now when the shown one went stale.
    static func changedVersion(_ error: Error) -> String? {
        guard let error = error as? MarmotKitError, case .EmojiSetChanged(let current) = error else { return nil }
        return current
    }

    /// The upload file extension for an installed emoji's validated MIME type.
    static func fileExtension(mime: String) -> String {
        switch mime.lowercased() {
        case "image/png", "image/apng": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/jpeg", "image/jpg": "jpg"
        default: "img"
        }
    }
}

/// The account's emoji sets: installed sets and emoji for the pickers and composer, discovery for
/// the browser, and installs in progress.
///
/// Owned by `AccountScope`, so an account switch discards every set, image and install with it
/// instead of checking an account id after each await.
@MainActor
@Observable
final class EmojiSetLibrary {
    private(set) var installedSets: [EmojiSetFfi] = []
    /// Installed emoji in MDK's order: set install order, then set order.
    private(set) var installedEmoji: [InstalledCustomEmojiFfi] = []
    private(set) var hasLoadedInstalled = false
    private(set) var isSyncing = false
    /// Installs in progress, by set coordinate.
    private(set) var installProgress: [String: EmojiSetInstallProgressFfi] = [:]

    let images: EmojiSetImageStore

    @ObservationIgnored private let accountRef: String
    /// Nil only for previews: nothing then reaches MDK.
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private let progressInterval: Duration
    @ObservationIgnored private var loadingInstalled: Task<Void, Never>?
    @ObservationIgnored private var syncing: Task<Void, Error>?
    @ObservationIgnored private var hasSynced = false
    @ObservationIgnored private var controls: [String: EmojiSetInstallControlFfi] = [:]

    init(accountRef: String, runtime: (any MarmotRuntime)?, progressInterval: Duration = .milliseconds(200)) {
        self.accountRef = accountRef
        self.runtime = runtime
        self.progressInterval = progressInterval
        images = EmojiSetImageStore(accountRef: accountRef, runtime: runtime)
    }

    /// A library with fixed installed sets and no runtime, for previews.
    static func preview(installed: [EmojiSetFfi] = []) -> EmojiSetLibrary {
        let library = EmojiSetLibrary(accountRef: "preview", runtime: nil)
        library.installedSets = installed
        library.hasLoadedInstalled = true
        return library
    }

    func isInstalled(_ coordinate: String) -> Bool {
        installedSets.contains { $0.coordinate == coordinate }
    }

    func loadInstalledIfNeeded() async {
        if hasLoadedInstalled { return }
        if let loadingInstalled { return await loadingInstalled.value }
        let task = Task { await reloadInstalled() }
        loadingInstalled = task
        await task.value
        loadingInstalled = nil
    }

    /// Re-reads installed sets and emoji. Local only. A failed read keeps what is on screen.
    func reloadInstalled() async {
        guard let runtime else { return }
        do {
            async let sets = runtime.emojiSets(accountRef: accountRef, installedOnly: true, search: nil, limit: 200)
            async let emoji = runtime.installedCustomEmoji(accountRef: accountRef)
            let (loadedSets, loadedEmoji) = try await (sets, emoji)
            guard !Task.isCancelled else { return }
            installedSets = loadedSets
            installedEmoji = loadedEmoji
            hasLoadedInstalled = true
        } catch {
            return
        }
    }

    /// Fetches the newest sets from relays (text only), once per account unless forced. A search
    /// naming an author always fetches that author's sets. A caller arriving mid-sync shares its
    /// outcome.
    func sync(force: Bool = false, search: String? = nil) async throws {
        guard let runtime else { return }
        if let search, EmojiSetPresentation.searchNamesAuthor(search) {
            _ = try await runtime.syncEmojiSets(
                accountRef: accountRef, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        if let syncing {
            try await syncing.value
            if !force { return }
        }
        guard force || !hasSynced else { return }
        let task = Task { [accountRef] in
            _ = try await runtime.syncEmojiSets(accountRef: accountRef, search: nil)
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

    func discover(search: String?) async throws -> [EmojiSetFfi] {
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = try await requireRuntime().emojiSets(
            accountRef: accountRef, installedOnly: false, search: query?.isEmpty == false ? query : nil, limit: 200)
        return EmojiSetPresentation.discoverable(found, installed: Set(installedSets.map(\.coordinate)))
    }

    /// Sets the account's own emoji list points to. Text only.
    func suggestions() async throws -> [EmojiSetFfi] {
        let list = try await requireRuntime().userEmojiList(accountRef: accountRef)
        return EmojiSetPresentation.suggestions(list, installed: Set(installedSets.map(\.coordinate)))
    }

    func lookUp(_ input: String) async throws -> EmojiSetFfi {
        try await requireRuntime().fetchEmojiSet(accountRef: accountRef, input: input)
    }

    /// The stored version of a set now, for a screen whose copy went stale.
    func current(_ coordinate: String) async throws -> EmojiSetFfi? {
        try await requireRuntime().emojiSet(accountRef: accountRef, coordinate: coordinate)
    }

    /// Downloads and stores the version shown (`set.eventIdHex`), also to apply an update.
    /// Progress is published in `installProgress`.
    @discardableResult
    func install(_ set: EmojiSetFfi) async throws -> EmojiSetInstallResultFfi {
        let runtime = try requireRuntime()
        let coordinate = set.coordinate
        guard controls[coordinate] == nil else { throw CancellationError() }
        let control = EmojiSetInstallControlFfi()
        controls[coordinate] = control
        installProgress[coordinate] = EmojiSetInstallProgressFfi(
            completedEmoji: 0, totalEmoji: UInt32(clamping: set.emoji.count), transferredBytes: 0)
        let interval = progressInterval
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.controls[coordinate] === control else { return }
                self.installProgress[coordinate] = control.progress()
            }
        }
        defer {
            poll.cancel()
            if controls[coordinate] === control {
                controls[coordinate] = nil
                installProgress[coordinate] = nil
            }
        }
        let result = try await runtime.installEmojiSet(
            accountRef: accountRef, coordinate: coordinate, expectedEventIdHex: set.eventIdHex, control: control)
        images.forget(setCoordinate: coordinate)
        await reloadInstalled()
        return result
    }

    func cancelInstall(_ coordinate: String) {
        controls[coordinate]?.cancel()
    }

    func uninstall(_ coordinate: String) async throws {
        _ = try await requireRuntime().uninstallEmojiSet(accountRef: accountRef, coordinate: coordinate)
        images.forget(setCoordinate: coordinate)
        await reloadInstalled()
    }

    /// The set author as an abbreviated `npub`, or the abbreviated hex when it has none.
    func authorLabel(_ set: EmojiSetFfi) -> String {
        DisplayText.short(runtime?.npub(accountIdHex: set.authorPubkeyHex) ?? set.authorPubkeyHex)
    }

    func stop() {
        loadingInstalled?.cancel()
        loadingInstalled = nil
        syncing?.cancel()
        syncing = nil
        isSyncing = false
        for control in controls.values { control.cancel() }
        controls.removeAll()
        installProgress.removeAll()
        images.cancelAll()
    }

    private func requireRuntime() throws -> any MarmotRuntime {
        guard let runtime else { throw CancellationError() }
        return runtime
    }
}

/// Decoded emoji-set images: installed emoji read from MDK's local store, and previews of a set the
/// person opened. Bounded, and a failed load stays failed until an explicit retry, so scrolling
/// never re-dials a broken host.
@MainActor
@Observable
final class EmojiSetImageStore {
    enum Source: Hashable {
        case installed(coordinate: String, shortcode: String, sha256: String)
        case preview(coordinate: String, eventIdHex: String, shortcode: String)

        var coordinate: String {
            switch self {
            case .installed(let coordinate, _, _), .preview(let coordinate, _, _): coordinate
            }
        }

        static func installed(_ emoji: InstalledCustomEmojiFfi) -> Source {
            .installed(coordinate: emoji.setCoordinate, shortcode: emoji.shortcode, sha256: emoji.sha256)
        }
    }

    static let limit = 256
    /// Large enough for a picker cell or a preview grid at 2x.
    static let pixelSize: CGFloat = 128

    private(set) var images: [Source: NSImage] = [:]
    private(set) var failures: Set<Source> = []

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private var order: [Source] = []
    @ObservationIgnored private var tasks: [Source: Task<Void, Never>] = [:]

    init(accountRef: String, runtime: (any MarmotRuntime)?) {
        self.accountRef = accountRef
        self.runtime = runtime
    }

    func image(for source: Source) -> NSImage? {
        images[source]
    }

    func hasFailed(_ source: Source) -> Bool {
        failures.contains(source)
    }

    /// Loads the image unless it is loaded, loading, or already failed.
    func load(_ source: Source) {
        guard let runtime, images[source] == nil, !failures.contains(source), tasks[source] == nil else { return }
        let accountRef = accountRef
        tasks[source] = Task { [weak self] in
            let data: Data?
            do {
                switch source {
                case .installed(let coordinate, let shortcode, _):
                    data = try await runtime.readInstalledCustomEmoji(
                        accountRef: accountRef, coordinate: coordinate, shortcode: shortcode
                    ).bytes
                case .preview(let coordinate, let eventIdHex, let shortcode):
                    data = try await runtime.fetchEmojiSetAsset(
                        accountRef: accountRef, coordinate: coordinate, expectedEventIdHex: eventIdHex,
                        shortcode: shortcode
                    ).bytes
                }
            } catch {
                data = nil
            }
            let image: NSImage? =
                if let data {
                    await RemoteImageLoader.shared.image(
                        for: DownloadedMediaPayload(id: "emoji-set-\(UUID().uuidString)", data: data),
                        maxPixelSize: Self.pixelSize
                    )?.nsImage
                } else { nil }
            self?.finish(source, image: image)
        }
    }

    /// Clears an earlier failure and loads again, for an explicit click.
    func retry(_ source: Source) {
        failures.remove(source)
        load(source)
    }

    /// Drops a set's images so a reinstall or update reads fresh bytes.
    func forget(setCoordinate: String) {
        images = images.filter { $0.key.coordinate != setCoordinate }
        order.removeAll { $0.coordinate == setCoordinate }
        failures = failures.filter { $0.coordinate != setCoordinate }
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func finish(_ source: Source, image: NSImage?) {
        guard tasks.removeValue(forKey: source) != nil, !Task.isCancelled else { return }
        guard let image else {
            failures.insert(source)
            return
        }
        if images.updateValue(image, forKey: source) == nil { order.append(source) }
        while order.count > Self.limit {
            images[order.removeFirst()] = nil
        }
    }
}
