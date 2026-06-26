//
//  ComposerViews.swift
//  whitenoise-mac
//
//  Composition surface: the conversation header, pending-media draft strip
//  and thumbnail decoding, voice-recording composer and audio waveform,
//  timeline loading rows, reply context, the new-chat column/form/recipient
//  card, and the profile-image avatar. Extracted verbatim from
//  MessengerShellView.swift (no behavior change).
//

import AppKit
import ImageIO
import SwiftUI

struct PendingMediaDraftStrip: View {
    let attachments: [PendingMediaAttachment]
    let onRemove: (PendingMediaAttachment.ID) -> Void

    private let tileSize = CGSize(width: 74, height: 74)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        PendingMediaDraftTile(attachment: attachment, tileSize: tileSize)

                        Button {
                            onRemove(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color(nsColor: .windowBackgroundColor), Color.primary.opacity(0.82))
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                        .offset(x: 7, y: -7)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
    }
}

struct PendingMediaDraftTile: View {
    let attachment: PendingMediaAttachment
    let tileSize: CGSize

    @State private var decodedImagePreview: NSImage?
    @State private var decodedImageCacheKey: String?

    // The composer only shows a handful of draft tiles. Keep thumbnails bounded while allowing
    // enough headroom for several ~148px previews and matching failed-decode entries.
    private static let imagePreviewCacheCountLimit = 64
    private static let failedImagePreviewCacheCountLimit = imagePreviewCacheCountLimit
    private static let imagePreviewCacheTotalCostLimit =
        PendingMediaDraftThumbnailDecoder.defaultDecodedCacheTotalCostLimit

