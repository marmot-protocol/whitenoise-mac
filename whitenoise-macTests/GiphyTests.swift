//
//  GiphyTests.swift
//  whitenoise-macTests
//
//  GIF support: the GIPHY text envelope, search and lookup decoding, playback preparation, the
//  picker's model, the auto-load preference, and every preview surface that must show a label
//  instead of the CDN URL.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MarmotKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import whitenoise_mac

struct GiphyTests: WorkspaceTestSupport {
    private static let gifURL = URL(string: "https://media1.giphy.com/media/abc123/giphy.gif?cid=client&rid=giphy.gif")!

    // MARK: Composer menu

    @Test func attachmentMenuOffersGIFsOnlyWhenTheBuildCanSearchThem() {
        #expect(ComposerAttachmentOption.available(gifsAvailable: true) == [.files, .gifs])
        #expect(ComposerAttachmentOption.available(gifsAvailable: false) == [.files])
    }

    @Test func attachmentMenuStringsResolveThroughTheCatalog() {
        let spanish = Locale(identifier: "es")
        #expect(L10n.string(ComposerAttachmentOption.files.titleKey, locale: spanish) == "Archivos")
        #expect(L10n.string(ComposerAttachmentOption.gifs.titleKey, locale: spanish) == "GIFs")
        #expect(L10n.string("Add attachment", locale: spanish) == "Añadir adjunto")
        #expect(L10n.string("Add attachment", locale: Locale(identifier: "de")) == "Anhang hinzufügen")
    }

    // MARK: Bubble playback

    /// Setting `.loading` must not re-key the load task: when the task id followed the playback
    /// state, `load()`'s own first line cancelled it, the cancellation reset the state to `.idle`,
    /// and a fresh task started the download again, forever. A GIF that may load has to be asked
    /// for once and then play.
    @MainActor
    @Test func bubbleLoadsAnEligibleGIFExactlyOnce() async throws {
        let calls = PrepareCallCounter()
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 480, height: 270, attribution: nil)
        let playback = GiphyRemoteMediaLoader.PreparedPlayback(data: Data([0x47, 0x49, 0x46]), aspectRatio: 16 / 9)
        let view = ScrollView {
            RemoteGiphyMediaView(
                media: media,
                mayLoadAutomatically: true,
                loadingPreference: RemoteGIFLoadingPreference(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                cache: GiphyPlaybackCache(),
                prepare: { _ in
                    await calls.increment()
                    try await Task.sleep(for: .milliseconds(20))
                    return playback
                }
            )
        }
        .frame(width: 320, height: 400)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let prepareCount = await calls.count
        #expect(prepareCount == 1, "prepare ran \(prepareCount) times")
    }

    /// A cancelled download does not return the instant it is cancelled, so the task that the next
    /// visibility change starts can run while the previous one still says `.loading`. Visibility
    /// flickers like that whenever a row is appended or a GIF resizes its row. That task must start
    /// its own download, not leave the bubble on "Load GIF" until someone clicks it.
    @MainActor
    @Test func bubbleReloadsWhenVisibilityReturnsBeforeACancelledLoadUnwinds() async throws {
        let calls = PrepareCallCounter()
        let gate = PrepareGate()
        let visibility = TranscriptCellVisibility()
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 480, height: 270, attribution: nil)
        let playback = GiphyRemoteMediaLoader.PreparedPlayback(data: Data([0x47, 0x49, 0x46]), aspectRatio: 16 / 9)
        let window = Self.hostingWindow(
            RemoteGiphyMediaView(
                media: media,
                mayLoadAutomatically: true,
                loadingPreference: RemoteGIFLoadingPreference(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                cache: GiphyPlaybackCache(),
                prepare: { _ in
                    await calls.increment()
                    await gate.wait()
                    try Task.checkCancellation()
                    return playback
                }
            )
            .environment(\.transcriptCellVisibility, visibility)
        )
        defer { window.orderOut(nil) }

        visibility.isVisible = true
        #expect(await Self.waitForPrepareCount(1, in: calls))

        visibility.isVisible = false
        try await Task.sleep(for: .milliseconds(100))
        visibility.isVisible = true

        let reloaded = await Self.waitForPrepareCount(2, in: calls)
        await gate.open()
        #expect(reloaded, "the bubble stopped at Load GIF instead of downloading again")
    }

