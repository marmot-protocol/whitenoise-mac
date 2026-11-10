import MarmotKit
import SwiftUI

// MARK: - Custom emoji in the emoji picker

/// What an emoji picker offers beyond Unicode: the conversation's sendable custom emoji, and the
/// account's emoji sets for browsing more. A pick hands the picker's `onPick` the emoji's
/// `:shortcode:` token, which the composer inserts and a reaction sends with its image.
@MainActor
struct CustomEmojiPickerContent {
    let emojiSets: EmojiSetLibrary?
    /// Draws emoji received in this chat.
    let chatImages: CustomEmojiImageStore?
    /// Read only when the picker draws, so building the content for a row costs nothing.
    private let provideSendables: @MainActor () -> [CustomEmojiSendable]

    init(
        sendables: @escaping @MainActor () -> [CustomEmojiSendable],
        emojiSets: EmojiSetLibrary?,
        chatImages: CustomEmojiImageStore?
    ) {
        provideSendables = sendables
        self.emojiSets = emojiSets
        self.chatImages = chatImages
    }

    static func conversation(_ model: ConversationViewModel) -> CustomEmojiPickerContent {
        CustomEmojiPickerContent(
            sendables: { [model] in model.customEmojiSendables }, emojiSets: model.emojiSets,
            chatImages: model.customEmojiImages)
    }

    var sendables: [CustomEmojiSendable] { provideSendables() }

    /// The sendables whose shortcode contains every term of `query`.
    func matching(_ query: String) -> [CustomEmojiSendable] {
        let sendables = sendables
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return sendables }
        return sendables.filter { sendable in
            let name = sendable.shortcode.lowercased()
            return terms.allSatisfy { name.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))) }
        }
    }
}

/// One picker section of custom emoji.
struct CustomEmojiPickerSection: View {
    let title: String
    let emoji: [CustomEmojiSendable]
    let content: CustomEmojiPickerContent
    let disabledEmoji: Set<String>
    let onPick: (CustomEmojiSendable) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(emoji) { sendable in
                    CustomEmojiPickerCell(
                        sendable: sendable,
                        content: content,
                        isDisabled: disabledEmoji.contains(sendable.token),
                        onPick: { onPick(sendable) }
                    )
                }
            }
        } header: {
            Text(title)
                .wnFont(.semiBold10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }
}

private struct CustomEmojiPickerCell: View {
    let sendable: CustomEmojiSendable
    let content: CustomEmojiPickerContent
    let isDisabled: Bool
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            CustomEmojiPickerImage(sendable: sendable, content: content, pointSize: 26)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.28 : 1)
        .help(sendable.token)
        .accessibilityLabel(Text(verbatim: sendable.spokenName))
    }
}

/// A custom emoji's image from wherever it lives, or its literal `:shortcode:` until it loads.
struct CustomEmojiPickerImage: View {
    let sendable: CustomEmojiSendable
    let content: CustomEmojiPickerContent
    let pointSize: CGFloat

    var body: some View {
        switch sendable.artwork {
        case .builtin(let builtin):
            CustomEmojiImageOrLiteral(
                image: CustomEmojiBuiltinImages.image(for: builtin.shortcode), token: sendable.token,
                pointSize: pointSize)
        case .chat(let reference):
            CustomEmojiImageOrLiteral(
                image: content.chatImages?.image(for: reference), token: sendable.token, pointSize: pointSize
            )
            .task(id: reference.plaintextSha256) { content.chatImages?.load(reference) }
        case .installed(let emoji):
            let source = EmojiSetImageStore.Source.installed(emoji)
            CustomEmojiImageOrLiteral(
                image: content.emojiSets?.images.image(for: source), token: sendable.token, pointSize: pointSize
            )
            .task(id: source) { content.emojiSets?.images.load(source) }
        }
    }
}

private struct CustomEmojiImageOrLiteral: View {
    let image: NSImage?
    let token: String
    let pointSize: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: pointSize, height: pointSize)
        } else {
            Text(verbatim: token)
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(minHeight: pointSize)
        }
    }
}

