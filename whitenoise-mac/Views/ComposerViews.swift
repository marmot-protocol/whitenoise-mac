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

struct ComposerMessageInputView: View {
    @Binding var text: String
    let onPasteMedia: ([OutgoingMediaPasteboardAttachment]) -> Void
    let onSend: () -> Void

    @State private var measuredHeight = ComposerMessageInputMetrics.minHeight

    var body: some View {
        ZStack(alignment: .topLeading) {
            ComposerMessageTextViewRepresentable(
                text: $text,
                measuredHeight: $measuredHeight,
                onPasteMedia: onPasteMedia,
                onSend: onSend
            )
            .frame(height: measuredHeight)

            if text.isEmpty {
                Text("Message")
                    .font(.body)
                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: ComposerMessageInputMetrics.minHeight)
    }
}

private enum ComposerMessageInputMetrics {
    static let minHeight: CGFloat = 20
    static let maxHeight: CGFloat = 96
}

nonisolated enum ComposerReturnKeyAction: Equatable {
    case send
    case insertLineBreak
    case deferToSystem
}

nonisolated enum ComposerKeyboardShortcutPolicy {
    static func returnKeyAction(for modifierFlags: NSEvent.ModifierFlags) -> ComposerReturnKeyAction {
        let meaningfulFlags =
            modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.shift, .control, .option, .command])
        if meaningfulFlags.isEmpty {
            return .send
        }
        if meaningfulFlags == .shift {
            return .insertLineBreak
        }
        return .deferToSystem
    }
}

private struct ComposerMessageTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let onPasteMedia: ([OutgoingMediaPasteboardAttachment]) -> Void
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, measuredHeight: $measuredHeight, onPasteMedia: onPasteMedia, onSend: onSend)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerPasteInterceptingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: ComposerMessageInputMetrics.minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        configureHandlers(for: textView, coordinator: context.coordinator)

        scrollView.documentView = textView
        DispatchQueue.main.async {
            context.coordinator.updateMeasuredHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.measuredHeight = $measuredHeight
        context.coordinator.onPasteMedia = onPasteMedia
        context.coordinator.onSend = onSend

        guard let textView = scrollView.documentView as? ComposerPasteInterceptingTextView else { return }
        configureHandlers(for: textView, coordinator: context.coordinator)
        textView.font = .preferredFont(forTextStyle: .body)
        if textView.string != text {
            textView.string = text
        }
        DispatchQueue.main.async {
            context.coordinator.updateMeasuredHeight(for: textView)
        }
    }

    private func configureHandlers(for textView: ComposerPasteInterceptingTextView, coordinator: Coordinator) {
        textView.mediaPasteHandler = { [weak coordinator] in
            coordinator?.handleMediaPaste() ?? false
        }
        textView.returnKeySendHandler = { [weak coordinator] in
            coordinator?.onSend()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var measuredHeight: Binding<CGFloat>
        var onPasteMedia: ([OutgoingMediaPasteboardAttachment]) -> Void
        var onSend: () -> Void

        init(
            text: Binding<String>,
            measuredHeight: Binding<CGFloat>,
            onPasteMedia: @escaping ([OutgoingMediaPasteboardAttachment]) -> Void,
            onSend: @escaping () -> Void
        ) {
            self.text = text
            self.measuredHeight = measuredHeight
            self.onPasteMedia = onPasteMedia
            self.onSend = onSend
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            updateMeasuredHeight(for: textView)
        }

        func handleMediaPaste() -> Bool {
            let attachments = OutgoingMediaPasteboardReader.attachments(from: .general)
            guard !attachments.isEmpty else { return false }
            onPasteMedia(attachments)
            return true
        }

        func updateMeasuredHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return }

            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let insetHeight = textView.textContainerInset.height * 2
            let height = min(
                ComposerMessageInputMetrics.maxHeight,
                max(ComposerMessageInputMetrics.minHeight, ceil(usedHeight + insetHeight))
            )
            if abs(measuredHeight.wrappedValue - height) > 0.5 {
                measuredHeight.wrappedValue = height
            }
        }
    }
}

@MainActor
private final class ComposerPasteInterceptingTextView: NSTextView {
    var mediaPasteHandler: (() -> Bool)?
    var returnKeySendHandler: (() -> Void)?

