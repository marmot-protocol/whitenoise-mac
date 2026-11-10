import MarmotKit
import SwiftUI

nonisolated enum StickerMetrics {
    static let messageSide: CGFloat = 150
    static let gridMinimum: CGFloat = 76
    static let packTabSide: CGFloat = 30
    static let popoverWidth: CGFloat = 400
    static let popoverHeight: CGFloat = 440
}

// MARK: - Images

/// One sticker image. Loads by itself only when `loadsAutomatically`; otherwise a click loads it,
/// since loading contacts the server the pack's author chose.
struct StickerImage: View {
    let store: StickerAssetStore
    let sticker: StickerKey
    let loadsAutomatically: Bool
    var placeholderLabel: String?

    var body: some View {
        Group {
            if let loaded = store.image(for: sticker) {
                Image(nsImage: loaded.image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(
                        StickerLoadPolicy.accessibilityLabel(alt: loaded.sticker.alt, emoji: loaded.sticker.emoji))
            } else {
                StickerPlaceholder(
                    phase: phase,
                    label: placeholderLabel,
                    onLoad: { store.retry(sticker) }
                )
            }
        }
        .task(id: StickerLoadRequest(sticker: sticker, automatic: loadsAutomatically)) {
            if loadsAutomatically { store.load(sticker) }
        }
    }

    private var phase: StickerPlaceholder.Phase {
        if store.isLoading(sticker) { return .loading }
        if store.hasFailed(sticker) { return .failed }
        return loadsAutomatically ? .loading : .waitingForClick
    }
}

private struct StickerLoadRequest: Equatable {
    let sticker: StickerKey
    let automatic: Bool
}

private struct StickerPlaceholder: View {
    enum Phase { case loading, waitingForClick, failed }

    let phase: Phase
    let label: String?
    let onLoad: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        switch phase {
        case .loading:
            shape.fill(WNColor.fillSecondary)
                .overlay { ProgressView().controlSize(.small) }
        case .waitingForClick, .failed:
            Button(action: onLoad) {
                VStack(spacing: 6) {
                    Image(systemName: phase == .failed ? "exclamationmark.triangle" : "face.dashed")
                        .wnFont(.medium18)
                    Text(phase == .failed ? L10n.string("Click to retry") : (label ?? L10n.string("Click to load")))
                        .wnFont(.medium10)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(WNColor.fillSecondary))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .help(L10n.string("Loads the sticker from the server its pack uses."))
        }
    }
}

/// A sticker message's sticker: the image alone, without a bubble.
struct MessageStickerView: View {
    let library: StickerLibrary
    let loadingPreference: StickerLoadingPreference
    let sticker: StickerKey
    let isOutgoing: Bool

    var body: some View {
        StickerImage(
            store: library.assets,
            sticker: sticker,
            loadsAutomatically: StickerLoadPolicy.loadsAutomatically(
                isFromMe: isOutgoing,
                packInstalled: library.isInstalled(sticker.packCoordinate),
                loadsEverySticker: loadingPreference.automaticallyLoads
            ),
            placeholderLabel: L10n.string("Click to load sticker")
        )
        .frame(width: StickerMetrics.messageSide, height: StickerMetrics.messageSide)
        .task { await library.loadInstalledIfNeeded() }
        .accessibilityIdentifier("message.sticker")
    }
}

// MARK: - Picker

/// The composer's sticker picker, shown in the `+` popover: installed packs as tabs over a grid,
/// with the pack browser and each pack's page pushed on top. Clicking a sticker sends it.
struct StickerPickerPopover: View {
    let library: StickerLibrary
    let send: (StickerFfi) async throws -> Void
    let onDismiss: () -> Void

    @State private var path: [StickerPickerRoute] = []