    private static let imagePreviewCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = imagePreviewCacheCountLimit
        cache.totalCostLimit = imagePreviewCacheTotalCostLimit
        return cache
    }()

    private static let failedImagePreviewCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = failedImagePreviewCacheCountLimit
        return cache
    }()

    var body: some View {
        Group {
            switch attachment.kind {
            case .image:
                imagePreview
                    .task(id: imagePreviewTaskID) {
                        await loadImagePreview()
                    }
            case .audio:
                audioPreview
            case .video, .file:
                filePreview
            }
        }
        .frame(width: tileSize.width, height: tileSize.height)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let image = decodedImagePreview {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityLabel(attachment.fileName)
        } else {
            iconPreview(systemName: attachment.kind.systemImageName)
        }
    }

    private var imagePreviewTaskID: String {
        Self.cacheKey(for: attachment, maxPixelSize: imagePreviewMaxPixelSize)
    }

    private var imagePreviewMaxPixelSize: CGFloat {
        ceil(max(tileSize.width, tileSize.height) * 2)
    }

    @MainActor
    private func loadImagePreview() async {
        let cacheKey = imagePreviewTaskID
        let nsCacheKey = cacheKey as NSString
        if decodedImageCacheKey == cacheKey {
            return
        }
        if let cached = Self.imagePreviewCache.object(forKey: nsCacheKey) {
            decodedImageCacheKey = cacheKey
            decodedImagePreview = cached
            return
        }
        if Self.failedImagePreviewCache.object(forKey: nsCacheKey) != nil {
            decodedImageCacheKey = cacheKey
            decodedImagePreview = nil
            return
        }

        decodedImageCacheKey = cacheKey
        decodedImagePreview = nil

        let data = attachment.data
        let maxPixelSize = imagePreviewMaxPixelSize
        let decoded = await Task.detached(priority: .utility) {
            PendingMediaDraftThumbnailDecoder.image(from: data, maxPixelSize: maxPixelSize)
        }.value

        guard decodedImageCacheKey == cacheKey else { return }
        if let decoded {
            Self.failedImagePreviewCache.removeObject(forKey: nsCacheKey)
            Self.imagePreviewCache.setObject(
                decoded,
                forKey: nsCacheKey,
                cost: PendingMediaDraftThumbnailDecoder.decodedCost(for: decoded)
            )
        } else {
            Self.failedImagePreviewCache.setObject(NSNumber(value: true), forKey: nsCacheKey)
        }
        decodedImagePreview = decoded
    }

    private static func cacheKey(for attachment: PendingMediaAttachment, maxPixelSize: CGFloat) -> String {
        "\(attachment.id.uuidString)|\(attachment.data.count)|\(Int(maxPixelSize))"
    }

    private var audioPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                ComposerAudioWaveformView(
                    samples: attachment.waveformSamples,
                    progress: 0,
                    barColor: Color.accentColor.opacity(0.82),
                    playedColor: Color.accentColor
                )
                .frame(height: 24)

                Text(attachment.durationLabel ?? attachment.sizeLabel)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
    }

    private var filePreview: some View {
        VStack(spacing: 5) {
            Image(systemName: attachment.kind.systemImageName)
                .font(.system(size: 18, weight: .semibold))
            Text(attachment.fileName)
                .font(.caption2.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    private func iconPreview(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

enum PendingMediaDraftThumbnailDecoder {
    static let defaultDecodedCacheTotalCostLimit = 8 * 1024 * 1024

    static func image(from data: Data, maxPixelSize: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(1, maxPixelSize)),
            ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func decodedCost(for image: NSImage) -> Int {
        let representation = image.representations.first
        let width = max(1, representation?.pixelsWide ?? Int(ceil(image.size.width)))
        let height = max(1, representation?.pixelsHigh ?? Int(ceil(image.size.height)))
        guard width <= Int.max / max(height, 1) / 4 else {
            return defaultDecodedCacheTotalCostLimit
        }
        return width * height * 4
    }
}

struct VoiceRecordingComposerView: View {
    let samples: [CGFloat]
    let durationSeconds: Double
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.red)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Cancel recording")

            ComposerAudioWaveformView(
                samples: samples,
                progress: 0,
                barColor: Color.accentColor.opacity(0.70),
                playedColor: Color.accentColor,
                mode: .liveRecording
            )
            .frame(height: 30)

            Text(Self.durationLabel(durationSeconds))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Finish recording")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private static func durationLabel(_ duration: Double) -> String {
        MediaDurationLabel.string(for: duration)
    }
}

nonisolated enum ComposerAudioWaveformMode {
    case playback
    case liveRecording
}

nonisolated struct ComposerAudioWaveformBar: Equatable {
    let amplitude: CGFloat?
}

nonisolated enum ComposerAudioWaveformPresentation {
    static let amplitudeCurveExponent: Double = 0.45

    static func bars(
        for samples: [CGFloat],
        mode: ComposerAudioWaveformMode,
        count: Int = MediaWaveformAnalyzer.sampleCount
    ) -> [ComposerAudioWaveformBar] {
        let targetCount = max(0, count)
        guard targetCount > 0 else { return [] }
        switch mode {
        case .playback:
            return MediaWaveformAnalyzer.normalized(samples, count: targetCount)
                .map(displayAmplitude)
                .map { ComposerAudioWaveformBar(amplitude: $0) }
        case .liveRecording:
            let visibleSamples = samples.suffix(targetCount)
                .map(displayAmplitude)
                .map { ComposerAudioWaveformBar(amplitude: $0) }
            let blankCount = max(0, targetCount - visibleSamples.count)
            return Array(repeating: ComposerAudioWaveformBar(amplitude: nil), count: blankCount) + visibleSamples
        }
    }

    private static func displayAmplitude(_ sample: CGFloat) -> CGFloat {
        let bounded = min(1, max(0.05, sample))
        return min(1, max(0.05, CGFloat(pow(Double(bounded), amplitudeCurveExponent))))
    }
}

struct ComposerAudioWaveformView: View {
    let samples: [CGFloat]
    let progress: CGFloat
    let barColor: Color
    let playedColor: Color
    var mode: ComposerAudioWaveformMode = .playback

    var body: some View {
        GeometryReader { geometry in
            let bars = ComposerAudioWaveformPresentation.bars(for: samples, mode: mode)
            let spacing: CGFloat = 2
            let barCount = max(1, bars.count)
            let availableWidth = geometry.size.width - spacing * CGFloat(max(0, barCount - 1))
            let barWidth = max(2, availableWidth / CGFloat(barCount))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    Capsule()
                        .fill(fillColor(for: bar, index: index, count: bars.count))
                        .frame(
                            width: barWidth,
                            height: barHeight(for: bar, in: geometry.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .accessibilityHidden(true)
    }

    private func fillColor(for bar: ComposerAudioWaveformBar, index: Int, count: Int) -> Color {
        guard bar.amplitude != nil else { return .clear }
        let played = CGFloat(index) / CGFloat(max(1, count - 1)) <= progress
        return played ? playedColor : barColor
    }

    private func barHeight(for bar: ComposerAudioWaveformBar, in availableHeight: CGFloat) -> CGFloat {
        guard let amplitude = bar.amplitude else { return 4 }
        return max(4, availableHeight * min(1, max(0.08, amplitude)))
    }
}

struct TimelineInitialLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading messages...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading messages")
    }
}

struct TimelinePageLoadingRow: View {
    let isLoading: Bool

    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .opacity(isLoading ? 1 : 0.55)
            Spacer()
        }
        .frame(height: 28)
        .padding(.vertical, 2)
    }
}

struct ReplyComposerContextView: View {
    let context: MessageReplyContext
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MessagesPalette.sentBubble)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.senderName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(context.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .nativeGlassCircleButtonStyle()
            .help("Cancel reply")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard()
    }
}

