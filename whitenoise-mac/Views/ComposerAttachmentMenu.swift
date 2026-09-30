//
//  ComposerAttachmentMenu.swift
//  whitenoise-mac
//
//  The composer's `+` button: every way to put something other than text into a message.
//

import SwiftUI

/// The destinations the composer's `+` button offers.
///
/// This is `whitenoise-ios`'s `ComposerAttachmentOption` minus the entries a Mac has nothing
/// behind: there is no camera or camera roll here (the open panel already takes photos and
/// videos), and no location or contact sends. Declaration order is the presented order, and
/// `available(gifsAvailable:pollsAvailable:)` is the whole decision the menu makes, so it stays
/// assertable without a view.
nonisolated enum ComposerAttachmentOption: String, CaseIterable, Hashable, Sendable {
    case files
    case gifs
    case poll

    /// `pollsAvailable` is false in direct messages: MDK accepts polls only in groups.
    static func available(gifsAvailable: Bool, pollsAvailable: Bool = false) -> [Self] {
        allCases.filter { option in
            switch option {
            case .files: true
            case .gifs: gifsAvailable
            case .poll: pollsAvailable
            }
        }
    }

    var titleKey: String {
        switch self {
        case .files: "Files"
        case .gifs: "GIFs"
        case .poll: "Poll"
        }
    }

    var systemImage: String {
        switch self {
        case .files: "folder"
        case .gifs: "rectangle.stack.badge.play"
        case .poll: "chart.bar.xaxis"
        }
    }
}

/// The composer's `+` button and the popover it opens.
///
/// A `Button` and a popover rather than a `Menu`, for the reason `ProfileImageSourceMenu` gives: a
/// macOS `Menu` coerces its label into a menu title and drops the circular chrome the composer's
/// other controls wear. Choosing **GIFs** turns the same popover into the GIPHY picker instead of
/// closing it and opening a second one, so there is no dismiss-then-present race; a fresh picker
/// model per opening means a closed picker keeps no stale query or results.
///
/// `giphyAPIKey` is nil when this build carries no GIPHY key, or when the conversation cannot send
/// right now; either way the GIFs entry is left out, the way the iOS menu leaves it out.
/// `onCreatePoll` is nil where a poll cannot be sent, which leaves the Poll entry out the same way.
struct ComposerAttachmentMenu: View {
    let giphyAPIKey: String?
    let isDisabled: Bool
    let onAttachFiles: () -> Void
    let sendGIF: GiphySearchViewModel.Send
    var onCreatePoll: (() -> Void)? = nil

    @State private var page: ComposerAttachmentMenuPage?

    var body: some View {
        Button {
            page = .options
        } label: {
            Image(systemName: "plus")
                .wnFont(.medium18)
                .frame(width: 30, height: 30)
                .background {
                    MessagesCircleControlBackground()
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(L10n.string("Add attachment"))
        .accessibilityLabel(L10n.string("Add attachment"))
        .accessibilityIdentifier("composer.attachments")
        .popover(
            isPresented: Binding(
                get: { page != nil },
                set: { if !$0 { page = nil } }
            ),
            arrowEdge: .bottom
        ) {
            switch page {
            case .options:
                ComposerAttachmentOptionList(
                    options: ComposerAttachmentOption.available(
                        gifsAvailable: giphyAPIKey != nil,
                        pollsAvailable: onCreatePoll != nil
                    ),
                    onSelect: select
                )
            case .gifs(let searchModel):
                GiphySearchView(model: searchModel) { page = nil }
            case nil:
                EmptyView()
            }
        }
    }

    private func select(_ option: ComposerAttachmentOption) {
        switch option {
        case .files:
            page = nil
            onAttachFiles()
        case .poll:
            page = nil
            onCreatePoll?()
        case .gifs:
            guard let giphyAPIKey else {
                page = nil
                return
            }
            let client = GiphySearchClient(apiKey: giphyAPIKey)
            let sendGIF = sendGIF
            page = .gifs(
                GiphySearchViewModel(
                    search: { try await client.search($0) },
                    send: { media in try await sendGIF(media) }
                )
            )
        }
    }
}

/// What the `+` popover is showing.
private enum ComposerAttachmentMenuPage {
    case options
    case gifs(GiphySearchViewModel)
}

/// The `+` popover's option rows, drawn to read as menu items.
struct ComposerAttachmentOptionList: View {
    let options: [ComposerAttachmentOption]
    let onSelect: (ComposerAttachmentOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(options, id: \.self) { option in
                ComposerAttachmentOptionRow(option: option) { onSelect(option) }
            }
        }
        .padding(6)
        .frame(width: 180)
    }
}

/// One row: a symbol in a fixed gutter so the titles line up, and a highlight that follows the
/// pointer.
private struct ComposerAttachmentOptionRow: View {
    let option: ComposerAttachmentOption
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: option.systemImage)
                    .wnFont(.medium12)
                    .frame(width: 16)

                Text(L10n.string(option.titleKey))
                    .wnFont(.medium12)

                Spacer(minLength: 0)
            }
            .foregroundStyle(WNColor.backgroundContentPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovering ? WNColor.fillSecondaryHover : .clear,
                in: .rect(cornerRadius: 6)
            )
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.attachments.\(option.rawValue)")
        .onHover { isHovering = $0 }
    }
}

#Preview("Composer + button") {
    ComposerAttachmentMenu(giphyAPIKey: "preview", isDisabled: false, onAttachFiles: {}, sendGIF: { _ in })
        .padding()
}

#Preview("Attachment options") {
    ComposerAttachmentOptionList(options: ComposerAttachmentOption.allCases, onSelect: { _ in })
}
