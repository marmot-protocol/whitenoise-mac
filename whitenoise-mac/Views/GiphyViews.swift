//
//  GiphyViews.swift
//  whitenoise-mac
//
//  GIF support, ported from whitenoise-ios: the GIPHY picker the composer opens, and the card a
//  GIPHY envelope renders as inside a message bubble. See `RemoteGiphyMedia` for the envelope.
//

import AppKit
import ImageIO
import OSLog
import SwiftUI

// MARK: - Playback

/// Plays GIF data with ImageIO's animator (`CGAnimateImageDataWithBlock`), the player the iOS app
/// uses. ImageIO decodes one frame at a time at the GIF's own delays and each frame goes straight
/// into the layer; `NSImageView.animates` re-rasterized an `NSImage` per tick and started over at
/// the first frame whenever SwiftUI rebuilt the view. The view reports no intrinsic size, so
/// SwiftUI sizes it from the aspect-ratio frame around it instead of from the GIF's pixels.
final class GiphyAnimatedNSView: NSView {
    /// One run of the animator. ImageIO keeps calling a run's block until the block asks it to
    /// stop, so stopping marks the run and its next frame ends it.
    private final class Run {
        var isStopped = false
    }

    /// Called with every frame the animator delivers.
    var onFrame: ((GiphyPlaybackCache.Position) -> Void)?

    private(set) var data: Data?
    /// The frame on screen, which is where a paused animation picks up again.
    private(set) var frameIndex = 0
    private var run: Run?
    private var wantsAnimation = false

    var isAnimating: Bool { run != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        // A frame must replace the last one outright: the default action cross-fades `contents`.
        layer?.actions = ["contents": NSNull()]
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

    override var wantsUpdateLayer: Bool { true }

    /// Nothing to redraw: the animator pushes each frame straight into `layer.contents`.
    override func updateLayer() {}

    /// The bubble is a click target for the whole row (context menu, selection), not the image.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `data`, starting from `position` — the frame a previous player of the same GIF was
    /// on — so a rebuilt view carries on rather than restarting. The same data again is a no-op.
    func show(_ data: Data, resumingAt position: GiphyPlaybackCache.Position?) {
        guard data != self.data else { return }
        stopAnimator()
        self.data = data
        frameIndex = position?.frameIndex ?? 0
        layer?.contents = position?.image
        if wantsAnimation { startAnimator() }
    }

    /// Runs or pauses the animation. A paused one keeps its current frame on screen. It only runs
    /// while the view is in a window: a recycled transcript cell waits off-window for reuse.
    func setAnimating(_ animating: Bool) {
        wantsAnimation = animating
        if animating { startAnimator() } else { stopAnimator() }
    }

    /// Stops the animation and releases the GIF.
    func clear() {
        wantsAnimation = false
        stopAnimator()
        data = nil
        frameIndex = 0
        layer?.contents = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimator()
        } else if wantsAnimation {
            startAnimator()
        }
    }

    private func startAnimator() {
        guard run == nil, window != nil, let data else { return }
        let run = Run()
        self.run = run
        let options: [CFString: Any] = [
            kCGImageAnimationLoopCount: Double.infinity,
            kCGImageAnimationStartIndex: frameIndex,
        ]
        let status = CGAnimateImageDataWithBlock(data as CFData, options as CFDictionary) {
            [weak self] index, image, stop in
            guard let self, !run.isStopped else {
                stop.pointee = true
                return
            }
            frameIndex = index
            layer?.contents = image
            onFrame?(GiphyPlaybackCache.Position(frameIndex: index, image: image))
        }
        if status != noErr {
            Self.log.error("animation_start_failed status=\(status, privacy: .public)")
            run.isStopped = true
            self.run = nil
        }
    }

    private func stopAnimator() {
        run?.isStopped = true
        run = nil
    }

    private static let log = Logger(subsystem: "dev.ipf.whitenoise.mac", category: "giphy-playback")
}

private struct GiphyAnimatedImage: NSViewRepresentable {
    let data: Data
    /// The GIF's envelope URL: where `cache` keeps its position.
    let url: URL
    var isAnimating = true
    let cache: GiphyPlaybackCache

    func makeNSView(context: Context) -> GiphyAnimatedNSView {
        let view = GiphyAnimatedNSView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: GiphyAnimatedNSView, context: Context) {
        let cache = cache
        let url = url
        nsView.onFrame = { cache.record($0, for: url) }
        nsView.show(data, resumingAt: cache.position(for: url))
        nsView.setAnimating(isAnimating)
    }