struct NewChatColumnView: View {
    @Environment(WorkspaceState.self) private var workspace
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Create New Chat")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    workspace.closeNewChatComposer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .nativeGlassCircleButtonStyle()
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Public key")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextField("npub or hex public key", text: $workspace.newChatQuery)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .onSubmit {
                                Task { await workspace.resolveNewChatQuery() }
                            }
                            .task(id: workspace.newChatQuery) {
                                // Debounce keystrokes and let `.task(id:)` cancel the
                                // pending lookup when the query changes again, so a
                                // flurry of edits no longer spawns overlapping,
                                // untracked tasks that race to write composer state.
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                guard !Task.isCancelled else { return }
                                await workspace.resolveNewChatQueryIfReady()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .glassCard()
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(isSearchFocused ? MessagesPalette.sentBubble : Color.clear, lineWidth: 1)
                            }
                    }

                    if workspace.isResolvingNewChat {
                        Label("Looking up profile...", systemImage: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let recipient = workspace.resolvedNewChatRecipient {
                        NewChatRecipientCard(recipient: recipient)
                    }

                    NewChatDetailsForm()

                    if let lastError = workspace.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
        }
        .background {
            GlassPaneBackground(opacity: 0.5)
        }
        .task {
            isSearchFocused = true
        }
    }
}

struct NewChatDetailsForm: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Optional group name", text: $workspace.newChatName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .glassCard()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Optional description", text: $workspace.newChatDescription, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .glassCard()
            }

            Button {
                Task { await workspace.createNewChat() }
            } label: {
                Label(
                    workspace.isCreatingChat ? L10n.string("Creating...") : L10n.string("Create Chat"),
                    systemImage: "message"
                )
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .nativeGlassProminentButtonStyle()
            .disabled(workspace.resolvedNewChatRecipient == nil || workspace.isCreatingChat)
        }
    }
}

struct NewChatRecipientCard: View {
    @Environment(WorkspaceState.self) private var workspace
    let recipient: NewChatRecipient

    var body: some View {
        let publicKey = recipient.npub.isEmpty ? recipient.accountIdHex : recipient.npub

        HStack(spacing: 12) {
            ProfileImageAvatarView(
                seed: recipient.accountIdHex,
                initials: recipient.title,
                pictureURL: recipient.pictureURL,
                size: 44,
                isSelected: false
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(recipient.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(DisplayText.short(publicKey, head: 12, tail: 10))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Button {
                        workspace.copyText(publicKey)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L10n.string("Copy npub"))
                }
            }

            Spacer()
        }
        .padding(12)
        .glassCard()
    }
}

struct ProfileImageAvatarView: View {
    @Environment(WorkspaceState.self) private var workspace
    let seed: String
    let initials: String
    let pictureURL: String?
    let size: CGFloat
    let isSelected: Bool

    /// Only returns a fetchable URL when the user has opted into loading remote images AND the
    /// URL passes the safety policy (https + valid host). Otherwise nil, so a generated avatar
    /// is shown and no outbound request is made to a sender-chosen server.
    private var imageURL: URL? {
        guard workspace.loadRemoteImages else { return nil }
        return RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
    }

    var body: some View {
        Group {
            if let imageURL {
                DownsampledAsyncImage(url: imageURL, maxPixelSize: size * 2) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    AvatarView(seed: seed, initials: initials, size: size, isSelected: isSelected, drawsChrome: false)
                }
            } else {
                AvatarView(seed: seed, initials: initials, size: size, isSelected: isSelected, drawsChrome: false)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .modifier(AvatarChromeModifier(isSelected: isSelected))
    }
}

struct ConversationHeader: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem

    var body: some View {
        @Bindable var workspace = workspace

        ZStack {
            VStack(spacing: 4) {
                ProfileImageAvatarView(
                    seed: chat.avatarSeed,
                    initials: chat.title,
                    pictureURL: chat.pictureURL,
                    size: 38,
                    isSelected: false
                )

                Text(chat.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }
            .frame(maxWidth: 220)

            HStack {
                Spacer()

                if !chat.isDirect {
                    if chat.pendingConfirmation {
                        Button {
                            Task { await workspace.acceptGroupInvite(for: chat) }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background {
                                    MessagesCircleControlBackground()
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)
                        .help("Accept invite")

                        Button(role: .destructive) {
                            Task { await workspace.declineGroupInvite(for: chat) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background {
                                    MessagesCircleControlBackground()
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)
                        .help("Decline invite")
                    }

                    Button {
                        Task { await workspace.showGroupDetails(for: chat) }
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Group details")

                    Button {
                        workspace.showGroupImagePicker(for: chat)
                    } label: {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background {
                                MessagesCircleControlBackground()
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Set group image")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .frame(height: 76)
        .background {
            MessagesHeaderBackground()
        }
        .sheet(isPresented: $workspace.isGroupDetailsPresented) {
            GroupDetailsSheet(chat: chat)
        }
        .sheet(isPresented: $workspace.isGroupImagePickerPresented) {
            GroupImagePickerSheet()
        }
    }
}
