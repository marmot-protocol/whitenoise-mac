//
//  MessageMediaViews.swift
//  whitenoise-mac
//
//  Message rendering and media subsystem: message rows, MessageBubble,
//  visual-media grids/tiles, attachment rows, audio/video players, the
//  image gallery overlay, and inline message actions/reactions. Extracted
//  verbatim from MessengerShellView.swift (no behavior change).
//

import AVFoundation
import AVKit
import AppKit
import SwiftUI

struct ConversationMessageRow: View {
    let message: MessageItem
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void

    // Receives the resolved MessageItem by value (not via a shared @Observable lookup),
    // so SwiftUI diffs each row by value and only re-runs the rows that actually changed
    // instead of invalidating every visible row on each page load / streaming update.
    var body: some View {
        if message.presentation.isChatBubble {
            MessageBubble(message: message, onOpenImageGallery: onOpenImageGallery)
        } else {
            TimelineNoticeRow(message: message)
        }
    }
}

struct TimelineNoticeRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem

    var body: some View {
        HStack {
            Spacer(minLength: 24)

            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: message.presentation.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)

                    Text(message.body)
                        .font(.caption.weight(.medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)

                    Text(message.timeLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if workspace.streamingDebugEnabled {
                    MessageDebugMetadataView(message: message, isOutgoing: false)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                GlassCapsuleBackground()
            }
            .frame(maxWidth: 520)
            .contextMenu {
                Button {
                    workspace.copyText(of: message)
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
            }

            Spacer(minLength: 24)
        }
    }
}

struct MessageBubble: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var isInlineActionPresentationActive = false
    let message: MessageItem
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isOutgoing { Spacer(minLength: 72) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 6) {
                if !message.isOutgoing {
                    Text(message.senderName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                if !message.visualMediaAttachments.isEmpty {
                    MessageVisualMediaGrid(
                        message: message,
                        attachments: message.visualMediaAttachments,
                        isOutgoing: message.isOutgoing,
                        onOpenImageGallery: onOpenImageGallery
                    )
                }

                ForEach(message.nonvisualMediaAttachments) { attachment in
                    MessageMediaAttachmentView(
                        downloadState: workspace.mediaDownloadStateStore(for: message, attachment: attachment),
                        message: message,
                        attachment: attachment,
                        isOutgoing: message.isOutgoing
                    )
                }

                if workspace.streamingDebugEnabled || message.hasBubbleContent {
                    bubbleContent
                }

                Text(message.metadataLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)

                if message.supportsChatActions && !message.reactions.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(message.reactions) { reaction in
                            Button {
                                Task {
                                    if reaction.canRemoveOwnReaction {
                                        await workspace.removeReaction(reaction, from: message)
                                    } else {
                                        await workspace.react(to: message, emoji: reaction.emoji)
                                    }
                                }
                            } label: {
                                Text(reaction.label)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background {
                                        GlassCapsuleBackground(
                                            borderColor: reaction.canRemoveOwnReaction
                                                ? MessagesPalette.sentBubble.opacity(0.45) : Color.white.opacity(0.18)
                                        )
                                    }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Capsule())
                            .help(
                                reaction.canRemoveOwnReaction
                                    ? "Remove \(reaction.emoji) reaction" : "React with \(reaction.emoji)")
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 660, alignment: message.isOutgoing ? .trailing : .leading)

            if !message.isOutgoing {
                Spacer(minLength: 72)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if message.canCopyText || message.canDelete {
                MessageOverflowMenuItems(message: message)
            }
        }
        .onHover { isHovering = $0 }
    }

    private var showsInlineActions: Bool {
        message.supportsChatActions && (isHovering || isInlineActionPresentationActive)
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if workspace.streamingDebugEnabled {
                MessageDebugMetadataView(message: message, isOutgoing: message.isOutgoing)
            }

            if let replyContext = message.replyContext {
                MessageReplyContextView(context: replyContext, isOutgoing: message.isOutgoing)
            }

            if !message.trimmedBody.isEmpty {
                Text(message.body)
                    .font(.system(size: 15.5))
                    .foregroundStyle(message.isOutgoing ? .white : .primary)
                    .lineSpacing(2)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background {
            bubbleBackground
        }
        .frame(maxWidth: 540, alignment: message.isOutgoing ? .trailing : .leading)
        .overlay(alignment: message.isOutgoing ? .leading : .trailing) {
            if showsInlineActions {
                MessageInlineActions(
                    isPresentationActive: $isInlineActionPresentationActive,
                    message: message
                )
                .offset(x: message.isOutgoing ? -100 : 100)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.12), value: showsInlineActions)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: message.isOutgoing ? 20 : 6,
            bottomTrailingRadius: message.isOutgoing ? 6 : 20,
            topTrailingRadius: 20,
            style: .continuous
        )

        if message.isOutgoing {
            shape
                .fill(MessagesPalette.sentBubble)
        } else {
            shape
                .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                .overlay {
                    shape
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.24), lineWidth: 1)
                }
        }
    }
}

