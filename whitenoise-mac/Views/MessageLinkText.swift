//
//  MessageLinkText.swift
//  whitenoise-mac
//
//  A message `Text` whose links show the pointing-hand cursor. SwiftUI makes link runs
//  clickable but never changes the cursor over them, and it offers no hit test for a run, so
//  the link geometry is read out of the text layout as it draws.
//

import AppKit
import SwiftUI
import Synchronization

/// Tags the runs of a message `Text` that carry a link. A `TextRenderer` sees only custom
/// `TextAttribute`s on a run, never the `AttributedString`'s own `.link`, so the link runs are
/// split out and marked with this before the text is laid out.
nonisolated struct MessageLinkRunAttribute: TextAttribute {}

/// Where the link runs of a bubble's texts were last laid out, in each text's own coordinates,
/// keyed by each text's `layoutID`.
///
/// A reference shared from above the bubble's selection gate rather than state on the text:
/// the hovered bubble is the selectable one, and a selectable `Text` is drawn by an AppKit
/// selection field that bypasses `TextRenderer` entirely. The rects recorded while the bubble
/// was drawn unselectable — the same text at the same width — are what the hover tests against,
/// and the gate's branch flip would discard any `@State` below it.
///
/// Keyed by where a text sits in the message rather than by what it says: the same linked words
/// as a heading and as a list item lay out differently, and a text-keyed entry would hand one
/// the other's rects. A key per text view also bounds the store to the bubble's text views, an
/// edit overwriting its own entry instead of adding one.
///
/// Written from the renderer, which SwiftUI may run off the main thread, hence the lock.
nonisolated final class MessageLinkRegions: Sendable {
    private let regions = Mutex<[String: [CGRect]]>([:])

    func record(_ rects: [CGRect], layoutID: String) {
        regions.withLock { $0[layoutID] = rects }
    }

    func linkRects(layoutID: String) -> [CGRect] {
        regions.withLock { $0[layoutID] ?? [] }
    }

    func containsLink(at point: CGPoint, layoutID: String) -> Bool {
        linkRects(layoutID: layoutID).contains { $0.contains(point) }
    }
}

extension EnvironmentValues {
    /// Set by `MessageBubble` outside its selection gate; see `MessageLinkRegions`.
    @Entry var messageLinkRegions: MessageLinkRegions? = nil
}

/// Records each line's link runs as it draws them, unchanged.
nonisolated struct MessageLinkRegionRecorder: TextRenderer {
    let layoutID: String
    let regions: MessageLinkRegions

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var rects: [CGRect] = []
        for line in layout {
            for run in line where run[MessageLinkRunAttribute.self] != nil {
                rects.append(run.typographicBounds.rect)
            }
            context.draw(line)
        }
        regions.record(rects, layoutID: layoutID)
    }
}

extension AttributedString {
    nonisolated var containsLink: Bool {
        runs[\.link].contains { link, _ in link != nil }
    }
}

extension Text {
    /// `CustomEmojiTextBuilder.text(text, glyphs:)`, with every link run tagged
    /// `MessageLinkRunAttribute`. The runs keep their own attributes, `.link` included, so they
    /// stay clickable, and the emoji inside each run still draw as images.
    static func markingLinks(_ text: AttributedString, glyphs: CustomEmojiGlyphs = .none) -> Text {
        var result: Text?
        for (link, range) in text.runs[\.link] {
            var segment = CustomEmojiTextBuilder.text(AttributedString(text[range]), glyphs: glyphs)
            if link != nil {
                segment = segment.customAttribute(MessageLinkRunAttribute())
            }
            result = result.map { $0 + segment } ?? segment
        }
        return result ?? CustomEmojiTextBuilder.text(text, glyphs: glyphs)
    }
}

/// A message's inline text, optionally followed by `trailing` (the bubble's metadata spacer),
/// that shows the pointing hand over its links. Text without a link is a plain `Text`, so the
/// common bubble pays for neither the renderer nor the hover tracking.
///
/// `layoutID` names this text's place in the message (see `MessageLinkRegions`); it must be
/// unique among the texts of one bubble and stable across renders.
struct MessageLinkText: View {
    let text: AttributedString
    let layoutID: String
    var trailing: Text? = nil
    var glyphs: CustomEmojiGlyphs = .none

    @Environment(\.messageLinkRegions) private var sharedRegions
    @State private var localRegions = MessageLinkRegions()
    @State private var cursor = MessageLinkCursor()

    var body: some View {
        if text.containsLink {
            let regions = sharedRegions ?? localRegions
            appendingTrailing(to: .markingLinks(text, glyphs: glyphs))
                .textRenderer(MessageLinkRegionRecorder(layoutID: layoutID, regions: regions))
                .onContinuousHover(coordinateSpace: .local) { phase in
                    cursor.sync(isOverLink: Self.isOverLink(phase, in: regions, layoutID: layoutID))
                }
                .onDisappear { cursor.sync(isOverLink: false) }
        } else {
            appendingTrailing(to: CustomEmojiTextBuilder.text(text, glyphs: glyphs))
        }
    }

    private func appendingTrailing(to body: Text) -> Text {
        guard let trailing else { return body }
        return body + trailing
    }

    /// Whether a hover update leaves the pointer on one of the text's recorded links.
    static func isOverLink(_ phase: HoverPhase, in regions: MessageLinkRegions, layoutID: String) -> Bool {
        switch phase {
        case .active(let location): regions.containsLink(at: location, layoutID: layoutID)
        case .ended: false
        }
    }

    /// A sentence with one link in the middle, for the preview.
    static let sample: AttributedString = {
        var text = AttributedString("Read the spec at ")
        var link = AttributedString("marmot.build")
        link.link = URL(string: "https://marmot.build")
        link.underlineStyle = .single
        text.append(link)
        text.append(AttributedString(" before Friday."))
        return text
    }()
}

/// The pointing hand for one `MessageLinkText`, pushed on entering a link and popped on leaving
/// it. Remembers whether it pushed, so a hover update that stays on (or off) a link changes
/// nothing, and leaving a link — or the text disappearing while the pointer is on one — pops
/// exactly what was pushed and never the cursor of whatever lies underneath.
struct MessageLinkCursor {
    private(set) var hasPushed = false

    mutating func sync(
        isOverLink: Bool,
        push: () -> Void = { NSCursor.pointingHand.push() },
        pop: () -> Void = { NSCursor.pop() }
    ) {
        if isOverLink, !hasPushed {
            push()
            hasPushed = true
        } else if !isOverLink, hasPushed {
            pop()
            hasPushed = false
        }
    }
}

#Preview {
    MessageLinkText(text: MessageLinkText.sample, layoutID: "preview")
        .wnFont(.medium16)
        .padding()
}
