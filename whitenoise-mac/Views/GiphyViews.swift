//
//  GiphyViews.swift
//  whitenoise-mac
//
//  GIF support, ported from whitenoise-ios: the GIPHY picker the composer opens, and the card a
//  GIPHY envelope renders as inside a message bubble. See `RemoteGiphyMedia` for the envelope.
//

import AppKit
import SwiftUI

// MARK: - Playback

/// An `NSImageView` that animates GIF data natively and reports no intrinsic size, so SwiftUI
/// sizes it from the aspect-ratio frame around it instead of from the GIF's pixel dimensions.
final class GiphyAnimatedNSImageView: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        animates = true
        isEditable = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// The bubble is a click target for the whole row (context menu, selection), not the image.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct GiphyAnimatedImage: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> GiphyAnimatedNSImageView {
        let view = GiphyAnimatedNSImageView(frame: .zero)
        view.image = NSImage(data: data)
        context.coordinator.data = data
        return view
    }

    func updateNSView(_ nsView: GiphyAnimatedNSImageView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        nsView.image = NSImage(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: GiphyAnimatedNSImageView, coordinator: Coordinator) {
        nsView.image = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GiphyAnimatedNSImageView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Coordinator {
        var data: Data?
    }
}

// MARK: - Message bubble

/// Keeps a timeline row's measured size independent of whether its GIF is currently resident.
/// Scrolling a GIF out of view drops its bytes; reverting to the 4:3 fallback then would change
/// the row's height and feed that geometry change back into the visibility it was driven by.
nonisolated struct StableGiphyDisplayGeometry: Equatable, Sendable {
    private(set) var aspectRatio: CGFloat

    init(fallbackAspectRatio: CGFloat) {
        aspectRatio = fallbackAspectRatio
    }

    mutating func record(decodedAspectRatio: CGFloat?) {
        guard let decodedAspectRatio, decodedAspectRatio.isFinite, decodedAspectRatio > 0 else { return }
        aspectRatio = decodedAspectRatio
    }
}

nonisolated enum GiphyPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case failed
    case playing(GiphyRemoteMediaLoader.PreparedPlayback)
}

/// A received or sent GIPHY GIF inside its bubble.
///
/// Received GIFs wait for a click unless "Automatically Load Remote GIFs" is on (see
/// `RemoteGIFLoadingPreference`); your own always load. The transcript realizes every row eagerly,
/// so `onDisappear` does not fire on scroll — scroll visibility is what starts playback and what
/// drops the bytes again, and the stable geometry keeps the row's height through that.
struct RemoteGiphyMediaView: View {
    static let width: CGFloat = 280

    let media: RemoteGiphyMedia
    let mayLoadAutomatically: Bool
    let loadingPreference: RemoteGIFLoadingPreference
    var prepare: @Sendable (RemoteGiphyMedia) async throws -> GiphyRemoteMediaLoader.PreparedPlayback = {
        try await GiphyRemoteMediaLoader.preparePlayback(for: $0)
    }

    @State private var state: GiphyPlaybackState
    @State private var loadRequested = false
    @State private var isVisible = false
    @State private var displayGeometry: StableGiphyDisplayGeometry

    init(
        media: RemoteGiphyMedia,
        mayLoadAutomatically: Bool,
        loadingPreference: RemoteGIFLoadingPreference,
        initialState: GiphyPlaybackState = .idle
    ) {
        self.media = media
        self.mayLoadAutomatically = mayLoadAutomatically
        self.loadingPreference = loadingPreference
        _state = State(initialValue: initialState)
        var geometry = StableGiphyDisplayGeometry(fallbackAspectRatio: media.aspectRatio)
        if case .playing(let prepared) = initialState {
            geometry.record(decodedAspectRatio: prepared.aspectRatio)
        }
        _displayGeometry = State(initialValue: geometry)
    }

