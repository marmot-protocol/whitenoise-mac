//
//  CustomEmojiViews.swift
//  whitenoise-mac
//
//  Draws NIP-30 custom emoji in place of their `:shortcode:` inside message text, and as the
//  glyph of a reaction. Text stays one wrapping `Text`: an emoji is a `Text(Image)` concatenated
//  between the runs around it, so wrapping, selection and the inline metadata spacer behave as
//  they do for plain text.
//

import AppKit
import SwiftUI

/// The custom emoji a piece of message text may draw. `pending` shortcodes resolved to an
/// attachment whose image has not arrived yet; they hold their space with a blank glyph so the
/// line does not reflow when it lands. A shortcode in neither set stays literal text.
struct CustomEmojiGlyphs: Equatable {
    var images: [String: NSImage] = [:]
    var pending: Set<String> = []

    static let none = CustomEmojiGlyphs()

    var isEmpty: Bool { images.isEmpty && pending.isEmpty }
    var shortcodes: Set<String> { pending.union(images.keys) }

    /// The glyphs for `message`'s resolved custom emoji, as far as `store` has loaded them.
    @MainActor
    static func value(for message: MessageItem, store: CustomEmojiImageStore) -> CustomEmojiGlyphs {
        var glyphs = CustomEmojiGlyphs()
        for (shortcode, attachment) in message.customEmoji {
            if let image = store.image(for: attachment.reference) {
                glyphs.images[shortcode] = image
            } else if !store.isUnavailable(attachment.reference) {
                glyphs.pending.insert(shortcode)
            }
        }
        return glyphs
    }
}

extension EnvironmentValues {
    @Entry var customEmojiGlyphs = CustomEmojiGlyphs.none
}

/// Builds the `Text` for message content with its custom emoji drawn inline.
enum CustomEmojiTextBuilder {
    /// Inline emoji height for the bubble's 16pt body text: a little over the cap height, as a
    /// Unicode emoji draws.
    static let inlineHeight: CGFloat = 20

    static func text(_ string: String, glyphs: CustomEmojiGlyphs) -> Text {
        guard !glyphs.isEmpty else { return Text(verbatim: string) }
        return CustomEmojiText.segments(in: string, shortcodes: glyphs.shortcodes).reduce(Text(verbatim: "")) {
            result, segment in
            switch segment {
            case .text(let run): result + Text(verbatim: run)
            case .emoji(let shortcode): result + glyph(shortcode, image: glyphs.images[shortcode])
            }
        }
    }

    /// Markdown-rendered text keeps its runs' attributes; a `:shortcode:` inside inline code stays
    /// code.
    static func text(_ attributed: AttributedString, glyphs: CustomEmojiGlyphs) -> Text {
        guard !glyphs.isEmpty else { return Text(attributed) }
        let plain = String(attributed.characters)
        let matches = CustomEmojiText.ranges(in: plain, matching: glyphs.shortcodes)
        guard !matches.isEmpty else { return Text(attributed) }

        var result = Text(verbatim: "")
        var cursor = attributed.startIndex
        for match in matches {
            let lower = attributed.index(
                attributed.startIndex,
                offsetByCharacters: plain.distance(from: plain.startIndex, to: match.range.lowerBound))
            let upper = attributed.index(
                attributed.startIndex,
                offsetByCharacters: plain.distance(from: plain.startIndex, to: match.range.upperBound))
            if attributed[lower..<upper].runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true })
            {
                continue
            }
            if cursor < lower {
                result = result + Text(AttributedString(attributed[cursor..<lower]))
            }
            result = result + glyph(match.shortcode, image: glyphs.images[match.shortcode])
            cursor = upper
        }
        if cursor < attributed.endIndex {
            result = result + Text(AttributedString(attributed[cursor..<attributed.endIndex]))
        }
        return result
    }

    /// One emoji as text: its image scaled to `height`, or a blank of that size while it loads.
    /// Read aloud as its `:shortcode:`.
    static func glyph(_ shortcode: String, image: NSImage?, height: CGFloat = inlineHeight) -> Text {
        let label = Text(verbatim: ":\(shortcode):")
        guard let cgImage = (image ?? blankImage).cgImage(forProposedRect: nil, context: nil, hints: nil),
            cgImage.height > 0
        else { return label }
        let aspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        // Wide banners would push the line apart; cap at three emoji widths.
        let scale = CGFloat(cgImage.height) / height * max(1, aspect / 3)
        return Text(Image(cgImage, scale: scale, label: label))
            .baselineOffset(-height * 0.2)
    }

    private static let blankImage: NSImage = {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }()
}

/// A reaction's emoji: its custom image when one is loaded, else the emoji text itself (which for
/// a custom emoji without an image is the literal `:shortcode:`).
struct ReactionEmojiGlyph: View {
    let emoji: String
    let image: NSImage?
    var size: CGFloat = 16

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel(Text(verbatim: emoji))
        } else {
            Text(verbatim: emoji)
        }
    }
}

#Preview("Reaction glyphs") {
    HStack(spacing: 12) {
        ReactionEmojiGlyph(emoji: "👍", image: nil)
        ReactionEmojiGlyph(emoji: ":party:", image: nil)
        ReactionEmojiGlyph(
            emoji: ":star:",
            image: NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        )
    }
    .padding()
}

#Preview("Inline custom emoji") {
    CustomEmojiTextBuilder.text(
        "Ship it :rocket: and celebrate :party: — :unknown: stays text",
        glyphs: CustomEmojiGlyphs(
            images: ["rocket": NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)!],
            pending: ["party"]
        )
    )
    .wnFont(.medium16)
    .padding()
    .frame(width: 320)
}

/// A message that is only one custom emoji, drawn large without a bubble like a lone Unicode
/// emoji. Holds its size while the image loads.
struct CustomEmojiSticker: View {
    let shortcode: String
    let image: NSImage?

    static let height: CGFloat = 64

    /// The image's own aspect at `height`, capped at three emoji widths like the inline glyph.
    static func width(for image: NSImage?) -> CGFloat {
        guard let size = image?.size, size.height > 0 else { return height }
        return min(height * size.width / size.height, height * 3)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: Self.width(for: image), height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: ":\(shortcode):"))
    }
}

#Preview("Custom emoji sticker") {
    HStack(spacing: 24) {
        CustomEmojiSticker(
            shortcode: "star",
            image: NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        )
        CustomEmojiSticker(shortcode: "party", image: nil)
    }
    .padding()
}