    var body: some View {
        Group {
            switch path.last {
            case nil:
                StickerPickerPage(
                    library: library,
                    send: send,
                    onDismiss: onDismiss,
                    onBrowse: { path.append(.browser) }
                )
            case .browser:
                StickerPackBrowserPage(
                    library: library,
                    onOpen: { path.append(.pack($0)) },
                    onBack: { path.removeLast() }
                )
            case .pack(let pack):
                StickerPackDetailPage(library: library, pack: pack, onBack: { path.removeLast() })
            }
        }
        .frame(width: StickerMetrics.popoverWidth, height: StickerMetrics.popoverHeight)
    }
}

private enum StickerPickerRoute: Hashable {
    case browser
    case pack(StickerPackFfi)
}

/// A page title with an optional Back button and trailing control.
struct StickerPageHeader<Trailing: View>: View {
    let title: String
    var onBack: (() -> Void)?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .wnFont(.semiBold14)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Back"))
                .accessibilityLabel(L10n.string("Back"))
            }
            Text(title)
                .wnFont(.semiBold14)
                .lineLimit(1)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct StickerPickerPage: View {
    let library: StickerLibrary
    let send: (StickerFfi) async throws -> Void
    let onDismiss: () -> Void
    let onBrowse: () -> Void

    @State private var selectedPack: String?
    @State private var sending: StickerKey?
    @State private var sendError: String?

    var body: some View {
        VStack(spacing: 0) {
            StickerPageHeader(title: L10n.string("Stickers")) {
                Button(action: onBrowse) {
                    Label(L10n.string("Sticker Packs"), systemImage: "plus")
                        .wnFont(.medium12)
                }
                .buttonStyle(.wnSecondary)
                .controlSize(.small)
                .accessibilityIdentifier("stickers.browse")
            }

            if !library.hasLoadedInstalled {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pack = currentPack {
                if library.installed.count > 1 {
                    StickerPackTabs(library: library, current: pack.coordinate) { selectedPack = $0 }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(StickerPackPresentation.title(pack))
                            .wnFont(.semiBold12)
                        if let sendError {
                            Text(sendError)
                                .wnFont(.medium12)
                                .foregroundStyle(WNColor.intentionErrorContent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        StickerGrid(store: library.assets, stickers: pack.stickers, sending: sending, onSelect: select)
                        StickerEgressDisclosure()
                    }
                    .padding(14)
                }
            } else {
                VStack(spacing: 12) {
                    WNEmptyStateView(
                        title: L10n.string("No Stickers"),
                        description: L10n.string("Add a sticker pack to send stickers."),
                        systemImage: "face.dashed"
                    )
                    Button(L10n.string("Browse Sticker Packs"), action: onBrowse)
                        .buttonStyle(.wnSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await library.loadInstalledIfNeeded()
            try? await library.sync()
        }
    }

    private var currentPack: StickerPackFfi? {
        library.installed.first { $0.coordinate == selectedPack } ?? library.installed.first
    }

    private func select(_ sticker: StickerFfi) {
        guard sending == nil else { return }
        sending = StickerKey(sticker)
        sendError = nil
        Task {
            defer { sending = nil }
            do {
                try await send(sticker)
                onDismiss()
            } catch is CancellationError {
                return
            } catch {
                sendError = UserFacingError.message(for: error)
            }
        }
    }
}

private struct StickerPackTabs: View {
    let library: StickerLibrary
    let current: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(library.installed, id: \.coordinate) { pack in
                    StickerPackTab(
                        store: library.assets, pack: pack, isSelected: pack.coordinate == current,
                        onSelect: { onSelect(pack.coordinate) })
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct StickerPackTab: View {
    let store: StickerAssetStore
    let pack: StickerPackFfi
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Group {
                if let cover = pack.cover ?? pack.stickers.first {
                    StickerImage(store: store, sticker: StickerKey(cover), loadsAutomatically: true)
                } else {
                    Image(systemName: "face.dashed")
                }
            }
            .frame(width: StickerMetrics.packTabSide, height: StickerMetrics.packTabSide)
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? WNColor.fillSecondary : .clear)
            )
        }
        .buttonStyle(.plain)
        .help(StickerPackPresentation.title(pack))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StickerPackPresentation.title(pack))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct StickerGrid: View {
    let store: StickerAssetStore
    let stickers: [StickerFfi]
    var sending: StickerKey?
    var onSelect: ((StickerFfi) -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: StickerMetrics.gridMinimum), spacing: 10)], spacing: 10) {
            ForEach(stickers, id: \.shortcode) { sticker in
                StickerGridCell(
                    store: store, sticker: sticker, isSending: sending == StickerKey(sticker),
                    isDisabled: sending != nil, onSelect: onSelect.map { select in { select(sticker) } })
            }
        }
    }
}

private struct StickerGridCell: View {
    let store: StickerAssetStore
    let sticker: StickerFfi
    let isSending: Bool
    let isDisabled: Bool
    let onSelect: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        let image = StickerImage(store: store, sticker: StickerKey(sticker), loadsAutomatically: true)
            .frame(height: StickerMetrics.gridMinimum)
            .overlay {
                if isSending { ProgressView().controlSize(.small) }
            }
        if let onSelect {
            Button(action: onSelect) {
                image
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isHovering ? WNColor.fillSecondaryHover : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .onHover { isHovering = $0 }
            .help(StickerLoadPolicy.accessibilityLabel(alt: sticker.alt, emoji: sticker.emoji))
            .accessibilityLabel(StickerLoadPolicy.accessibilityLabel(alt: sticker.alt, emoji: sticker.emoji))
            .accessibilityHint(L10n.string("Sends this sticker"))
        } else {
            image
        }
    }
}

private struct StickerEgressDisclosure: View {
    var body: some View {
        Text(L10n.string("Stickers load from servers each pack’s author chose. Those servers can see your IP address."))
            .wnFont(.medium10)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Browsing and installing

private struct StickerPackBrowserPage: View {
    let library: StickerLibrary
    let onOpen: (StickerPackFfi) -> Void
    let onBack: () -> Void

    @State private var search = ""
    @State private var link = ""
    @State private var discovered: [StickerPackFfi] = []
    @State private var isLoading = false
    @State private var syncError: String?
    @State private var isLookingUp = false
    @State private var errorMessage: String?
    @State private var reloadRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            StickerPageHeader(title: L10n.string("Sticker Packs"), onBack: onBack) {
                if library.isSyncing { ProgressView().controlSize(.small) }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StickerBrowserSection(
                        title: L10n.string("Add by Link"),
                        footer: L10n.string("Paste a Sonar sticker pack link or an naddr.")
                    ) {
                        HStack(spacing: 8) {
                            TextField(L10n.string("Sticker pack link"), text: $link)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(lookUp)
                                .accessibilityIdentifier("stickers.link")
                            Button(L10n.string("Open Link"), action: lookUp)
                                .buttonStyle(.wnSecondary)
                                .controlSize(.small)
                                .disabled(StickerPackPresentation.lookupInput(link) == nil || isLookingUp)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.intentionErrorContent)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !library.installed.isEmpty {
                        StickerBrowserSection(title: L10n.string("Installed")) {
                            ForEach(library.installed, id: \.coordinate) { pack in
                                StickerPackRow(pack: pack) { onOpen(pack) }
                            }
                        }
                    }

                    StickerBrowserSection(
                        title: L10n.string("Discover"),
                        footer: L10n.string(
                            "Sticker packs are public and aren’t reviewed by White Noise. Your installed packs are listed publicly on your relays."
                        )
                    ) {
                        TextField(L10n.string("Search sticker packs"), text: $search)
                            .textFieldStyle(.roundedBorder)
                        StickerDiscoverList(
                            state: StickerPackPresentation.discoveryState(
                                isLoading: isLoading, packCount: discovered.count, search: search,
                                syncError: syncError),
                            packs: discovered,
                            onOpen: onOpen,
                            onRetry: { reloadRequest += 1 }
                        )
                    }
                }
                .padding(14)
            }
        }
        .task(id: StickerDiscoverRequest(search: search, reload: reloadRequest)) {
            await reloadDiscovered(debounce: !search.isEmpty, forceSync: reloadRequest > 0)
        }
    }