    private var shouldLoad: Bool {
        mayLoadAutomatically || loadingPreference.automaticallyLoads || loadRequested
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                GiphyPlaybackContent(state: state) {
                    loadRequested = true
                    if state == .failed { state = .idle }
                }
            }
            .aspectRatio(displayGeometry.aspectRatio, contentMode: .fit)
            .frame(width: Self.width)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))

            Text(verbatim: media.creditLabel)
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentTertiary)
                .lineLimit(1)
                .frame(width: Self.width, alignment: .leading)
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
            if !visible, case .playing = state { state = .idle }
        }
        .task(id: PlaybackTaskID(url: media.url, isEligible: isVisible && shouldLoad, state: state)) {
            guard isVisible, shouldLoad, state == .idle else { return }
            await load()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("GIF via GIPHY"))
    }

    private func load() async {
        state = .loading
        do {
            let prepared = try await prepare(media)
            try Task.checkCancellation()
            displayGeometry.record(decodedAspectRatio: prepared.aspectRatio)
            state = .playing(prepared)
        } catch is CancellationError {
            if state == .loading { state = .idle }
        } catch {
            state = .failed
            loadRequested = false
        }
    }

    private struct PlaybackTaskID: Equatable {
        let url: URL
        let isEligible: Bool
        let isIdle: Bool

        init(url: URL, isEligible: Bool, state: GiphyPlaybackState) {
            self.url = url
            self.isEligible = isEligible
            self.isIdle = state == .idle
        }
    }
}

/// What fills the GIF's frame: the animation, a spinner, or the click-to-load / retry control.
private struct GiphyPlaybackContent: View {
    let state: GiphyPlaybackState
    let onLoad: () -> Void

    var body: some View {
        switch state {
        case .playing(let prepared):
            GiphyAnimatedImage(data: prepared.data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .idle, .failed:
            Button(action: onLoad) {
                VStack(spacing: 8) {
                    Image(systemName: state == .failed ? "arrow.clockwise" : "play.fill")
                        .wnFont(.medium18)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.16), in: Circle())
                    Text(state == .failed ? L10n.string("Retry") : L10n.string("Load GIF"))
                        .wnFont(.semiBold12)
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state == .failed ? L10n.string("This GIF couldn't be loaded.") : L10n.string("Load GIF"))
        }
    }
}

// MARK: - Picker

/// The composer's GIF button. Only shown when this build carries a GIPHY API key, the way the
/// iOS attachment menu leaves the GIFs entry out; a fresh picker model per opening means a closed
/// picker keeps no stale query or results.
struct ComposerGiphyButton: View {
    let apiKey: String
    let isDisabled: Bool
    let send: GiphySearchViewModel.Send

    @State private var searchModel: GiphySearchViewModel?