    static func dismantleNSView(_ nsView: GiphyAnimatedNSView, coordinator: ()) {
        nsView.onFrame = nil
        nsView.clear()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GiphyAnimatedNSView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

// MARK: - Message bubble

/// Keeps a timeline row's measured size independent of whether its GIF is currently resident.
/// A bubble rebuilt before its GIF is back would otherwise revert to the 4:3 fallback, change the
/// row's height, and feed that geometry change back into the visibility it was driven by.
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
/// `RemoteGIFLoadingPreference`), and a click is remembered for the session; your own always load.
/// Transcript visibility is what starts a download and what runs the animation: off screen it
/// pauses on its current frame rather than letting go of the GIF. A bubble rebuilt for a GIF the
/// session already has — a recycled cell, a table reload — starts out playing from
/// `GiphyPlaybackCache`, so it never passes back through "Load GIF" or the spinner.
struct RemoteGiphyMediaView: View {
    static let width: CGFloat = 280

    let media: RemoteGiphyMedia
    let mayLoadAutomatically: Bool
    let loadingPreference: RemoteGIFLoadingPreference
    let prepare: @Sendable (RemoteGiphyMedia) async throws -> GiphyRemoteMediaLoader.PreparedPlayback
    let cache: GiphyPlaybackCache

    @State private var state: GiphyPlaybackState
    /// Bumped by every Load/Retry click so the load task re-keys even when eligibility did not
    /// change (a failed own send is already eligible). The task must never key on `state`: its
    /// own `state = .loading` would cancel it, and the cancellation would reset it to `.idle` and
    /// start the download again, in a loop.
    @State private var retryRequests = 0
    @State private var isVisible = false
    @State private var displayGeometry: StableGiphyDisplayGeometry

    init(
        media: RemoteGiphyMedia,
        mayLoadAutomatically: Bool,
        loadingPreference: RemoteGIFLoadingPreference,
        initialState: GiphyPlaybackState = .idle,
        cache: GiphyPlaybackCache? = nil,
        prepare: @escaping @Sendable (RemoteGiphyMedia) async throws -> GiphyRemoteMediaLoader.PreparedPlayback = {
            try await GiphyRemoteMediaLoader.preparePlayback(for: $0)
        }
    ) {
        self.media = media
        self.mayLoadAutomatically = mayLoadAutomatically
        self.loadingPreference = loadingPreference
        self.prepare = prepare
        let cache = cache ?? .shared
        self.cache = cache
        var state = initialState
        if state == .idle, Self.mayLoad(media, mayLoadAutomatically, loadingPreference),
            let cached = cache.playback(for: media.url)
        {
            state = .playing(cached)
        }
        _state = State(initialValue: state)
        var geometry = StableGiphyDisplayGeometry(fallbackAspectRatio: media.aspectRatio)
        if case .playing(let prepared) = state {
            geometry.record(decodedAspectRatio: prepared.aspectRatio)
        }
        _displayGeometry = State(initialValue: geometry)
    }

    private var shouldLoad: Bool {
        Self.mayLoad(media, mayLoadAutomatically, loadingPreference)
    }

    private static func mayLoad(
        _ media: RemoteGiphyMedia,
        _ mayLoadAutomatically: Bool,
        _ loadingPreference: RemoteGIFLoadingPreference
    ) -> Bool {
        mayLoadAutomatically || loadingPreference.automaticallyLoads
            || loadingPreference.wasLoadRequested(for: media.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                GiphyPlaybackContent(state: state, url: media.url, isAnimating: isVisible, cache: cache) {
                    loadingPreference.recordLoadRequest(for: media.url)
                    if state == .failed { state = .idle }
                    retryRequests &+= 1
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
        .onTranscriptVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .task(id: PlaybackTaskID(url: media.url, isEligible: isVisible && shouldLoad, retryRequests: retryRequests)) {
            guard isVisible, shouldLoad else {
                if state == .loading { state = .idle }
                return
            }
            // `.loading` is not "someone else is on it": a cancelled load can still be unwinding
            // when visibility comes back, and waiting for it left the bubble on "Load GIF".
            guard state == .idle || state == .loading else { return }
            if let cached = cache.playback(for: media.url) {
                displayGeometry.record(decodedAspectRatio: cached.aspectRatio)
                state = .playing(cached)
                return
            }
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
            cache.insert(prepared, for: media.url)
            displayGeometry.record(decodedAspectRatio: prepared.aspectRatio)
            state = .playing(prepared)
        } catch {
            // A cancelled load leaves the state to whichever task replaced it: resetting it here
            // would clobber a newer load's spinner. The task that found the bubble ineligible
            // already put it back to `.idle`.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            state = .failed
        }
    }

    private struct PlaybackTaskID: Equatable {
        let url: URL
        let isEligible: Bool
        let retryRequests: Int
    }
}

/// What fills the GIF's frame: the animation, a spinner, or the click-to-load / retry control.
private struct GiphyPlaybackContent: View {
    let state: GiphyPlaybackState
    let url: URL
    let isAnimating: Bool
    let cache: GiphyPlaybackCache
    let onLoad: () -> Void

    var body: some View {
        switch state {
        case .playing(let prepared):
            GiphyAnimatedImage(data: prepared.data, url: url, isAnimating: isAnimating, cache: cache)
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
            // Keyed on the URL so a new rendition rebuilds the preview, whose init re-reads the
            // cache, instead of keeping the old GIF playing under the new URL.
            GiphySearchPreview(media: result.media)
                .id(result.media.url)

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
///
/// Results share `GiphyPlaybackCache` with the bubbles, so a GIF sent from here plays in its
/// bubble at once, from where the preview was.
private struct GiphySearchPreview: View {
    let media: RemoteGiphyMedia

    @State private var state: GiphyPlaybackState

    init(media: RemoteGiphyMedia) {
        self.media = media
        _state = State(initialValue: GiphyPlaybackCache.shared.playback(for: media.url).map { .playing($0) } ?? .idle)
    }

    var body: some View {
        ZStack {
            WNColor.fillSecondary
            switch state {
            case .playing(let prepared):
                GiphyAnimatedImage(data: prepared.data, url: media.url, cache: .shared)
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
            if case .playing = state { return }
            state = .loading
            do {
                let prepared = try await GiphyRemoteMediaLoader.preparePlayback(for: media)
                GiphyPlaybackCache.shared.insert(prepared, for: media.url)
                // Awaiting the detached validation does not observe cancellation; a newer task
                // owns `state` now.
                try Task.checkCancellation()
                state = .playing(prepared)
            } catch is CancellationError {
                return
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

#Preview("Powered by GIPHY") {
    PoweredByGiphyMark()
        .padding()
}
