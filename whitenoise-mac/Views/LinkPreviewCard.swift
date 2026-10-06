//
//  LinkPreviewCard.swift
//  whitenoise-mac
//
//  The title-and-image card above a message's text for the first link in it, shown only while
//  "Show Link Previews" is on. Ported from whitenoise-ios's `LinkPreviewCard`.
//

import SwiftUI

/// Loads the preview for `url` once its row is on screen, and draws nothing until there is one —
/// a page with no title or image, or one that fails to load, leaves the message as plain text.
struct LinkPreviewCard: View {
    /// The widest the card is ever drawn: a 540pt bubble less its 12pt side padding. The card
    /// fills whatever width the bubble has, so the image is decoded for the widest case.
    static let maximumWidth: CGFloat = 516

    let url: URL
    let loader: LinkPreviewLoader

    @Environment(\.openURL) private var openURL
    @Environment(\.displayScale) private var displayScale
    @State private var metadata: LinkPreviewMetadata?
    @State private var image: NSImage?
    @State private var imageFailed = false
    @State private var isVisible = false

    init(url: URL, loader: LinkPreviewLoader) {
        self.url = url
        self.loader = loader
        _metadata = State(initialValue: loader.cachedMetadata(for: url) ?? nil)
    }

    var body: some View {
        Group {
            if let metadata {
                // Through the environment's `openURL`, so the preview opens exactly the way the
                // link in the text does — after the app-side external-link gate.
                Button {
                    openURL(url)
                } label: {
                    LinkPreviewCardContent(
                        title: metadata.title,
                        host: LinkPreviewCardContent.host(for: url),
                        image: image,
                        showsImageSlot: metadata.imageURL != nil && !imageFailed
                    )
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(url.absoluteString)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onTranscriptVisibilityChange { isVisible = $0 }
        .task(id: LinkPreviewTaskID(url: url, isVisible: isVisible)) {
            guard isVisible else { return }
            await load()
        }
    }

    private func load() async {
        if metadata == nil {
            guard let loaded = await loader.metadata(for: url), !Task.isCancelled else { return }
            metadata = loaded
        }
        guard image == nil, !imageFailed, let imageURL = metadata?.imageURL else { return }
        let maxPixelSize = (Self.maximumWidth * displayScale).rounded(.up)
        if let loaded = await RemoteImageLoader.shared.image(for: imageURL, maxPixelSize: maxPixelSize) {
            image = loaded.nsImage
        } else if !Task.isCancelled {
            imageFailed = true
        }
    }
}

private struct LinkPreviewTaskID: Equatable {
    let url: URL
    let isVisible: Bool
}

/// The card itself, with everything it shows passed in.
struct LinkPreviewCardContent: View {
    static let imageAspectRatio: CGFloat = 1.91

    let title: String?
    let host: String?
    let image: NSImage?
    /// Reserved as soon as the page names an image, so the card does not grow when it arrives.
    let showsImageSlot: Bool

    static func host(for url: URL) -> String? {
        guard let host = url.host(percentEncoded: false) else { return nil }
        let display = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return PeerDisplayText.sanitize(display).map { String($0.prefix(64)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsImageSlot {
                WNColor.fillSecondary
                    .aspectRatio(Self.imageAspectRatio, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .clipped()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(verbatim: title)
                        .wnFont(.semiBold12)
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if let host {
                    Text(verbatim: host)
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        // The same card the reply quote sits on — `backgroundPrimary` with a hairline, identically
        // in both directions — so its text can take `background*` tokens whatever the bubble fill.
        .background(WNColor.backgroundPrimary)
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(WNColor.borderTertiary, lineWidth: 1)
        }
        .contentShape(.rect(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
    }
}

#Preview("Link preview card") {
    VStack(spacing: 16) {
        LinkPreviewCardContent(
            title: "An example article title that runs long enough to wrap onto a second line",
            host: "example.com",
            image: nil,
            showsImageSlot: true
        )
        LinkPreviewCardContent(
            title: "A page without an image",
            host: "news.example.com",
            image: nil,
            showsImageSlot: false
        )
    }
    .frame(width: LinkPreviewCard.maximumWidth)
    .padding()
}