    var body: some View {
        Button {
            let client = GiphySearchClient(apiKey: apiKey)
            let send = send
            searchModel = GiphySearchViewModel(
                search: { try await client.search($0) },
                send: { media in try await send(media) }
            )
        } label: {
            Text(L10n.string("GIF"))
                .wnFont(.bold10)
                .frame(width: 30, height: 30)
                .background {
                    MessagesCircleControlBackground()
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(L10n.string("GIFs"))
        .accessibilityIdentifier("composer.gifs")
        .popover(
            isPresented: Binding(
                get: { searchModel != nil },
                set: { if !$0 { searchModel = nil } }
            ),
            arrowEdge: .bottom
        ) {
            if let searchModel {
                GiphySearchView(model: searchModel) { self.searchModel = nil }
            }
        }
    }
}

/// The composer's GIF picker. Search results load as soon as they arrive — the notice at the top
/// is the disclosure for that — and choosing one sends it and closes the picker.
struct GiphySearchView: View {
    @Bindable var model: GiphySearchViewModel
    let onDismiss: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                TextField(L10n.string("Search GIPHY"), text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("giphy.search")
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(
                L10n.string("Your search and IP address are sent to GIPHY. Opening a received GIF also contacts GIPHY.")
            )
            .wnFont(.medium10)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if let sendErrorMessage = model.sendErrorMessage {
                Text(sendErrorMessage)
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.intentionErrorContent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                GiphySearchResultsContent(model: model, columns: columns, onDismiss: onDismiss)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 320)

            HStack {
                Spacer()
                PoweredByGiphyMark()
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 400)
        .task(id: model.query) { await model.searchAfterDebounce() }
    }
}

private struct GiphySearchResultsContent: View {
    let model: GiphySearchViewModel
    let columns: [GridItem]
    let onDismiss: () -> Void

    var body: some View {
        if model.isLoading && model.results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if let errorMessage = model.errorMessage {
            WNEmptyStateView(
                title: L10n.string("Couldn't search GIFs"),
                description: errorMessage,
                systemImage: "exclamationmark.magnifyingglass"
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if model.trimmedQuery.isEmpty {
            WNEmptyStateView(
                title: L10n.string("Search GIPHY"),
                description: L10n.string("Find a GIF to send to this conversation."),
                systemImage: "magnifyingglass"
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if model.results.isEmpty {
            WNEmptyStateView(
                title: L10n.string("No Results"),
                systemImage: "magnifyingglass"
            )
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.results) { result in
                    Button {
                        Task {
                            if await model.select(result) { onDismiss() }
                        }
                    } label: {
                        GiphySearchResultTile(
                            result: result,
                            isSending: model.sendingResultID == result.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.sendingResultID != nil)
                    .help(result.title)
                    .accessibilityLabel(result.title)
                }
            }
        }
    }
}

private struct GiphySearchResultTile: View {
    let result: GiphySearchResult
    let isSending: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GiphySearchPreview(media: result.media)

            if let attribution = result.media.attribution {
                Text(verbatim: attribution)
                    .wnFont(.semiBold10)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                    )
            }

            if isSending {
                Color.black.opacity(0.4)
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A search result's animation. Loaded without a click: the user asked GIPHY for these results,
/// and the picker says so above them.
private struct GiphySearchPreview: View {
    let media: RemoteGiphyMedia

    @State private var state: GiphyPlaybackState = .idle

    var body: some View {
        ZStack {
            WNColor.fillSecondary
            switch state {
            case .playing(let prepared):
                GiphyAnimatedImage(data: prepared.data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                Image(systemName: "photo")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: media.url) {
            state = .loading
            do {
                state = .playing(try await GiphyRemoteMediaLoader.preparePlayback(for: media))
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed
            }
        }
    }
}

/// GIPHY's required "Powered by GIPHY" attribution. The mark is GIPHY's official logo — see
/// `docs/third-party-assets.md` — and must not be recolored.
struct PoweredByGiphyMark: View {
    var body: some View {
        HStack(spacing: 7) {
            Text(L10n.string("Powered by"))
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            Image("GiphyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 22)
                .accessibilityLabel(L10n.string("GIPHY"))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("GIF bubble, click to load") {
    RemoteGiphyMediaView(
        media: RemoteGiphyMedia(
            url: URL(string: "https://media.giphy.com/media/abc/giphy.gif")!,
            width: 480,
            height: 270,
            attribution: "Creator"
        ),
        mayLoadAutomatically: false,
        loadingPreference: RemoteGIFLoadingPreference(defaults: UserDefaults(suiteName: "giphy-preview")!)
    )
    .padding()
}

#Preview("GIF bubble, failed") {
    RemoteGiphyMediaView(
        media: RemoteGiphyMedia(
            url: URL(string: "https://media.giphy.com/media/abc/giphy.gif")!,
            width: 4,
            height: 3,
            attribution: nil
        ),
        mayLoadAutomatically: true,
        loadingPreference: RemoteGIFLoadingPreference(defaults: UserDefaults(suiteName: "giphy-preview")!),
        initialState: .failed
    )
    .padding()
}

#Preview("GIF picker") {
    GiphySearchView(
        model: GiphySearchViewModel(search: { _ in [] }, send: { _ in }),
        onDismiss: {}
    )
}

#Preview("Composer GIF button") {
    ComposerGiphyButton(apiKey: "preview", isDisabled: false, send: { _ in })
        .padding()
}

#Preview("Powered by GIPHY") {
    PoweredByGiphyMark()
        .padding()
}
