//
//  NostrEventPreviewCard.swift
//  whitenoise-mac
//
//  The card under a message for the first public Nostr event it links: a text note drawn in
//  place, an article as a title card, anything else as a pointer. The app has no view of its own
//  for a public event, so a click opens it on njump.me. Shown only while "Show Link Previews" is
//  on, because loading one asks relays the sender chose.
//

import SwiftUI

/// Loads `reference` once its row is on screen, and draws nothing until there is an event —
/// one that is missing, deleted, or fails to load leaves the message as plain text.
struct NostrEventPreviewCard: View {
    let reference: String
    let store: NostrEventPreviewStore

    @Environment(\.openURL) private var openURL
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var imageFailed = false
    @State private var isVisible = false

    var body: some View {
        Group {
            if case .loaded(let preview) = store.entry(for: reference),
                let viewerURL = MarkdownLinkPolicy.eventViewerURL(for: reference)
            {
                // Through the environment's `openURL`, so the card opens exactly the way a web
                // link in the text does — after the app-side external-link gate.
                Button {
                    openURL(viewerURL)
                } label: {
                    NostrEventPreviewCardContent(
                        preview: preview,
                        author: store.author(preview.authorIdHex),
                        image: image,
                        showsImageSlot: !imageFailed
                    )
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(viewerURL.absoluteString)
                .task(id: articleImageURL(of: preview)) {
                    await loadImage(articleImageURL(of: preview))
                }
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onTranscriptVisibilityChange { isVisible = $0 }
        .task(id: NostrEventPreviewTaskID(reference: reference, isVisible: isVisible)) {
            guard isVisible else { return }
            store.load(reference)
        }
    }

    private func articleImageURL(of preview: NostrEventPreview) -> URL? {
        guard case .article(_, _, let imageURL) = preview.body else { return nil }
        return imageURL
    }

    private func loadImage(_ url: URL?) async {
        guard let url, image == nil, !imageFailed else { return }
        let maxPixelSize = (LinkPreviewCard.maximumWidth * displayScale).rounded(.up)
        if let loaded = await RemoteImageLoader.shared.image(for: url, maxPixelSize: maxPixelSize) {
            image = loaded.nsImage
        } else if !Task.isCancelled {
            imageFailed = true
        }
    }
}

private struct NostrEventPreviewTaskID: Equatable {
    let reference: String
    let isVisible: Bool
}

/// The card itself, with everything it shows passed in. The same frame as a web link preview.
struct NostrEventPreviewCardContent: View {
    static let viewerHost = "njump.me"
    static let avatarSize: CGFloat = 18

    let preview: NostrEventPreview
    let author: NostrEventPreviewStore.Author?
    let image: NSImage?
    /// Reserved as soon as an article names an image, so the card does not grow when it arrives.
    let showsImageSlot: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .article(_, _, let imageURL) = preview.body, imageURL != nil, showsImageSlot {
                WNColor.fillSecondary
                    .aspectRatio(LinkPreviewCardContent.imageAspectRatio, contentMode: .fit)
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
            VStack(alignment: .leading, spacing: 4) {
                switch preview.body {
                case .note(let text):
                    NostrEventAuthorLine(preview: preview, author: author)
                    if !text.isEmpty {
                        Text(verbatim: text)
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.backgroundContentPrimary)
                            .lineLimit(8)
                            .multilineTextAlignment(.leading)
                    }
                case .article(let title, let summary, _):
                    if let title {
                        Text(verbatim: title)
                            .wnFont(.semiBold12)
                            .foregroundStyle(WNColor.backgroundContentPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let summary {
                        Text(verbatim: summary)
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    NostrEventAuthorLine(preview: preview, author: author)
                case .other:
                    Text(L10n.string("Nostr event"))
                        .wnFont(.semiBold12)
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                    NostrEventAuthorLine(preview: preview, author: author)
                }
                Label {
                    Text(verbatim: Self.viewerHost)
                } icon: {
                    Image(systemName: "arrow.up.right")
                }
                .labelStyle(.titleAndIcon)
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        // The web link preview's card: `backgroundPrimary` with a hairline, identically in both
        // directions, so its text can take `background*` tokens whatever the bubble fill.
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

/// Avatar, name and date of the event's author. Until the profile is read the name is blank and
/// the avatar shows the key's colors, so the line does not jump when it arrives.
private struct NostrEventAuthorLine: View {
    let preview: NostrEventPreview
    let author: NostrEventPreviewStore.Author?

    var body: some View {
        HStack(spacing: 6) {
            ProfileImageAvatarView(
                seed: preview.authorIdHex,
                initials: author?.name ?? "",
                sanitizedPictureURL: author?.pictureURL,
                size: NostrEventPreviewCardContent.avatarSize,
                isSelected: false
            )
            .accessibilityHidden(true)
            if let name = author?.name {
                Text(verbatim: name)
                    .wnFont(.semiBold12)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                    .lineLimit(1)
            }
            Text(preview.createdAt, format: .dateTime.year().month(.abbreviated).day())
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)
        }
    }
}

#Preview("Nostr event preview cards") {
    let author = NostrEventPreviewStore.Author(name: "Alice", pictureURL: nil)
    let authorIdHex = String(repeating: "ab", count: 32)
    let date = Date(timeIntervalSince1970: 1_760_000_000)
    ScrollView {
        VStack(spacing: 16) {
            NostrEventPreviewCardContent(
                preview: NostrEventPreview(
                    authorIdHex: authorIdHex,
                    createdAt: date,
                    body: .note(
                        text: "Just shipped encrypted group chats over Nostr. Feedback welcome!\n\nnpub1abcde...wxyz"
                    )
                ),
                author: author,
                image: nil,
                showsImageSlot: true
            )
            NostrEventPreviewCardContent(
                preview: NostrEventPreview(
                    authorIdHex: authorIdHex,
                    createdAt: date,
                    body: .article(
                        title: "How Marmot brings MLS to Nostr",
                        summary:
                            "A walk through key packages, welcomes and commits, and what they mean for your groups.",
                        imageURL: URL(string: "https://example.com/cover.png")
                    )
                ),
                author: author,
                image: nil,
                showsImageSlot: true
            )
            NostrEventPreviewCardContent(
                preview: NostrEventPreview(authorIdHex: authorIdHex, createdAt: date, body: .other(kind: 30000)),
                author: nil,
                image: nil,
                showsImageSlot: true
            )
        }
        .frame(width: LinkPreviewCard.maximumWidth)
        .padding()
    }
}