    /// A received GIF the viewer chose to load stays chosen for the session: a transcript cell
    /// recycled for that message starts with fresh view state, and must not ask again.
    @MainActor
    @Test func aGIFLoadedOnRequestLoadsAutomaticallyWhenItsBubbleIsRebuilt() async throws {
        let calls = PrepareCallCounter()
        let visibility = TranscriptCellVisibility()
        visibility.isVisible = true
        let preference = RemoteGIFLoadingPreference(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 480, height: 270, attribution: nil)
        let playback = GiphyRemoteMediaLoader.PreparedPlayback(data: Data([0x47, 0x49, 0x46]), aspectRatio: 16 / 9)
        preference.recordLoadRequest(for: media.url)

        let window = Self.hostingWindow(
            RemoteGiphyMediaView(
                media: media,
                mayLoadAutomatically: false,
                loadingPreference: preference,
                cache: GiphyPlaybackCache(),
                prepare: { _ in
                    await calls.increment()
                    return playback
                }
            )
            .environment(\.transcriptCellVisibility, visibility)
        )
        defer { window.orderOut(nil) }

        #expect(await Self.waitForPrepareCount(1, in: calls))
    }

    /// Transcript cells are recycled and the table reloads whenever a message arrives, so a GIF
    /// bubble is rebuilt with fresh state all the time. A rebuild for a GIF the session already has
    /// must come up playing — not flash "Load GIF" or a spinner, and not download it again.
    @MainActor
    @Test func aRebuiltBubbleForACachedGIFComesUpPlayingWithoutLoading() async throws {
        let calls = PrepareCallCounter()
        let cache = GiphyPlaybackCache()
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 480, height: 270, attribution: nil)
        cache.insert(
            .init(data: try Self.animatedGIF(width: 4, height: 2), aspectRatio: 2),
            for: media.url
        )