/// The "Emoji Sets" control at the end of the picker's custom emoji.
struct CustomEmojiManageSetsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.string("Emoji Sets"), systemImage: "square.grid.2x2")
                .wnFont(.medium12)
        }
        .buttonStyle(.wnSecondary)
        .controlSize(.small)
        .accessibilityIdentifier("emojiPicker.emojiSets")
    }
}

/// Inline, persistent explanation of why a custom emoji message or reaction was not sent. A
/// message's draft is still in the composer, so Send retries it.
struct CustomEmojiSendNotice: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(WNColor.intentionErrorContent)
                .accessibilityHidden(true)
            Text(message)
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .wnFont(.semiBold10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Dismiss"))
            .accessibilityLabel(L10n.string("Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { AccessibilityNotification.Announcement(message).post() }
        .onChange(of: message) { _, message in AccessibilityNotification.Announcement(message).post() }
    }
}

// MARK: - Browsing and installing sets

/// The emoji-set browser and one set's page, navigated inside the emoji picker.
struct EmojiSetBrowser: View {
    let library: EmojiSetLibrary
    let onBack: () -> Void

    @State private var opened: EmojiSetFfi?

    var body: some View {
        if let opened {
            EmojiSetDetailPage(library: library, initialSet: opened, onBack: { self.opened = nil })
                .id(opened.coordinate)
        } else {
            EmojiSetBrowserPage(library: library, onOpen: { opened = $0 }, onBack: onBack)
        }
    }
}

private struct EmojiSetEgressDisclosure: View {
    var body: some View {
        Text(
            L10n.string(
                "Emoji sets are public and aren’t reviewed by White Noise. Opening or installing a set downloads its images from servers its author chose, which can see your IP address. Installing doesn’t change your public emoji list."
            )
        )
        .wnFont(.medium10)
        .foregroundStyle(WNColor.backgroundContentSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct EmojiSetDiscoverRequest: Equatable {
    let search: String
    let reload: Int
}

private struct EmojiSetBrowserPage: View {
    let library: EmojiSetLibrary
    let onOpen: (EmojiSetFfi) -> Void
    let onBack: () -> Void

    @State private var search = ""
    @State private var link = ""
    @State private var discovered: [EmojiSetFfi] = []
    @State private var suggestions: [EmojiSetFfi] = []
    @State private var isLoading = false
    @State private var syncError: String?
    @State private var isLookingUp = false
    @State private var errorMessage: String?
    @State private var reloadRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            StickerPageHeader(title: L10n.string("Emoji Sets"), onBack: onBack) {
                if library.isSyncing { ProgressView().controlSize(.small) }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StickerBrowserSection(
                        title: L10n.string("Add by Link"),
                        footer: L10n.string("Paste an emoji set’s naddr or address.")
                    ) {
                        HStack(spacing: 8) {
                            TextField(L10n.string("Emoji set address"), text: $link)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(lookUp)
                                .accessibilityIdentifier("emojiSets.link")
                            Button(L10n.string("Open Link"), action: lookUp)
                                .buttonStyle(.wnSecondary)
                                .controlSize(.small)
                                .disabled(EmojiSetPresentation.lookupInput(link) == nil || isLookingUp)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.intentionErrorContent)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !library.installedSets.isEmpty {
                        StickerBrowserSection(title: L10n.string("Installed")) {
                            ForEach(library.installedSets, id: \.coordinate) { set in
                                EmojiSetRow(set: set, progress: library.installProgress[set.coordinate]) {
                                    onOpen(set)
                                }
                            }
                        }
                    }

                    let pendingSuggestions = suggestions.filter { !library.isInstalled($0.coordinate) }
                    if !pendingSuggestions.isEmpty {
                        StickerBrowserSection(
                            title: L10n.string("From Your Emoji List"),
                            footer: L10n.string("Sets your public Nostr emoji list includes.")
                        ) {
                            ForEach(pendingSuggestions, id: \.coordinate) { set in
                                EmojiSetRow(set: set, progress: library.installProgress[set.coordinate]) {
                                    onOpen(set)
                                }
                            }
                        }
                    }

                    StickerBrowserSection(title: L10n.string("Discover")) {
                        TextField(L10n.string("Search emoji sets or paste an npub"), text: $search)
                            .textFieldStyle(.roundedBorder)
                        EmojiSetDiscoverList(
                            state: StickerPackPresentation.discoveryState(
                                isLoading: isLoading, packCount: shownDiscovered.count, search: search,
                                syncError: syncError),
                            sets: shownDiscovered,
                            library: library,
                            onOpen: onOpen,
                            onRetry: { reloadRequest += 1 }
                        )
                        EmojiSetEgressDisclosure()
                    }
                }
                .padding(14)
            }
        }
        .task { await library.loadInstalledIfNeeded() }
        .task { await loadSuggestions() }
        .task(id: EmojiSetDiscoverRequest(search: search, reload: reloadRequest)) {
            await reloadDiscovered(debounce: !search.isEmpty, forceSync: reloadRequest > 0)
        }
    }

    private var shownDiscovered: [EmojiSetFfi] {
        discovered.filter { !library.isInstalled($0.coordinate) }
    }

    /// Text only. A failure leaves the section hidden; Discover still works.
    private func loadSuggestions() async {
        guard let sets = try? await library.suggestions() else { return }
        suggestions = sets
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
                try await library.sync(force: forceSync, search: search)
                syncError = nil
            } catch is CancellationError {
                return
            } catch {
                syncError = UserFacingError.message(for: error)
            }
            let sets = try await library.discover(search: search)
            guard !Task.isCancelled else { return }
            discovered = sets
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = UserFacingError.message(for: error)
        }
    }

    private func lookUp() {
        guard let input = EmojiSetPresentation.lookupInput(link), !isLookingUp else { return }
        isLookingUp = true
        errorMessage = nil
        Task {
            defer { isLookingUp = false }
            do {
                let set = try await library.lookUp(input)
                link = ""
                onOpen(set)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }
}

private struct EmojiSetDiscoverList: View {
    let state: StickerPackPresentation.DiscoveryState
    let sets: [EmojiSetFfi]
    let library: EmojiSetLibrary
    let onOpen: (EmojiSetFfi) -> Void
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        case .packs:
            ForEach(sets, id: \.coordinate) { set in
                EmojiSetRow(set: set, progress: library.installProgress[set.coordinate]) { onOpen(set) }
            }
        case .noneOnRelays:
            StickerBrowserNote(
                text: L10n.string(
                    "Your relays don’t have any emoji sets yet. Paste a set’s address above to add one."))
        case .noMatches:
            StickerBrowserNote(text: L10n.string("No emoji sets match your search."))
        case .unreachable(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Couldn’t check your relays for emoji sets."))
                    .wnFont(.medium12)
                StickerBrowserNote(text: message)
                Button(L10n.string("Try Again"), action: onRetry)
                    .buttonStyle(.wnSecondary)
                    .controlSize(.small)
            }
        }
    }
}