struct MessageImageGalleryPresentation: Identifiable, Equatable {
    let id: String
    let message: MessageItem
    let imageAttachments: [MessageMediaAttachment]
    let initialIndex: Int

    init?(message: MessageItem, initialAttachment: MessageMediaAttachment) {
        let imageAttachments = message.mediaAttachments.filter { $0.kind == .image }
        guard !imageAttachments.isEmpty else { return nil }
        self.id = "\(message.id)-image-gallery"
        self.message = message
        self.imageAttachments = imageAttachments
        self.initialIndex = imageAttachments.firstIndex(of: initialAttachment) ?? 0
    }
}

struct MessageVisualMediaGrid: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    let attachments: [MessageMediaAttachment]
    let isOutgoing: Bool
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void

    private let maxWidth: CGFloat = 360
    private let spacing: CGFloat = 3
    private let cornerRadius: CGFloat = 10

    private var visibleAttachments: [MessageMediaAttachment] {
        Array(attachments.prefix(MessageMediaGridPresentation.visibleCount(totalCount: attachments.count)))
    }

    private var hiddenCount: Int {
        MessageMediaGridPresentation.hiddenCount(totalCount: attachments.count)
    }

    private var columnCount: Int {
        MessageMediaGridPresentation.columnCount(totalCount: attachments.count)
    }

    private var rowCount: Int {
        MessageMediaGridPresentation.rowCount(totalCount: attachments.count)
    }

    private var tileSide: CGFloat {
        MessageMediaGridPresentation.tileSide(totalCount: attachments.count, maxWidth: maxWidth, spacing: spacing)
    }

    private var gridHeight: CGFloat {
        MessageMediaGridPresentation.gridHeight(totalCount: attachments.count, maxWidth: maxWidth, spacing: spacing)
    }

    private var rowStarts: [Int] {
        rowCount == 1 ? [0] : [0, columnCount]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rowStarts, id: \.self) { rowStart in
                HStack(spacing: spacing) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        tile(at: rowStart + column)
                    }
                }
            }
        }
        .frame(width: maxWidth, height: gridHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(isOutgoing ? 0.16 : 0.1), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func tile(at index: Int) -> some View {
        if index < visibleAttachments.count {
            MessageVisualMediaTile(
                downloadState: workspace.mediaDownloadStateStore(for: message, attachment: visibleAttachments[index]),
                message: message,
                attachment: visibleAttachments[index],
                isOutgoing: isOutgoing,
                sideLength: tileSide,
                hiddenCount: index == MessageMediaGridPresentation.maxVisibleItems - 1 ? hiddenCount : 0,
                onOpenImageGallery: onOpenImageGallery
            )
        } else {
            Color.clear
                .frame(width: tileSide, height: tileSide)
        }
    }
}