    override func paste(_ sender: Any?) {
        if mediaPasteHandler?() == true {
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\n" else {
            super.keyDown(with: event)
            return
        }

        // While a composition is marked, Return belongs to the input context — it commits the
        // pending candidate, so forwarding it must win over the send shortcut.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        switch ComposerKeyboardShortcutPolicy.returnKeyAction(for: event.modifierFlags) {
        case .send:
            returnKeySendHandler?()
        case .insertLineBreak:
            insertNewlineIgnoringFieldEditor(nil)
        case .deferToSystem:
            super.keyDown(with: event)
        }
    }
}

struct PendingMediaDraftStrip: View {
    let attachments: [PendingMediaAttachment]
    let uploadStates: [PendingMediaAttachment.ID: PendingMediaUploadState]
    let isSending: Bool
    let onRemove: (PendingMediaAttachment.ID) -> Void

    private let tileSize = CGSize(width: 74, height: 74)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        PendingMediaDraftTile(
                            attachment: attachment,
                            tileSize: tileSize,
                            uploadState: uploadStates[attachment.id]
                        )

                        if !isSending {
                            Button {
                                onRemove(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(
                                        Color(nsColor: .windowBackgroundColor), Color.primary.opacity(0.82))
                            }
                            .buttonStyle(.plain)
                            .help("Remove attachment")
                            .offset(x: 7, y: -7)
                        }
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
    let uploadState: PendingMediaUploadState?

    @State private var decodedImagePreview: NSImage?
    @State private var decodedImageTaskID: String?

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
        .overlay(alignment: .bottomTrailing) {
            if attachment.kind == .image, let uploadState {
                PendingMediaUploadStatusBadge(state: uploadState)
                    .padding(5)
            }
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
        Self.previewTaskID(for: attachment, maxPixelSize: imagePreviewMaxPixelSize)
    }

    private var imagePreviewMaxPixelSize: CGFloat {
        ceil(max(tileSize.width, tileSize.height) * 2)
    }

    @MainActor
    private func loadImagePreview() async {
        let taskID = imagePreviewTaskID
        if decodedImageTaskID == taskID {
            return
        }

        decodedImageTaskID = taskID
        decodedImagePreview = nil

        let data = attachment.data
        let maxPixelSize = imagePreviewMaxPixelSize
        let decoded = await Task.detached(priority: .utility) {
            PendingMediaDraftThumbnailDecoder.image(from: data, maxPixelSize: maxPixelSize)
        }.value

        guard decodedImageTaskID == taskID else { return }
        decodedImagePreview = decoded
    }

    private static func previewTaskID(for attachment: PendingMediaAttachment, maxPixelSize: CGFloat) -> String {
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

private struct PendingMediaUploadStatusBadge: View {
    let state: PendingMediaUploadState

    var body: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
            Circle()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)

            switch state {
            case .uploading:
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentColor)
                    .scaleEffect(0.62)
            case .uploaded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }
}

nonisolated enum PendingMediaDraftThumbnailDecoder {
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
        return DownsampledImageSizing.image(fromDownsampled: cgImage)
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
        .frame(maxWidth: .infinity)
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
    static let fallbackPlaybackBars = bars(for: MediaWaveformAnalyzer.fallbackSamples, mode: .playback)

    static func visiblePlaybackBars(
        loadedBars: [ComposerAudioWaveformBar],
        metadataPayloadID: String?,
        currentPayloadID: String
    ) -> [ComposerAudioWaveformBar] {
        metadataPayloadID == currentPayloadID ? loadedBars : fallbackPlaybackBars
    }

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
            // Live recordings grow while the user speaks, so this path intentionally
            // recomputes from the current samples instead of caching a stale snapshot.
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
    let bars: [ComposerAudioWaveformBar]
    let progress: CGFloat
    let barColor: Color
    let playedColor: Color

    // Convenience path for one-shot previews and live recording. Playback rows pass
    // precomputed bars so progress ticks only recolor already-prepared amplitudes.
    init(
        samples: [CGFloat],
        progress: CGFloat,
        barColor: Color,
        playedColor: Color,
        mode: ComposerAudioWaveformMode = .playback
    ) {
        self.init(
            bars: ComposerAudioWaveformPresentation.bars(for: samples, mode: mode),
            progress: progress,
            barColor: barColor,
            playedColor: playedColor
        )
    }

    init(
        bars: [ComposerAudioWaveformBar],
        progress: CGFloat,
        barColor: Color,
        playedColor: Color
    ) {
        self.bars = bars
        self.progress = progress
        self.barColor = barColor
        self.playedColor = playedColor
    }

    var body: some View {
        GeometryReader { geometry in
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

/// Replaces the composer for a group the local account left or was removed from:
/// the transcript stays readable, but the core would reject any send
/// (`invalid_transition`), so no input is offered.
struct MembershipEndedComposerNotice: View {
    let membership: ChatSelfMembership

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: membership.endedSymbolName ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(membership.endedDescription ?? "")
                    .font(.callout.weight(.semibold))

                Text(ChatSelfMembership.endedHistoryExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard()
        .accessibilityIdentifier("composer.membershipEnded")
    }
}

/// Replaces the composer until the user accepts or declines a pending group invite.
struct PendingGroupInviteComposerNotice: View {
    @Environment(WorkspaceState.self) private var workspace
    let chat: ChatItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(inviteMessage)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(L10n.string("If you decline, this chat will be removed from your chat list."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await workspace.acceptGroupInvite(for: chat) }
                } label: {
                    HStack(spacing: 8) {
                        if workspace.isAcceptingGroupInvite {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Text(workspace.isAcceptingGroupInvite ? L10n.string("Accepting...") : L10n.string("Accept"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
                .controlSize(.large)
                .nativeGlassProminentButtonStyle()
                .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)
                .help(L10n.string("Accept invite"))

                Button(role: .destructive) {
                    Task { await workspace.declineGroupInvite(for: chat) }
                } label: {
                    HStack(spacing: 8) {
                        if workspace.isDecliningGroupInvite {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "xmark.circle")
                        }
                        Text(workspace.isDecliningGroupInvite ? L10n.string("Declining...") : L10n.string("Decline"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                }
                .controlSize(.large)
                .nativeGlassButtonStyle()
                .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)
                .help(L10n.string("Decline invite"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard()
        .accessibilityIdentifier("composer.pendingGroupInvite")
    }

    private var inviteMessage: String {
        String(format: L10n.string("%@ invited you to a secure chat."), inviterName)
    }

    private var inviterName: String {
        if let previewSender = previewSenderName {
            return previewSender
        }
        return L10n.string("Someone")
    }

    private var previewSenderName: String? {
        let preview = chat.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = preview.firstIndex(of: ":") else { return nil }
        let candidate = String(preview[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
            candidate != L10n.string("You"),
            candidate != chat.title
        else { return nil }
        return candidate
    }
}

struct ProfileImageAvatarView: View {
    @Environment(WorkspaceState.self) private var workspace
    let seed: String
    let initials: String
    /// Already passed through `RemoteImageURLPolicy`; body only checks the user preference.
    let sanitizedPictureURL: URL?
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        Group {
            if workspace.loadRemoteImages, let imageURL = sanitizedPictureURL {
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

        HStack(spacing: 10) {
            // Tapping the avatar or title opens the chat info / settings panel,
            // which slides in over the transcript (see ConversationView).
            Button {
                Task { await workspace.showGroupDetails(for: chat) }
            } label: {
                HStack(spacing: 10) {
                    ProfileImageAvatarView(
                        seed: chat.avatarSeed,
                        initials: chat.title,
                        sanitizedPictureURL: chat.sanitizedPictureURL,
                        size: 38,
                        isSelected: false
                    )

                    Text(chat.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Chat info")

            Spacer()

            // Changing the group image is a send (commit) under the hood, which the
            // core rejects until the invite is accepted, or once the local account is
            // no longer a member.
            if !chat.isDirect && chat.canUseComposer {
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
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .frame(height: 76)
        .background {
            MessagesHeaderBackground()
        }
        .sheet(isPresented: $workspace.isGroupImagePickerPresented) {
            GroupImagePickerSheet()
        }
    }
}
