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
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .padding(.horizontal, 4)
            }
            UnsupportedEventCard(event: event, isOutgoing: isOutgoing, timeLabel: timeLabel, onCopyJSON: onCopyJSON)
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .padding(isOutgoing ? .leading : .trailing, 72)
    }
}

struct UnsupportedEventCard: View {
    let event: UnsupportedEvent
    let isOutgoing: Bool
    let timeLabel: String
    let onCopyJSON: (String) -> Void
    /// Collapsed by default. The transcript re-measures the row when this changes its height.
    @State var isExpanded = false

    var body: some View {
        let content = MessagesPalette.bubbleContent(isOutgoing: isOutgoing)
        let detail = AttachmentRowPalette.detailContent(isOutgoing: isOutgoing)
        VStack(alignment: .leading, spacing: 10) {
            UnsupportedEventHeader(kind: event.kind, timeLabel: timeLabel, content: content, detail: detail)

            if event.title != nil || event.summary != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title = event.title {
                        Text(verbatim: title)
                            .wnFont(.semiBold14)
                            .foregroundStyle(content)
                            .lineLimit(2)
                    }
                    if let summary = event.summary {
                        Text(verbatim: summary)
                            .wnFont(.medium12)
                            .foregroundStyle(detail)
                            .lineLimit(isExpanded ? nil : 3)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if isExpanded {
                UnsupportedEventJSONBlock(event: event)
            }

            HStack(spacing: 12) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(
                        isExpanded ? L10n.string("Hide Event Data") : L10n.string("Show Event Data"),
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .wnFont(.semiBold12)
                    .foregroundStyle(content)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if isExpanded {
                    Button {
                        onCopyJSON(event.json)
                    } label: {
                        Label(L10n.string("Copy JSON"), systemImage: "doc.on.doc")
                            .wnFont(.semiBold12)
                            .foregroundStyle(content)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: isExpanded ? 460 : 380, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(MessagesPalette.bubbleFill(isOutgoing: isOutgoing))
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
    let content: Color
    let detail: Color

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "curlybraces.square")
                .wnFont(.semiBold20)
                .foregroundStyle(detail)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("Unsupported event"))
                    .wnFont(.semiBold12)
                    .foregroundStyle(content)
                Text(String(format: L10n.string("Kind %lld"), Int64(clamping: kind)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(detail)
            }
            Spacer(minLength: 8)
            Text(timeLabel)
                .wnFont(.medium10.monospacedDigit())
                .foregroundStyle(detail)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The event as JSON in a code block. Lines keep their shape and scroll sideways, since ids and
/// tags are long; a tall event also scrolls inside a fixed height rather than stretching the row.
private struct UnsupportedEventJSONBlock: View {
    let event: UnsupportedEvent

    var body: some View {
        let shown = event.displayedJSON
        let text = Text(verbatim: shown.isTruncated ? shown.text + "\n…" : shown.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(MarkdownCodeBlockPalette.content)
            .fixedSize()
            .padding(10)
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if Self.isTall(shown.text) {
                    ScrollView([.horizontal, .vertical]) { text }
                        .frame(height: 280)
                } else {
                    ScrollView(.horizontal) { text }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MarkdownCodeBlockPalette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if shown.isTruncated {
                Text(L10n.string("Showing the start of this event. Copy JSON copies all of it."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
    }

    static func isTall(_ text: String) -> Bool {
        text.reduce(into: 0) { count, character in if character == "\n" { count += 1 } } > 22
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