struct MessageVisualMediaTile: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var downloadState: MediaDownloadStateStore
    let message: MessageItem
    let attachment: MessageMediaAttachment
    let isOutgoing: Bool
    let sideLength: CGFloat
    let hiddenCount: Int
    let onOpenImageGallery: (MessageImageGalleryPresentation) -> Void

    var body: some View {
        ZStack {
            content

            if hiddenCount > 0 {
                Color.black.opacity(0.46)
                Text("+\(hiddenCount)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: sideLength, height: sideLength)
        .contentShape(Rectangle())
        .clipped()
        .task(id: attachment.id) {
            await workspace.loadMediaAttachment(attachment, for: message)
        }
        .onTapGesture {
            if attachment.kind == .image,
                let gallery = MessageImageGalleryPresentation(message: message, initialAttachment: attachment)
            {
                onOpenImageGallery(gallery)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch downloadState.state {
        case .idle, .loading:
            placeholder(systemImage: attachment.kind == .video ? "play.rectangle" : "photo", isLoading: true)
        case .failed:
            placeholder(systemImage: "arrow.clockwise", isLoading: false)
        case .loaded(let download):
            switch attachment.kind {
            case .image:
                DownsampledDataImage(
                    data: download.data,
                    cacheKey: attachment.id,
                    maxPixelSize: sideLength * max(1, displayScale) * 2
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: sideLength, height: sideLength)
                        .clipped()
                        .accessibilityLabel(attachment.fileName)
                } placeholder: {
                    placeholder(systemImage: "photo", isLoading: false)
                }
            case .video:
                MessageVideoAttachmentPlayer(
                    download: download,
                    attachment: attachment,
                    isOutgoing: isOutgoing,
                    sideLength: sideLength
                )
            case .audio, .file:
                placeholder(systemImage: attachment.kind.systemImageName, isLoading: false)
            }
        }
    }

    private func placeholder(systemImage: String, isLoading: Bool) -> some View {
        ZStack {
            Color.primary.opacity(0.06)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MessageMediaAttachmentView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var downloadState: MediaDownloadStateStore
    let message: MessageItem
    let attachment: MessageMediaAttachment
    let isOutgoing: Bool

    var body: some View {
        Group {
            switch downloadState.state {
            case .idle, .loading:
                MessageAttachmentStatusRow(
                    systemImage: "arrow.down.circle",
                    title: attachment.fileName,
                    detail: attachment.mediaType,
                    isOutgoing: isOutgoing,
                    isLoading: true
                )
            case .loaded(let download):
                loadedContent(download)
            case .failed:
                MessageAttachmentStatusRow(
                    systemImage: "exclamationmark.triangle",
                    title: attachment.fileName,
                    detail: L10n.string("Attachment unavailable"),
                    isOutgoing: isOutgoing,
                    isLoading: false
                ) {
                    Task { await workspace.loadMediaAttachment(attachment, for: message) }
                }
            }
        }
        .task(id: attachment.id) {
            await workspace.loadMediaAttachment(attachment, for: message)
        }
    }

    @ViewBuilder
    private func loadedContent(_ download: MessageMediaDownload) -> some View {
        switch attachment.kind {
        case .image:
            DownsampledDataImage(
                data: download.data,
                cacheKey: attachment.id,
                maxPixelSize: 260 * max(1, displayScale) * 2
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 260, height: 260)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel(attachment.fileName)
            } placeholder: {
                MessageAttachmentStatusRow(
                    systemImage: "photo",
                    title: download.fileName.nilIfBlank ?? attachment.fileName,
                    detail: mediaDetail(download),
                    isOutgoing: isOutgoing
                )
            }
        case .audio:
            MessageAudioAttachmentPlayer(
                download: download,
                fallbackFileName: attachment.fileName,
                isOutgoing: isOutgoing
            )
        case .video:
            MessageVideoAttachmentPlayer(
                download: download,
                attachment: attachment,
                isOutgoing: isOutgoing,
                sideLength: 260
            )
        case .file:
            MessageDocumentAttachmentRow(
                download: download,
                attachment: attachment,
                isOutgoing: isOutgoing
            )
        }
    }

    private func mediaDetail(_ download: MessageMediaDownload) -> String {
        let type = download.mediaType.nilIfBlank ?? attachment.mediaType
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: download.sizeBytes), countStyle: .file)
        return "\(type) - \(size)"
    }
}

struct MessageDocumentAttachmentRow: View {
    let download: MessageMediaDownload
    let attachment: MessageMediaAttachment
    let isOutgoing: Bool

    var body: some View {
        MessageAttachmentStatusRow(
            systemImage: "doc",
            title: download.fileName.nilIfBlank ?? attachment.fileName,
            detail: mediaDetail,
            isOutgoing: isOutgoing
        ) {
            Task { await openAttachment() }
        }
    }

    private var mediaDetail: String {
        let type = download.mediaType.nilIfBlank ?? attachment.mediaType
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: download.sizeBytes), countStyle: .file)
        return "\(type) - \(size)"
    }

    @MainActor
    private func openAttachment() async {
        guard
            let url = await MessageMediaPlaybackFileStore.fileURL(
                attachment: attachment,
                download: download
            )
        else { return }
        // `open` returns once LaunchServices accepts the handoff; the receiving app may
        // still be reading the file. Delete shortly after so we don't leave decrypted
        // plaintext on disk, while giving the app a brief window to read the bytes.
        let didOpen = NSWorkspace.shared.open(url)
        let cleanupDelay: TimeInterval = didOpen ? cleanupDelaySeconds : 0
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + cleanupDelay) {
            MediaPlaybackTempStore.remove(at: url)
        }
    }

    private var cleanupDelaySeconds: TimeInterval { 30 }
}

