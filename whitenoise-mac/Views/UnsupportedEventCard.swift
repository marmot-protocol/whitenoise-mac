import AppKit
import SwiftUI

/// A row for an event of a kind White Noise can't draw, so the reader at least knows something
/// arrived. Sits on its author's side like a poll; the card expands in place to show the event.
struct UnsupportedEventRow: View {
    let event: UnsupportedEvent
    let isOutgoing: Bool
    /// Nil for an outgoing row, which never names its sender.
    let senderName: String?
    let timeLabel: String
    let onCopyJSON: (String) -> Void

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
            if let senderName, !isOutgoing {
                Text(senderName)
                    .font(MessageTypography.senderName)
                    .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                    .padding(.horizontal, 4)
            }
            UnsupportedEventCard(event: event, isOutgoing: isOutgoing, timeLabel: timeLabel, onCopyJSON: onCopyJSON)
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .padding(isOutgoing ? .leading : .trailing, 72)
    }
}

struct UnsupportedEventCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let event: UnsupportedEvent
    let isOutgoing: Bool
    let timeLabel: String
    let onCopyJSON: (String) -> Void
    /// Collapsed by default. The transcript re-measures the row when this changes its height.
    @State var isExpanded = false

    private var polarity: MessageBubblePolarity { MessageBubblePolarity(isOutgoing: isOutgoing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UnsupportedEventHeader(kind: event.kind, timeLabel: timeLabel, polarity: polarity)

            if event.title != nil || event.summary != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title = event.title {
                        Text(verbatim: title)
                            .font(MessageTypography.bodySemibold)
                            .foregroundStyle(polarity.content)
                            .lineLimit(2)
                    }
                    if let summary = event.summary {
                        Text(verbatim: summary)
                            .font(.subheadline)
                            .foregroundStyle(polarity.secondaryContent)
                            .lineLimit(isExpanded ? nil : 3)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if isExpanded {
                UnsupportedEventJSONView(json: event.json)
                    .background(
                        MarkdownCodeBlockPalette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Label(
                        isExpanded ? L10n.string("Hide Event Data") : L10n.string("Show Event Data"),
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(polarity.content)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if isExpanded {
                    Button {
                        onCopyJSON(event.json)
                    } label: {
                        Label(L10n.string("Copy JSON"), systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(polarity.content)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 380, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MessageBubbleShape.cornerRadius, style: .continuous)
                .fill(polarity.fill)
        }
        .contextMenu {
            Button {
                onCopyJSON(event.json)
            } label: {
                Label(L10n.string("Copy JSON"), systemImage: "doc.on.doc")
            }
        }
    }
}

private struct UnsupportedEventHeader: View {
    let kind: UInt64
    let timeLabel: String
    let polarity: MessageBubblePolarity

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "curlybraces.square")
                .font(.title3)
                .foregroundStyle(polarity.secondaryContent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("Unsupported event"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(polarity.content)
                Text(String(format: L10n.string("Kind %lld"), Int64(clamping: kind)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(polarity.secondaryContent)
            }
            Spacer(minLength: 8)
            Text(timeLabel)
                .font(MessageTypography.footer.monospacedDigit())
                .foregroundStyle(polarity.secondaryContent)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The event as JSON in a code block: the whole event, unaltered, wrapped to the card's width.
/// An event can be as large as a relay accepts (megabytes), which a SwiftUI `Text` lays out all at
/// once, so this is a read-only text view: TextKit lays out only what scrolls into view, and the
/// reader can scroll to the end. It grows with its text up to `maxHeight`, then scrolls. Not
/// selectable: the text view's own ⌘C would skip the concealed pasteboard type that Copy JSON (and
/// every message copy) uses to keep decrypted content out of clipboard history.
struct UnsupportedEventJSONView: NSViewRepresentable {
    let json: String

    static let maxHeight: CGFloat = 280
    /// Past this many UTF-8 bytes the block takes `maxHeight` without measuring the text, which
    /// would lay all of it out. Far more than fills `maxHeight` at any card width. Bytes, not
    /// characters: combining marks stack without adding characters, so a character count can't
    /// bound the work.
    static let measuredLimit = 4_000
    private static let inset = NSSize(width: 8, height: 8)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        // Window-derived insets would push the text under the block's top edge; the measurement
        // below counts only the text container's own inset.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = false
            textView.drawsBackground = false
            textView.isRichText = false
            textView.textContainerInset = Self.inset
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textColor = MarkdownCodeBlockPalette.nsContent
            textView.layoutManager?.allowsNonContiguousLayout = true
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != json else { return }
        textView.string = json
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        guard json.utf8.count <= Self.measuredLimit,
            let textView = scrollView.documentView as? NSTextView,
            let layoutManager = textView.layoutManager, let container = textView.textContainer
        else { return CGSize(width: width, height: Self.maxHeight) }
        if textView.string != json { textView.string = json }
        container.size = NSSize(width: width - Self.inset.width * 2, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let textHeight = layoutManager.usedRect(for: container).height + Self.inset.height * 2
        return CGSize(width: width, height: min(ceil(textHeight), Self.maxHeight))
    }
}

#Preview("Unsupported event") {
    VStack(spacing: 16) {
        UnsupportedEventRow(
            event: UnsupportedEvent(
                id: String(repeating: "a", count: 64), pubkey: String(repeating: "b", count: 64),
                createdAt: 1_763_635_860, kind: 4242,
                tags: [
                    ["subject", "Signal box log"], ["alt", "The evening crew logged a delay at the north entrance."],
                    ["imeta", "url https://video.invalid/station.mp4", "m video/mp4", "dim 1280x720"],
                ],
                content: #"{"status":"Delayed","platform":2}"#),
            isOutgoing: false, senderName: "Vivid Tiger", timeLabel: "11:51", onCopyJSON: { _ in })
        UnsupportedEventCard(
            event: UnsupportedEvent(
                id: String(repeating: "c", count: 64), pubkey: String(repeating: "d", count: 64),
                createdAt: 1_763_635_900, kind: 31_337, tags: [["d", "track-1"]], content: "{}"),
            isOutgoing: true, timeLabel: "11:52", onCopyJSON: { _ in }, isExpanded: true)
    }
    .padding(24)
    .frame(width: 560)
}