/// A set as text only: its images load once the set is opened.
private struct EmojiSetRow: View {
    let set: EmojiSetFfi
    let progress: EmojiSetInstallProgressFfi?
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: EmojiSetPresentation.title(set))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                        .lineLimit(1)
                    Text(EmojiSetPresentation.summary(set))
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                    if let progress {
                        ProgressView(value: EmojiSetPresentation.fraction(progress) ?? 0)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.string("Installing"))
                    } else if set.installed?.updateAvailable == true {
                        Text(L10n.string("Update available"))
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.fillPrimary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHovering ? WNColor.fillSecondaryHover : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

struct EmojiSetDetailPage: View {
    let library: EmojiSetLibrary
    let onBack: () -> Void

    @State private var set: EmojiSetFfi
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmingRemove = false

    init(library: EmojiSetLibrary, initialSet: EmojiSetFfi, onBack: @escaping () -> Void) {
        self.library = library
        self.onBack = onBack
        _set = State(initialValue: initialSet)
    }

    var body: some View {
        let isInstalled = library.isInstalled(set.coordinate)
        let progress = library.installProgress[set.coordinate]
        let action = EmojiSetPresentation.action(for: set, isInstalled: isInstalled)
        VStack(spacing: 0) {
            StickerPageHeader(title: EmojiSetPresentation.title(set), onBack: onBack) {
                EmojiSetActionControl(
                    action: action,
                    isBusy: isWorking || progress != nil,
                    perform: perform,
                    confirmRemove: { confirmingRemove = true }
                )
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(EmojiSetPresentation.summary(set))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                    Text(String(format: L10n.string("By %@"), library.authorLabel(set)))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(1)
                    if let description = EmojiSetPresentation.description(set) {
                        Text(verbatim: description)
                            .wnFont(.medium12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    EmojiSetNotes(set: set)
                    if let errorMessage {
                        Text(errorMessage)
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.intentionErrorContent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let progress {
                        EmojiSetInstallProgressView(progress: progress) {
                            library.cancelInstall(set.coordinate)
                        }
                    }
                    EmojiSetGrid(
                        set: set, store: library.images,
                        installed: installedShortcodes(isInstalled: isInstalled))
                    EmojiSetEgressDisclosure()
                    if isInstalled, action == .update {
                        Button(L10n.string("Remove Set"), role: .destructive) { confirmingRemove = true }
                            .buttonStyle(.wnSecondary)
                            .controlSize(.small)
                            .disabled(isWorking || progress != nil)
                    }
                }
                .padding(14)
            }
        }
        .confirmationDialog(
            L10n.string("Remove this emoji set?"), isPresented: $confirmingRemove, titleVisibility: .visible
        ) {
            Button(L10n.string("Remove"), role: .destructive) { perform(.remove) }
        } message: {
            Text(L10n.string("Its emoji leave your picker. Messages you already sent keep them."))
        }
    }

    /// Emoji this device already stored, by shortcode, read locally instead of contacting the
    /// image host.
    private func installedShortcodes(isInstalled: Bool) -> [String: InstalledCustomEmojiFfi] {
        guard isInstalled, set.installed?.updateAvailable != true else { return [:] }
        return Dictionary(
            library.installedEmoji.filter { $0.setCoordinate == set.coordinate }.map { ($0.shortcode, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    private func perform(_ action: EmojiSetPresentation.Action) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        let shown = set
        Task {
            defer { isWorking = false }
            do {
                switch action {
                case .install, .update:
                    // The install's own progress drives the header from here.
                    isWorking = false
                    let result = try await library.install(shown)
                    set = result.set
                    if !result.skipped.isEmpty {
                        errorMessage = L10n.plural("%lld emoji couldn’t be installed.", Int64(result.skipped.count))
                    }
                case .remove:
                    try await library.uninstall(shown.coordinate)
                    if let current = try? await library.current(shown.coordinate) { set = current }
                }
            } catch {
                if EmojiSetPresentation.isCancellation(error) { return }
                if EmojiSetPresentation.changedVersion(error) != nil,
                    let current = try? await library.current(shown.coordinate)
                {
                    set = current
                }
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }
}

private struct EmojiSetActionControl: View {
    let action: EmojiSetPresentation.Action
    let isBusy: Bool
    let perform: (EmojiSetPresentation.Action) -> Void
    let confirmRemove: () -> Void

    var body: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else {
            switch action {
            case .install:
                Button(L10n.string("Install")) { perform(.install) }
                    .buttonStyle(.wnSecondary)
                    .controlSize(.small)
                    .accessibilityIdentifier("emojiSets.install")
            case .update:
                Button(L10n.string("Update")) { perform(.update) }
                    .buttonStyle(.wnSecondary)
                    .controlSize(.small)
            case .remove:
                Button(L10n.string("Remove"), role: .destructive, action: confirmRemove)
                    .buttonStyle(.wnSecondary)
                    .controlSize(.small)
            }
        }
    }
}

private struct EmojiSetNotes: View {
    let set: EmojiSetFfi

    var body: some View {
        if let skipped = EmojiSetPresentation.skippedNote(set) {
            Label(skipped, systemImage: "exclamationmark.triangle")
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
        }
        let unsendable = EmojiSetPresentation.unsendableCount(set)
        if unsendable > 0 {
            Label(
                L10n.plural(
                    "%lld emoji have names chats can’t send, so they won’t appear in your picker.", Int64(unsendable)),
                systemImage: "info.circle"
            )
            .wnFont(.medium10)
            .foregroundStyle(WNColor.backgroundContentSecondary)
        }
    }
}

private struct EmojiSetInstallProgressView: View {
    let progress: EmojiSetInstallProgressFfi
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = EmojiSetPresentation.fraction(progress) {
                ProgressView(value: fraction)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Text(
                    String(
                        format: L10n.string("Installing %lld of %lld"), Int64(progress.completedEmoji),
                        Int64(progress.totalEmoji))
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .monospacedDigit()
                Spacer()
                Button(L10n.string("Cancel"), action: onCancel)
                    .buttonStyle(.wnSecondary)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct EmojiSetGrid: View {
    let set: EmojiSetFfi
    let store: EmojiSetImageStore
    let installed: [String: InstalledCustomEmojiFfi]

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(set.emoji, id: \.shortcode) { entry in
                EmojiSetGridCell(source: source(for: entry), store: store, shortcode: entry.shortcode)
            }
        }
    }

    private func source(for entry: EmojiSetEmojiFfi) -> EmojiSetImageStore.Source {
        if let stored = installed[entry.shortcode] { return .installed(stored) }
        return .preview(coordinate: set.coordinate, eventIdHex: set.eventIdHex, shortcode: entry.shortcode)
    }
}

private struct EmojiSetGridCell: View {
    let source: EmojiSetImageStore.Source
    let store: EmojiSetImageStore
    let shortcode: String

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image = store.image(for: source) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else if store.hasFailed(source) {
                    Button {
                        store.retry(source)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Try Again"))
                    .accessibilityLabel(L10n.string("Try Again"))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 36, height: 36)
            Text(verbatim: shortcode)
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .task(id: source) { store.load(source) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: shortcode))
    }
}

// MARK: - Previews

private enum EmojiSetPreviewData {
    static let set = EmojiSetFfi(
        coordinate: "30030:author:blobs",
        kind: 30030,
        authorPubkeyHex: String(repeating: "a", count: 64),
        identifier: "blobs",
        eventIdHex: String(repeating: "b", count: 64),
        createdAt: 0,
        title: "Blob Friends",
        description: "Round friends for every mood.",
        imageUrl: nil,
        emoji: (1...8).map { EmojiSetEmojiFfi(shortcode: "blob\($0)", url: "https://example.invalid/\($0).png") },
        skipped: [],
        skippedCount: 1,
        installed: nil
    )
}

#Preview("Emoji sets") {
    EmojiSetBrowser(library: .preview(installed: [EmojiSetPreviewData.set]), onBack: {})
        .frame(width: 420, height: 430)
}

#Preview("Emoji set") {
    EmojiSetDetailPage(library: .preview(), initialSet: EmojiSetPreviewData.set, onBack: {})
        .frame(width: 420, height: 430)
}

#Preview("Custom emoji in the picker") {
    ScrollView {
        CustomEmojiPickerSection(
            title: L10n.string("Custom Emoji"),
            emoji: CustomEmojiBuiltins.all.map(CustomEmojiSendable.init(builtin:)),
            content: CustomEmojiPickerContent(
                sendables: { CustomEmojiBuiltins.all.map(CustomEmojiSendable.init(builtin:)) }, emojiSets: nil,
                chatImages: nil),
            disabledEmoji: [],
            onPick: { _ in }
        )
        CustomEmojiManageSetsButton {}
    }
    .padding(10)
    .frame(width: 420, height: 200)
}

#Preview("Send notice") {
    CustomEmojiSendNotice(message: CustomEmojiSendError.mixedWithAttachments.message, onDismiss: {})
        .frame(width: 420)
}