struct MessageAttachmentStatusRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let isOutgoing: Bool
    var isLoading = false
    var retryAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(iconBackground)
                    .frame(width: 30, height: 30)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isOutgoing ? Color.white : Color.primary)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.72) : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let retryAction {
                Button(action: retryAction) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(L10n.string("Retry"))
            }
        }
        .foregroundStyle(isOutgoing ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        }
    }

    private var iconBackground: Color {
        isOutgoing ? Color.white.opacity(0.18) : Color.primary.opacity(0.08)
    }

    private var rowBackground: Color {
        isOutgoing ? Color.white.opacity(0.12) : Color.primary.opacity(0.06)
    }
}

struct PreparedMessageAudioPlayer: @unchecked Sendable {
    let player: AVAudioPlayer
}

@MainActor
final class MessageAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onDidFinishPlaying: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        player.currentTime = 0
        onDidFinishPlaying?()
    }
}

struct MessageAudioAttachmentPlayer: View {
    let download: MessageMediaDownload
    let fallbackFileName: String
    let isOutgoing: Bool
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playbackPreparationID: UUID?
    @State private var playbackProgress: CGFloat = 0
    @State private var metadata: MediaWaveformAnalyzer.Metadata?
    @State private var playbackMonitor: Task<Void, Never>?
    @State private var audioPlayerDelegate = MessageAudioPlayerDelegate()