        let window = Self.hostingWindow(
            RemoteGiphyMediaView(
                media: media,
                mayLoadAutomatically: false,
                loadingPreference: Self.preferenceRemembering(media.url),
                cache: cache,
                prepare: { _ in
                    await calls.increment()
                    throw CancellationError()
                }
            )
            .environment(\.transcriptCellVisibility, TranscriptCellVisibility())
        )
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(Self.animatedViews(in: window).count == 1, "the first frame drew something other than the GIF")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await calls.count == 0)
    }

    /// The same rebuild for a GIF the viewer never chose to load must still wait for the click:
    /// the cache is not a way around the preference.
    @MainActor
    @Test func aCachedGIFTheViewerNeverLoadedStillWaitsForTheClick() throws {
        let cache = GiphyPlaybackCache()
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 480, height: 270, attribution: nil)
        cache.insert(.init(data: try Self.animatedGIF(width: 4, height: 2), aspectRatio: 2), for: media.url)

        let window = Self.hostingWindow(
            RemoteGiphyMediaView(
                media: media,
                mayLoadAutomatically: false,
                loadingPreference: RemoteGIFLoadingPreference(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                cache: cache
            )
            .environment(\.transcriptCellVisibility, TranscriptCellVisibility())
        )
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(Self.animatedViews(in: window).isEmpty)
    }

    /// Scrolling a GIF out of view pauses it on its frame; it used to drop the GIF, so scrolling
    /// back showed a spinner, fetched it again, and restarted it from the first frame.
    @MainActor
    @Test func scrollingABubbleAwayPausesItAndScrollingBackResumesWithoutReloading() async throws {
        let calls = PrepareCallCounter()
        let visibility = TranscriptCellVisibility()
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 480, height: 270, attribution: nil)
        let playback = GiphyRemoteMediaLoader.PreparedPlayback(
            data: try Self.animatedGIF(width: 4, height: 2), aspectRatio: 2)
        let window = Self.hostingWindow(
            RemoteGiphyMediaView(
                media: media,
                mayLoadAutomatically: true,
                loadingPreference: RemoteGIFLoadingPreference(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                cache: GiphyPlaybackCache(),
                prepare: { _ in
                    await calls.increment()
                    return playback
                }
            )
            .environment(\.transcriptCellVisibility, visibility)
        )
        defer { window.orderOut(nil) }

        visibility.isVisible = true
        #expect(await Self.waitUntil { Self.animatedViews(in: window).first?.isAnimating == true })

        visibility.isVisible = false
        #expect(await Self.waitUntil { Self.animatedViews(in: window).first?.isAnimating == false })
        #expect(Self.animatedViews(in: window).first?.data == playback.data, "scrolling away dropped the GIF")

        visibility.isVisible = true
        #expect(await Self.waitUntil { Self.animatedViews(in: window).first?.isAnimating == true })
        #expect(await calls.count == 1)
    }

    @MainActor
    @Test func playerDrawsFramesAndReportsWhereItIs() async throws {
        let cache = GiphyPlaybackCache()
        let data = try Self.animatedGIF(width: 4, height: 2, frames: 3)
        cache.insert(.init(data: data, aspectRatio: 2), for: Self.gifURL)
        let (window, player) = Self.playerWindow()
        defer { window.orderOut(nil) }
        player.onFrame = { cache.record($0, for: Self.gifURL) }

        player.show(data, resumingAt: nil)
        player.setAnimating(true)

        #expect(await Self.waitUntil { cache.position(for: Self.gifURL)?.frameIndex ?? 0 >= 1 })
        #expect(player.layer?.contents != nil)

        player.setAnimating(false)
        #expect(!player.isAnimating)
        #expect(player.layer?.contents != nil, "a paused GIF must keep its frame on screen")

        player.clear()
        #expect(player.layer?.contents == nil)
        #expect(player.data == nil)
    }

    /// A rebuilt player draws the frame its predecessor was on before its first tick, and picks
    /// the animation up from there instead of from the first frame.
    @MainActor
    @Test func playerResumesFromARecordedPosition() throws {
        let data = try Self.animatedGIF(width: 4, height: 2, frames: 3)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let thirdFrame = try #require(CGImageSourceCreateImageAtIndex(source, 2, nil))
        let (window, player) = Self.playerWindow()
        defer { window.orderOut(nil) }

        player.show(data, resumingAt: .init(frameIndex: 2, image: thirdFrame))

        #expect(player.frameIndex == 2)
        #expect((player.layer?.contents as! CGImage) === thirdFrame)
    }

    @MainActor
    @Test func playerOnlyRunsInAWindow() throws {
        let player = GiphyAnimatedNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        player.show(try Self.animatedGIF(width: 4, height: 2), resumingAt: nil)

        player.setAnimating(true)
        #expect(!player.isAnimating, "a recycled cell waiting off-window must not keep decoding")

        let (window, _) = Self.playerWindow()
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(player)
        #expect(player.isAnimating)

        player.removeFromSuperview()
        #expect(!player.isAnimating)
    }

    @MainActor
    @Test func playbackCacheKeepsAPositionOnlyForTheBytesItWasReadFrom() throws {
        let cache = GiphyPlaybackCache()
        let data = try Self.animatedGIF(width: 4, height: 2)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))

        cache.record(.init(frameIndex: 1, image: frame), for: Self.gifURL)
        #expect(cache.position(for: Self.gifURL) == nil, "a position without its GIF is meaningless")

        let playback = GiphyRemoteMediaLoader.PreparedPlayback(data: data, aspectRatio: 2)
        cache.insert(playback, for: Self.gifURL)
        cache.record(.init(frameIndex: 1, image: frame), for: Self.gifURL)
        cache.insert(playback, for: Self.gifURL)
        #expect(cache.playback(for: Self.gifURL) == playback)
        #expect(cache.position(for: Self.gifURL)?.frameIndex == 1, "storing the same GIF again lost its place")

        cache.insert(.init(data: try Self.animatedGIF(width: 2, height: 2), aspectRatio: 1), for: Self.gifURL)
        #expect(cache.position(for: Self.gifURL) == nil, "new bytes inherited the old GIF's frame")
    }

    @MainActor
    private static func playerWindow() -> (NSWindow, GiphyAnimatedNSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 20),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let player = GiphyAnimatedNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        window.contentView?.addSubview(player)
        window.orderFrontRegardless()
        return (window, player)
    }

    @MainActor
    private static func preferenceRemembering(_ url: URL) -> RemoteGIFLoadingPreference {
        let preference = RemoteGIFLoadingPreference(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        preference.recordLoadRequest(for: url)
        return preference
    }

    @MainActor
    private static func animatedViews(in window: NSWindow) -> [GiphyAnimatedNSView] {
        func collect(_ view: NSView) -> [GiphyAnimatedNSView] {
            (view as? GiphyAnimatedNSView).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        return window.contentView.map(collect) ?? []
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor
    private static func hostingWindow(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: view.frame(width: 320, height: 400))
        window.orderFrontRegardless()
        return window
    }

    private static func waitForPrepareCount(_ expected: Int, in calls: PrepareCallCounter) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await calls.count >= expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await calls.count >= expected
    }

    // MARK: Envelope

    @Test func wireTextRoundTripsTheExactGiphyURLAndCredit() throws {
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 480, height: 270, attribution: "Creator")

        #expect(media.wireText == "\(Self.gifURL.absoluteString)\nvia GIPHY · Creator")
        let parsed = try #require(RemoteGiphyMedia.parse(wireText: media.wireText))
        #expect(parsed.url.absoluteString == Self.gifURL.absoluteString)
        #expect(parsed.attribution == "Creator")

        let uncredited = RemoteGiphyMedia(url: Self.gifURL, width: 1, height: 1, attribution: nil)
        #expect(RemoteGiphyMedia.parse(wireText: uncredited.wireText)?.attribution == nil)
    }

    /// The exact envelope whitenoise-ios sends must parse here, or GIFs would not cross clients.
    @Test func parsesTheEnvelopeTheIOSClientSends() throws {
        let wire = "https://media.giphy.com/media/abc/giphy.mp4?cid=client&rid=giphy.mp4\nvia GIPHY · Someone"
        let parsed = try #require(RemoteGiphyMedia.parse(wireText: wire))
        #expect(parsed.url.pathExtension == "mp4")
        #expect(parsed.attribution == "Someone")
    }

    @Test(arguments: [
        "http://media.giphy.com/media/abc/giphy.gif",
        "https://giphy.com/media/abc/giphy.gif",
        "https://media.giphy.com.evil.example/media/abc/giphy.gif",
        "https://user@media.giphy.com/media/abc/giphy.gif",
        "https://media.giphy.com:443/media/abc/giphy.gif",
        "https://media.giphy.com/media/abc/index.html",
        "https://mediax.giphy.com/media/abc/giphy.gif",
    ])
    func rejectsUnsafeOrNonMediaURLs(_ rawURL: String) {
        #expect(RemoteGiphyMedia.validatedMediaURL(rawURL) == nil)
    }

    @Test(arguments: [
        "https://media.giphy.com/media/abc/giphy.gif",
        "https://media4.giphy.com/media/abc/giphy.webp",
        "https://i.giphy.com/media/abc/giphy.mp4",
    ])
    func acceptsGiphyCDNMediaURLs(_ rawURL: String) {
        #expect(RemoteGiphyMedia.validatedMediaURL(rawURL) != nil)
    }

    @Test func parserRejectsExtraOrMalformedMetadata() {
        let url = Self.gifURL.absoluteString
        #expect(RemoteGiphyMedia.parse(wireText: url) == nil)
        #expect(RemoteGiphyMedia.parse(wireText: "\(url)\nnot GIPHY") == nil)
        #expect(RemoteGiphyMedia.parse(wireText: "\(url)\nvia GIPHY\nextra") == nil)
        #expect(RemoteGiphyMedia.parse(wireText: "\(url)\nvia GIPHY · \(String(repeating: "a", count: 81))") == nil)
        #expect(RemoteGiphyMedia.parse(wireText: "hello\nvia GIPHY") == nil)
    }

    /// A credit line clipped or mangled upstream no longer parses as a GIF, but it must still read
    /// as a GIF in previews rather than leaking the CDN URL.
    @Test func previewLabelCoversEnvelopesTheParserRejects() {
        let label = L10n.string("GIF via GIPHY")
        #expect(RemoteGiphyMedia.envelopePreviewText(for: "https://media.giphy.com/media/abc/gi") == label)
        #expect(RemoteGiphyMedia.envelopePreviewText(for: "\(Self.gifURL.absoluteString)\nvia GIPH") == label)
        #expect(RemoteGiphyMedia.envelopePreviewText(for: "look at https://media.giphy.com/x.gif") == nil)
        #expect(RemoteGiphyMedia.envelopePreviewText(for: "https://example.com/cat.gif") == nil)
    }

    @MainActor
    @Test func messageItemExposesTheGIFAndLabelsItsReplyPreview() throws {
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 2, height: 1, attribution: "Creator")
        let message = MessageItem(
            id: "gif", senderName: "Alice", body: media.wireText, sentAt: .now, isOutgoing: false)

        #expect(try #require(message.remoteGiphyMedia).url == Self.gifURL)
        #expect(message.replyPreviewText == L10n.string("GIF via GIPHY"))

        let text = MessageItem(id: "text", senderName: "Alice", body: "hello", sentAt: .now, isOutgoing: false)
        #expect(text.remoteGiphyMedia == nil)
        #expect(text.replyPreviewText == "hello")
    }

    @Test func chatListPreviewNamesTheGIFInsteadOfItsURL() {
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 2, height: 1, attribution: nil)
        let row = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "Planning",
            groupName: "Planning",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "message-1",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                senderDisplayName: "Alice",
                plaintext: media.wireText,
                contentTokens: MarkdownDocumentFfi(blocks: [], truncated: false),
                kind: 9,
                timelineAt: 1,
                deleted: false
            ),
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 1,
            selfMembership: .member
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.preview.contains(L10n.string("GIF via GIPHY")))
        #expect(!chat.preview.contains("giphy.com"))
    }

    @MainActor
    @Test func notificationBodyNamesTheGIFInsteadOfItsURL() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 2, height: 1, attribution: "Creator")

        let request = state.localNotificationRequest(
            for: notificationUpdate(
                account: account,
                notificationKey: "gif-notice",
                senderName: "Alice",
                previewText: media.wireText
            ))

        #expect(!request.body.contains("giphy.com"))
        if state.notificationPreviewMode == .full {
            #expect(request.body == L10n.string("GIF via GIPHY"))
        }
    }

    // MARK: Build configuration

    @Test func buildConfigTreatsMissingBlankAndUnresolvedKeysAsUnavailable() {
        #expect(!GiphyBuildConfig.current(infoDictionary: [:]).isAvailable)
        #expect(!GiphyBuildConfig.current(infoDictionary: [GiphyBuildConfig.infoDictionaryKey: "  \n"]).isAvailable)
        #expect(
            !GiphyBuildConfig.current(infoDictionary: [GiphyBuildConfig.infoDictionaryKey: "$(WN_GIPHY_API_KEY)"])
                .isAvailable)
        #expect(
            GiphyBuildConfig.current(infoDictionary: [GiphyBuildConfig.infoDictionaryKey: "  test-key  "]).apiKey
                == "test-key")
    }

    // MARK: Search client

    @Test func searchURLKeepsTheQueryAndGiphyParameters() throws {
        let url = try #require(
            GiphySearchClient.searchURL(
                query: "tiny cats & dogs", apiKey: "test-key", locale: Locale(identifier: "pt_PT"))
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) }
            }
        )

        #expect(components.scheme == "https")
        #expect(components.host == "api.giphy.com")
        #expect(components.path == "/v1/gifs/search")
        #expect(values["q"] == "tiny cats & dogs")
        #expect(values["api_key"] == "test-key")
        #expect(values["rating"] == "pg-13")
        #expect(values["lang"] == "pt")
        #expect(values["bundle"] == "messaging_non_clips")
        #expect(GiphySearchClient.searchURL(query: "cats", apiKey: "", locale: .current) == nil)
    }

    @Test func decodedResultsPickTheLargestGIFUnderTheByteBudget() throws {
        let results = try GiphySearchClient.decodeResults(from: Data(Self.searchResponseJSON.utf8))

        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.id == "abc123")
        #expect(result.title == "Happy Cat")
        #expect(result.media.url.absoluteString == "https://media2.giphy.com/media/abc123/200.gif")
        #expect(result.media.width == 356)
        #expect(result.media.height == 200)
        #expect(result.media.attribution == "Cat Person")
    }

    @Test func decodeRejectsMalformedJSON() {
        #expect(throws: GiphySearchError.badResponse) {
            try GiphySearchClient.decodeResults(from: Data("{".utf8))
        }
    }

    @Test func searchFailsClosedOnTransportFailureAndOverlongQueries() async throws {
        let client = GiphySearchClient(apiKey: "key", fetch: { _ in nil })

        await #expect(throws: GiphySearchError.badResponse) { try await client.search("cats") }
        await #expect(throws: GiphySearchError.queryTooLong) {
            try await client.search(String(repeating: "a", count: GiphySearchClient.maximumQueryLength + 1))
        }
        #expect(try await client.search("   ").isEmpty)
    }

    @Test func legacyURLYieldsItsGiphyID() throws {
        let url = try #require(URL(string: "https://media.giphy.com/media/abc123/giphy.mp4"))
        #expect(GiphySearchClient.giphyID(from: url) == "abc123")
    }

    // MARK: Playback

    @Test func animatedGIFReadsDimensionsFromItsFirstFrame() throws {
        let aspectRatio = try GiphyRemoteMediaLoader.animatedImageAspectRatio(
            from: try Self.animatedGIF(width: 2, height: 1))
        #expect(aspectRatio == 2)
    }

    @Test func aSingleFrameImageIsNotAcceptedAsAGIF() throws {
        #expect(throws: GiphyRemoteMediaLoader.Failure.invalidResponse) {
            try GiphyRemoteMediaLoader.animatedImageAspectRatio(
                from: try Self.animatedGIF(width: 2, height: 1, frames: 1))
        }
        #expect(throws: GiphyRemoteMediaLoader.Failure.invalidResponse) {
            try GiphyRemoteMediaLoader.animatedImageAspectRatio(from: Data("not an image".utf8))
        }
    }

    @Test func preparePlaybackDownloadsAndValidatesTheGIF() async throws {
        let gif = try Self.animatedGIF(width: 3, height: 1)
        let requested = RequestLog()
        let media = RemoteGiphyMedia(url: Self.gifURL, width: 1, height: 1, attribution: nil)

        let prepared = try await GiphyRemoteMediaLoader.preparePlayback(for: media, apiKey: nil) { url in
            await requested.append(url)
            return gif
        }

        #expect(prepared.data == gif)
        #expect(prepared.aspectRatio == 3)
        #expect(await requested.urls == [Self.gifURL])
    }

    @Test func legacyMP4EnvelopeResolvesToItsGIFRendition() async throws {
        let gif = try Self.animatedGIF(width: 2, height: 1)
        let requested = RequestLog()
        let legacy = RemoteGiphyMedia(
            url: URL(string: "https://media.giphy.com/media/abc123/giphy.mp4")!, width: 4, height: 3, attribution: nil)
        let lookup = Data(#"{"data": \#(Self.itemJSON)}"#.utf8)

        let prepared = try await GiphyRemoteMediaLoader.preparePlayback(for: legacy, apiKey: "key") { url in
            await requested.append(url)
            return url.host == "api.giphy.com" ? lookup : gif
        }

        #expect(prepared.aspectRatio == 2)
        let urls = await requested.urls
        #expect(urls.count == 2)
        #expect(urls.first?.path == "/v1/gifs/abc123")
        #expect(urls.last?.absoluteString == "https://media2.giphy.com/media/abc123/200.gif")
    }

    @Test func legacyMP4EnvelopeWithoutAnAPIKeyFails() async {
        let legacy = RemoteGiphyMedia(
            url: URL(string: "https://media.giphy.com/media/abc123/giphy.mp4")!, width: 4, height: 3, attribution: nil)

        await #expect(throws: GiphyRemoteMediaLoader.Failure.invalidResponse) {
            _ = try await GiphyRemoteMediaLoader.preparePlayback(for: legacy, apiKey: nil) { _ in
                Issue.record("nothing may be fetched without a key")
                return nil
            }
        }
    }

    @Test func decodedGeometrySurvivesPlaybackTeardown() {
        var geometry = StableGiphyDisplayGeometry(fallbackAspectRatio: 1)
        geometry.record(decodedAspectRatio: 16.0 / 9.0)
        let resolved = geometry.aspectRatio

        geometry.record(decodedAspectRatio: nil)
        geometry.record(decodedAspectRatio: .nan)
        geometry.record(decodedAspectRatio: 0)

        #expect(geometry.aspectRatio == resolved)
    }

    // MARK: Picker model

    @MainActor
    @Test func searchPublishesResultsForTheTrimmedQuery() async {
        let queries = RequestLog()
        let result = Self.result(id: "one")
        let model = GiphySearchViewModel(
            search: { query in
                await queries.append(URL(string: "q:\(query)")!)
                return [result]
            },
            send: { _ in },
            debounce: .zero
        )

        model.query = "  cats  "
        await model.searchAfterDebounce()

        #expect(model.results == [result])
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
        #expect(await queries.urls.map(\.absoluteString) == ["q:cats"])

        model.query = " "
        await model.searchAfterDebounce()
        #expect(model.results.isEmpty)
    }

    @MainActor
    @Test func searchFailureSurfacesItsMessage() async {
        let model = GiphySearchViewModel(
            search: { _ in throw GiphySearchError.badResponse },
            send: { _ in },
            debounce: .zero
        )

        model.query = "cats"
        await model.searchAfterDebounce()

        #expect(model.results.isEmpty)
        #expect(model.errorMessage == GiphySearchError.badResponse.localizedDescription)
    }

    @MainActor
    @Test func selectingAResultSendsItsEnvelopeAndReportsFailure() async {
        let result = Self.result(id: "one")
        let sender = SendRecorder()
        let model = GiphySearchViewModel(
            search: { _ in [] },
            send: { media in try sender.send(media) },
            debounce: .zero
        )

        #expect(await model.select(result))
        #expect(sender.sent == [result.media])
        #expect(model.sendingResultID == nil)
        #expect(model.sendErrorMessage == nil)

        sender.failNext = true
        #expect(!(await model.select(result)))
        #expect(model.sendErrorMessage == GiphySearchError.badResponse.localizedDescription)
    }

    // MARK: Preference

    @MainActor
    @Test func autoLoadPreferenceDefaultsOffPersistsAndResets() throws {
        let suite = "giphy-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!RemoteGIFLoadingPreference(defaults: defaults).automaticallyLoads)

        RemoteGIFLoadingPreference(defaults: defaults).setAutomaticallyLoads(true)
        let reloaded = RemoteGIFLoadingPreference(defaults: defaults)
        #expect(reloaded.automaticallyLoads)

        reloaded.recordLoadRequest(for: Self.gifURL)
        #expect(reloaded.wasLoadRequested(for: Self.gifURL))

        reloaded.reset()
        #expect(!reloaded.automaticallyLoads)
        #expect(!reloaded.wasLoadRequested(for: Self.gifURL))
        #expect(!RemoteGIFLoadingPreference(defaults: defaults).automaticallyLoads)
    }

    // MARK: Fixtures

    @MainActor
    private final class SendRecorder {
        var sent: [RemoteGiphyMedia] = []
        var failNext = false

        func send(_ media: RemoteGiphyMedia) throws {
            if failNext { throw GiphySearchError.badResponse }
            sent.append(media)
        }
    }

    private actor RequestLog {
        private(set) var urls: [URL] = []
        func append(_ url: URL) { urls.append(url) }
    }

    private static func result(id: String) -> GiphySearchResult {
        GiphySearchResult(
            id: id,
            title: "Cat",
            media: RemoteGiphyMedia(url: gifURL, width: 2, height: 1, attribution: nil)
        )
    }

    /// One item with a GIF over the preferred budget (`original`), one under it (`fixed_height`),
    /// an MP4-only rendition, and a rendition on a foreign host — only `fixed_height` qualifies.
    private static let itemJSON = """
        {
          "id": "abc123",
          "title": "Happy\\u202E Cat",
          "username": "",
          "source_tld": "example.com",
          "user": { "username": "catperson", "display_name": "Cat Person" },
          "images": {
            "original": { "width": "480", "height": "270", "url": "https://media2.giphy.com/media/abc123/giphy.gif", "size": "4000000" },
            "fixed_height": { "width": "356", "height": "200", "url": "https://media2.giphy.com/media/abc123/200.gif", "size": "900000" },
            "fixed_width": { "width": "200", "height": "112", "url": "https://media2.giphy.com/media/abc123/200w.mp4", "size": "100000" },
            "downsized": { "width": "400", "height": "225", "url": "https://evil.example/abc123/giphy.gif", "size": "100000" }
          }
        }
        """

    private static let searchResponseJSON = """
        { "data": [\(itemJSON), { "id": "broken", "title": "No renditions", "images": {} }] }
        """

    private static func animatedGIF(width: Int, height: Int, frames: Int = 2) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        let frameProperties =
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        for index in 0..<frames {
            context.setFillColor(CGColor(red: CGFloat(index % 2), green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), frameProperties)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor PrepareCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// A download that ignores cancellation until it is let through, the way a network fetch keeps
/// running for a while after its task is cancelled.
private actor PrepareGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