    private func reloadDiscovered(debounce: Bool, forceSync: Bool) async {
        if debounce {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            do {
                try await library.sync(force: forceSync)
                syncError = nil
            } catch is CancellationError {
                return
            } catch {
                syncError = UserFacingError.message(for: error)
            }
            let packs = try await library.discover(search: search)
            guard !Task.isCancelled else { return }
            discovered = packs
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = UserFacingError.message(for: error)
        }
    }

    private func lookUp() {
        guard let input = StickerPackPresentation.lookupInput(link), !isLookingUp else { return }
        isLookingUp = true
        errorMessage = nil
        Task {
            defer { isLookingUp = false }
            do {
                let pack = try await library.lookUp(input)
                link = ""
                onOpen(pack)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }
}

private struct StickerDiscoverRequest: Equatable {
    let search: String
    let reload: Int
}

struct StickerBrowserSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .wnFont(.semiBold12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            content
            if let footer {
                Text(footer)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StickerDiscoverList: View {
    let state: StickerPackPresentation.DiscoveryState
    let packs: [StickerPackFfi]
    let onOpen: (StickerPackFfi) -> Void
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        case .packs:
            ForEach(packs, id: \.coordinate) { pack in
                StickerPackRow(pack: pack) { onOpen(pack) }
            }
        case .noneOnRelays:
            StickerBrowserNote(
                text: L10n.string("Your relays don’t have any sticker packs yet. Paste a pack link above to add one."))
        case .noMatches:
            StickerBrowserNote(text: L10n.string("No sticker packs match your search."))
        case .unreachable(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Couldn’t check your relays for sticker packs."))
                    .wnFont(.medium12)
                StickerBrowserNote(text: message)
                Button(L10n.string("Try Again"), action: onRetry)
                    .buttonStyle(.wnSecondary)
                    .controlSize(.small)
            }
        }
    }
}

struct StickerBrowserNote: View {
    let text: String

    var body: some View {
        Text(text)
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A pack as text only: its artwork loads once the pack is opened.
private struct StickerPackRow: View {
    let pack: StickerPackFfi
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(StickerPackPresentation.title(pack))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                        .lineLimit(1)
                    Text(StickerPackPresentation.summary(pack))
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isHovering ? WNColor.fillSecondaryHover : .clear,
                in: .rect(cornerRadius: 6)
            )
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

struct StickerPackDetailPage: View {
    let library: StickerLibrary
    let pack: StickerPackFfi
    let onBack: () -> Void

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        let isInstalled = library.isInstalled(pack.coordinate)
        VStack(spacing: 0) {
            StickerPageHeader(title: StickerPackPresentation.title(pack), onBack: onBack) {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(isInstalled ? L10n.string("Remove") : L10n.string("Add")) {
                        toggleInstall(installing: !isInstalled)
                    }
                    .buttonStyle(.wnSecondary)
                    .controlSize(.small)
                    .accessibilityIdentifier("stickers.pack.toggleInstall")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(StickerPackPresentation.summary(pack))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                    Text(String(format: L10n.string("By %@"), library.authorLabel(pack)))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(1)
                    if let description = StickerPackPresentation.description(pack) {
                        Text(description)
                            .wnFont(.medium12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.intentionErrorContent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    StickerGrid(store: library.assets, stickers: pack.stickers)
                    StickerEgressDisclosure()
                }
                .padding(14)
            }
        }
    }

    private func toggleInstall(installing: Bool) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                if installing {
                    try await library.install(pack)
                } else {
                    try await library.uninstall(pack)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }
}

// MARK: - Previews

private enum StickerPreviewData {
    static let pack = StickerPackFfi(
        coordinate: "30031:author:party",
        authorPubkeyHex: String(repeating: "a", count: 64),
        identifier: "party",
        eventIdHex: String(repeating: "b", count: 64),
        createdAt: 0,
        title: "Party Animals",
        description: "A few animals having a good time.",
        cover: nil,
        stickers: (1...6).map { index in
            StickerFfi(
                packCoordinate: "30031:author:party",
                shortcode: "animal\(index)",
                url: "https://example.invalid/\(index).png",
                plaintextSha256: String(repeating: "\(index)", count: 64),
                mime: "image/png",
                width: 512,
                height: 512,
                alt: nil,
                emoji: "🎉"
            )
        },
        license: nil,
        installed: true
    )
}

#Preview("Picker") {
    StickerPickerPopover(library: .preview(installed: [StickerPreviewData.pack]), send: { _ in }, onDismiss: {})
}

#Preview("Picker, no packs") {
    StickerPickerPopover(library: .preview(), send: { _ in }, onDismiss: {})
}

#Preview("Received sticker") {
    MessageStickerView(
        library: .preview(),
        loadingPreference: StickerLoadingPreference(defaults: UserDefaults(suiteName: "sticker-preview")!),
        sticker: StickerKey(StickerPreviewData.pack.stickers[0]),
        isOutgoing: false
    )
    .padding()
}