    private var isPreparingPlayback: Bool {
        playbackPreparationID != nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await togglePlayback() }
            } label: {
                Image(systemName: isPlaying || isPreparingPlayback ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background {
                        Circle()
                            .fill(isOutgoing ? Color.white.opacity(0.18) : Color.primary.opacity(0.08))
                    }
            }
            .buttonStyle(.plain)
            .help(isPlaying || isPreparingPlayback ? L10n.string("Stop") : L10n.string("Play"))

            VStack(alignment: .leading, spacing: 2) {
                Text(download.fileName.nilIfBlank ?? fallbackFileName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    ComposerAudioWaveformView(
                        samples: metadata?.samples ?? MediaWaveformAnalyzer.fallback(),
                        progress: playbackProgress,
                        barColor: isOutgoing ? Color.white.opacity(0.42) : Color.secondary.opacity(0.55),
                        playedColor: isOutgoing ? Color.white.opacity(0.9) : Color.accentColor
                    )
                    .frame(height: 24)

                    Text(durationLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.72) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(isOutgoing ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOutgoing ? Color.white.opacity(0.12) : Color.primary.opacity(0.06))
        }
        .onDisappear {
            stopPlayback()
        }
        .task(id: "\(download.fileName)-\(download.sizeBytes)-\(download.mediaType)") {
            let data = download.data
            let mediaType = download.mediaType
            metadata = await Task.detached(priority: .utility) {
                MediaWaveformAnalyzer.metadata(from: data, mediaType: mediaType)
            }.value
        }
    }

    private var durationLabel: String {
        if let durationSeconds = metadata?.durationSeconds {
            return MediaDurationLabel.string(for: durationSeconds)
        }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: download.sizeBytes), countStyle: .file)
    }

    private func togglePlayback() async {
        if isPlaying || isPreparingPlayback {
            stopPlayback()
        } else {
            await startPlayback()
        }
    }

    private func startPlayback() async {
        var preparationID: UUID?
        do {
            if player == nil {
                let data = download.data
                let nextPreparationID = UUID()
                preparationID = nextPreparationID
                playbackPreparationID = nextPreparationID
                let preparedPlayer = try await Task.detached(priority: .userInitiated) {
                    let audioPlayer = try AVAudioPlayer(data: data)
                    audioPlayer.prepareToPlay()
                    return PreparedMessageAudioPlayer(player: audioPlayer)
                }.value.player
                guard playbackPreparationID == nextPreparationID else { return }
                playbackPreparationID = nil
                player = preparedPlayer
                preparedPlayer.delegate = audioPlayerDelegate
            }
            audioPlayerDelegate.onDidFinishPlaying = handlePlaybackFinished
            player?.play()
            isPlaying = true
            updatePlaybackProgress()
            monitorPlaybackProgress()
        } catch {
            if preparationID == nil || playbackPreparationID == preparationID {
                playbackPreparationID = nil
                isPlaying = false
            }
        }
    }

    private func stopPlayback() {
        playbackPreparationID = nil
        audioPlayerDelegate.onDidFinishPlaying = nil
        player?.stop()
        player?.currentTime = 0
        finishPlayback()
    }

    private func handlePlaybackFinished() {
        finishPlayback()
    }

    private func finishPlayback() {
        playbackMonitor?.cancel()
        playbackMonitor = nil
        isPlaying = false
        playbackProgress = 0
    }

    private func monitorPlaybackProgress() {
        playbackMonitor?.cancel()
        playbackMonitor = Task { @MainActor in
            while !Task.isCancelled, isPlaying {
                updatePlaybackProgress()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func updatePlaybackProgress() {
        guard let player, player.duration > 0 else {
            playbackProgress = 0
            return
        }
        playbackProgress = min(1, max(0, CGFloat(player.currentTime / player.duration)))
    }
}

struct MessageVideoAttachmentPlayer: View {
    let download: MessageMediaDownload
    let attachment: MessageMediaAttachment
    let isOutgoing: Bool
    let sideLength: CGFloat

    @State private var player: AVPlayer?
    @State private var playbackURL: URL?
    @State private var isLoading = false
    @State private var didFail = false
    @State private var playbackPreparationID: UUID?
    @State private var playbackTask: Task<Void, Never>?

    private var isPreparingPlayback: Bool {
        playbackPreparationID != nil
    }

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: sideLength, height: sideLength)
                    .background(Color.black)
            } else {
                Color.black.opacity(0.86)
                Image(systemName: didFail ? "arrow.clockwise" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.45), in: Circle())

                VStack {
                    Spacer()
                    Text(download.fileName.nilIfBlank ?? attachment.fileName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
        }
        .frame(width: sideLength, height: sideLength)
        .contentShape(Rectangle())
        .onTapGesture {
            if isPreparingPlayback {
                playbackTask?.cancel()
                playbackTask = nil
                stopPlayback()
            } else {
                playbackTask?.cancel()
                playbackTask = Task { await togglePlayback() }
            }
        }
        .onDisappear {
            playbackTask?.cancel()
            playbackTask = nil
            stopPlayback()
        }
        .accessibilityLabel("Video attachment")
    }

    @MainActor
    private func togglePlayback() async {
        guard !Task.isCancelled else { return }

        if let player {
            if player.timeControlStatus == .playing {
                player.pause()
            } else {
                player.play()
            }
            return
        }

        if isPreparingPlayback {
            stopPlayback()
            return
        }

        await startPlayback()
    }

    @MainActor
    private func startPlayback() async {
        guard !Task.isCancelled else { return }

        let nextPreparationID = UUID()
        playbackPreparationID = nextPreparationID
        isLoading = true
        didFail = false
        defer {
            if playbackPreparationID == nextPreparationID {
                playbackPreparationID = nil
                isLoading = false
            }
        }

        let resolvedURL: URL?
        if let playbackURL {
            resolvedURL = playbackURL
        } else {
            resolvedURL = await MessageMediaPlaybackFileStore.fileURL(
                attachment: attachment,
                download: download
            )
        }
        guard playbackPreparationID == nextPreparationID, !Task.isCancelled else { return }
        guard let url = resolvedURL else {
            didFail = true
            return
        }
        playbackURL = url
        let next = AVPlayer(url: url)
        player = next
        next.play()
    }

    /// Cancels in-flight preparation, releases the player, and deletes the decrypted scratch
    /// file. Ordered so `AVPlayer` no longer references the file before it is removed.
    private func stopPlayback() {
        playbackPreparationID = nil
        isLoading = false
        player?.pause()
        player = nil
        if let url = playbackURL {
            MessageMediaPlaybackFileStore.remove(at: url)
            playbackURL = nil
        }
    }
}

enum MessageMediaPlaybackFileStore {
    /// Materializes decrypted attachment plaintext into the sandboxed playback scratch
    /// directory. Callers own the returned URL and must delete it via `remove(at:)` once
    /// the consuming action (open/playback) finishes.
    @MainActor
    static func fileURL(attachment: MessageMediaAttachment, download: MessageMediaDownload) async -> URL? {
        let resolvedFileName = download.fileName.nilIfBlank ?? attachment.fileName
        let resolvedMediaType = download.mediaType.nilIfBlank ?? attachment.mediaType
        let attachmentID = attachment.id
        let data = download.data

        return await Task.detached(priority: .utility) {
            do {
                let directory = try MediaPlaybackTempStore.directoryURL()
                return try MediaPlaybackTempStore.materialize(
                    data: data,
                    id: attachmentID,
                    fileName: resolvedFileName,
                    fallbackExtension: OutgoingMediaAttachmentPolicy.fileExtension(
                        for: resolvedMediaType,
                        fileName: resolvedFileName
                    ),
                    directory: directory
                )
            } catch {
                return nil
            }
        }.value
    }

    static func remove(at url: URL) {
        MediaPlaybackTempStore.remove(at: url)
    }
}

struct MessageImageGalleryOverlay: View {
    @Environment(WorkspaceState.self) private var workspace
    let presentation: MessageImageGalleryPresentation
    let onClose: () -> Void
    @State private var selectedIndex: Int

    init(presentation: MessageImageGalleryPresentation, onClose: @escaping () -> Void) {
        self.presentation = presentation
        self.onClose = onClose
        _selectedIndex = State(initialValue: presentation.initialIndex)
    }

    private var selectedAttachment: MessageMediaAttachment {
        presentation.imageAttachments[min(max(0, selectedIndex), presentation.imageAttachments.count - 1)]
    }

    private var canNavigate: Bool {
        presentation.imageAttachments.count > 1
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.92)

                imageContent
                    .frame(
                        maxWidth: max(1, geometry.size.width - 104),
                        maxHeight: max(1, geometry.size.height - 120)
                    )

                VStack {
                    HStack(spacing: 12) {
                        Text(selectedAttachment.fileName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer()

                        if canNavigate {
                            Text("\(selectedIndex + 1) / \(presentation.imageAttachments.count)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 34, height: 34)
                                .background(Color.white.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .help("Close")
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                    Spacer()
                }

                if canNavigate {
                    HStack {
                        navigationButton(systemName: "chevron.left", isEnabled: selectedIndex > 0) {
                            selectedIndex = max(0, selectedIndex - 1)
                        }

                        Spacer()

                        navigationButton(
                            systemName: "chevron.right",
                            isEnabled: selectedIndex < presentation.imageAttachments.count - 1
                        ) {
                            selectedIndex = min(presentation.imageAttachments.count - 1, selectedIndex + 1)
                        }
                    }
                    .padding(.horizontal, 22)
                }
            }
            .task(id: selectedAttachment.id) {
                await workspace.loadMediaAttachment(selectedAttachment, for: presentation.message)
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        MessageImageGalleryContent(
            downloadState: workspace.mediaDownloadStateStore(for: presentation.message, attachment: selectedAttachment),
            message: presentation.message,
            attachment: selectedAttachment
        )
    }

    private func navigationButton(
        systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .bold))
                .frame(width: 54, height: 54)
                .background(Color.white.opacity(isEnabled ? 0.16 : 0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isEnabled ? 0.96 : 0.28))
        .disabled(!isEnabled)
        .help(systemName == "chevron.left" ? "Previous image" : "Next image")
    }
}

struct MessageImageGalleryContent: View {
    @Environment(WorkspaceState.self) private var workspace
    @ObservedObject var downloadState: MediaDownloadStateStore
    let message: MessageItem
    let attachment: MessageMediaAttachment

    var body: some View {
        switch downloadState.state {
        case .idle, .loading:
            ProgressView()
                .controlSize(.regular)
                .tint(.white)
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                Text("Image unavailable")
                    .font(.callout.weight(.semibold))
                Button {
                    Task { await workspace.loadMediaAttachment(attachment, for: message) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            .foregroundStyle(.white)
        case .loaded(let download):
            DownsampledMessageGalleryImage(download: download, attachment: attachment)
        }
    }
}

struct DownsampledMessageGalleryImage: View {
    @Environment(\.displayScale) private var displayScale
    let download: MessageMediaDownload
    let attachment: MessageMediaAttachment

    var body: some View {
        GeometryReader { proxy in
            DownsampledDataImage(
                data: download.data,
                cacheKey: attachment.id,
                maxPixelSize: DownsampledImageSizing.galleryPixelSize(
                    for: proxy.size,
                    displayScale: displayScale
                )
            ) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(attachment.fileName)
            } placeholder: {
                Text("Image unavailable")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct MessageDebugMetadataView: View {
    let message: MessageItem
    let isOutgoing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.debugTitle)
                .font(.caption2.weight(.semibold).monospaced())
            Text(message.debugDetail)
                .font(.caption2.monospaced())
                .lineLimit(1)
        }
        .foregroundStyle(isOutgoing ? Color.white.opacity(0.74) : Color.primary.opacity(0.52))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageInlineActions: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isEmojiPickerPresented = false
    @State private var isOverflowPresented = false
    @Binding var isPresentationActive: Bool
    let message: MessageItem

    var body: some View {
        HStack(spacing: 6) {
            if message.canReact {
                Button {
                    isEmojiPickerPresented = true
                } label: {
                    MessageInlineActionIcon(systemName: "face.smiling", label: "React")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isEmojiPickerPresented, arrowEdge: .bottom) {
                    MessageEmojiPickerPopover { emoji in
                        isEmojiPickerPresented = false
                        Task { await workspace.react(to: message, emoji: emoji) }
                    }
                }
                .help("React")
            }

            if message.canReply {
                Button {
                    workspace.startReply(to: message)
                } label: {
                    MessageInlineActionIcon(systemName: "arrowshape.turn.up.left", label: "Reply")
                }
                .buttonStyle(.plain)
                .help("Reply")
            }

            if message.canCopyText || message.canDelete {
                Button {
                    isOverflowPresented = true
                } label: {
                    MessageInlineActionIcon(systemName: "ellipsis", label: "More")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isOverflowPresented, arrowEdge: .bottom) {
                    MessageOverflowPopover(message: message) {
                        isOverflowPresented = false
                    }
                }
                .help("More")
            }
        }
        .frame(width: 92, height: 32)
        .onChange(of: isEmojiPickerPresented) { _, _ in
            syncPresentationState()
        }
        .onChange(of: isOverflowPresented) { _, _ in
            syncPresentationState()
        }
        .onDisappear {
            isPresentationActive = false
        }
    }

    private func syncPresentationState() {
        isPresentationActive = isEmojiPickerPresented || isOverflowPresented
    }
}

struct MessageInlineActionIcon: View {
    let systemName: String
    let label: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }
}

struct MessageEmojiPickerPopover: View {
    let onPick: (String) -> Void

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 8), count: 8)
    private let emojis = [
        "👍", "👎", "❤️", "🔥", "🎉", "😂", "🤣", "😅",
        "😊", "😍", "😎", "🤔", "🙏", "👏", "🙌", "💪",
        "🤝", "👀", "😮", "😯", "😢", "😭", "😡", "🤯",
        "🥳", "😴", "🥲", "💯", "✅", "❌", "⭐️", "✨",
        "🚀", "👋", "🤙", "🫡", "🫶", "😬", "😇", "🤩",
        "🥹", "😆", "😁", "😄", "😋", "😌", "😐", "🙃",
        "😉", "😏", "😤", "😮‍💨", "🤗", "🤪", "🤨", "🧐",
        "💙", "💚", "💛", "🧡", "💜", "🤍", "🖤", "💔",
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onPick(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 24))
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 360, height: 304)
        .presentationBackground(.regularMaterial)
        .glassCard(material: .regularMaterial)
    }
}

struct MessageOverflowPopover: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if message.canCopyText {
                overflowButton("Copy Text", systemImage: "doc.on.doc") {
                    workspace.copyText(of: message)
                    dismiss()
                }
            }

            if message.canCopyText && message.canDelete {
                Divider()
            }

            if message.canDelete {
                overflowButton("Delete", systemImage: "trash", role: .destructive) {
                    dismiss()
                    Task { await workspace.deleteMessage(message) }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 190)
        .presentationBackground(.regularMaterial)
        .glassCard(material: .regularMaterial)
    }

    private func overflowButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }
}

struct MessageOverflowMenuItems: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem

    var body: some View {
        if message.canCopyText {
            Button {
                workspace.copyText(of: message)
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }
        }

        if message.canCopyText && message.canDelete {
            Divider()
        }

        if message.canDelete {
            Button(role: .destructive) {
                Task { await workspace.deleteMessage(message) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct MessageReplyContextView: View {
    let context: MessageReplyContext
    let isOutgoing: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isOutgoing ? Color.white.opacity(0.72) : MessagesPalette.sentBubble.opacity(0.68))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.9) : MessagesPalette.sentBubble)
                    .lineLimit(1)

                Text(context.body)
                    .font(.caption)
                    .foregroundStyle(isOutgoing ? Color.white.opacity(0.78) : Color.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            if isOutgoing {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.13))
            } else {
                GlassRoundedBackground(cornerRadius: 8)
            }
        }
    }
}
