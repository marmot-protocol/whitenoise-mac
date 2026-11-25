//
//  ComposerAttachmentMenu.swift
//  whitenoise-mac
//
//  The composer's `+` button: every way to put something other than text into a message.
//

import MarmotKit
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
    case stickers
    case poll

    /// `pollsAvailable` is false only where the menu has no poll composer behind it; MDK 0.13
    /// accepts polls in direct conversations as well as groups. `stickersAvailable` is false where
    /// the conversation cannot send or has no account's sticker library behind it.
    static func available(gifsAvailable: Bool, stickersAvailable: Bool = false, pollsAvailable: Bool = false)
        -> [Self]
    {
        allCases.filter { option in
            switch option {
            case .files: true
            case .gifs: gifsAvailable
            case .stickers: stickersAvailable
            case .poll: pollsAvailable
            }
        }
    }

    /// Whether `chat`'s composer offers a new poll: whenever it can send, and not mid-edit — the iOS
    /// rule, `editSession == nil && canCreatePolls`. Direct and group conversations alike; MDK 0.13
    /// accepts polls in both. It takes the whole chat so a test can prove a DM is not excluded.
    static func pollsAvailable(in chat: ChatItem, isPeerBlocked: Bool, isEditing: Bool) -> Bool {
        chat.canUseComposer && !isPeerBlocked && !isEditing
    }

    var titleKey: String {
        switch self {
        case .files: "Files"
        case .gifs: "GIFs"
        case .stickers: "Stickers"
        case .poll: "Poll"
        }
    }

    var systemImage: String {
        switch self {
        case .files: "folder"
        case .gifs: "rectangle.stack.badge.play"
        case .stickers: "face.dashed"
        case .poll: "chart.bar.xaxis"
        }
    }
}

/// The composer's `+` menu and the popovers its picker entries open (T08, C03, P02).
///
/// A native macOS `Menu` provides standard keyboard navigation, VoiceOver menu semantics, and
/// pointer feedback. Choosing **GIFs** or **Stickers** dismisses the menu and opens the picker in
/// a popover anchored to the same control; a fresh picker model per opening means a closed picker
/// keeps no stale query or results.
///
/// `giphyAPIKey` is nil when this build carries no GIPHY key, or when the conversation cannot send
/// right now; either way the GIFs entry is left out, the way the iOS menu leaves it out.
/// `onCreatePoll` is nil where a poll cannot be sent, which leaves the Poll entry out the same way.
/// `stickers` is nil where a sticker cannot be sent; choosing **Stickers** opens the sticker
/// picker popover, as GIFs does.
struct ComposerAttachmentMenu: View {
    let giphyAPIKey: String?
    let isDisabled: Bool
    let onAttachFiles: () -> Void
    let sendGIF: GiphySearchViewModel.Send
    var stickers: StickerLibrary? = nil
    var sendSticker: (StickerFfi) async throws -> Void = { _ in }
    var onCreatePoll: (() -> Void)? = nil

    @State private var popoverPage: ComposerAttachmentPopoverPage?

    private var availableOptions: [ComposerAttachmentOption] {
        ComposerAttachmentOption.available(
            gifsAvailable: giphyAPIKey != nil,
            stickersAvailable: stickers != nil,
            pollsAvailable: onCreatePoll != nil
        )
    }

    var body: some View {
        Menu {
            ForEach(availableOptions, id: \.self) { option in
                Button {
                    select(option)
                } label: {
                    Label(L10n.string(option.titleKey), systemImage: option.systemImage)
                }
                .accessibilityIdentifier("composer.attachments.\(option.rawValue)")
            }
        } label: {
            Label(L10n.string("Add attachment"), systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(width: 20, height: 20)
        }
        .menuLabelIcons()
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .wnButtonShape(.circle)
        .wnSecondaryButtonStyle()
        .controlSize(.regular)
        .disabled(isDisabled)
        .help(L10n.string("Add attachment"))
        .accessibilityLabel(L10n.string("Add attachment"))
        .accessibilityIdentifier("composer.attachments")
        .popover(
            isPresented: Binding(
                get: { popoverPage != nil },
                set: { if !$0 { popoverPage = nil } }
            ),
            arrowEdge: .bottom
        ) {
            switch popoverPage {
            case .gifs(let searchModel):
                GiphySearchView(model: searchModel) { popoverPage = nil }
            case .stickers(let library):
                StickerPickerPopover(library: library, send: sendSticker) { popoverPage = nil }
            case nil:
                EmptyView()
            }
        }
    }

    private func select(_ option: ComposerAttachmentOption) {
        switch option {
        case .files:
            popoverPage = nil
            onAttachFiles()
        case .poll:
            popoverPage = nil
            onCreatePoll?()
        case .stickers:
            popoverPage = stickers.map(ComposerAttachmentPopoverPage.stickers)
        case .gifs:
            guard let giphyAPIKey else {
                popoverPage = nil
                return
            }
            let client = GiphySearchClient(apiKey: giphyAPIKey)
            let sendGIF = sendGIF
            popoverPage = .gifs(
                GiphySearchViewModel(
                    search: { try await client.search($0) },
                    send: { media in try await sendGIF(media) }
                )
            )
        }
    }
}

/// Which picker popover the `+` menu opened.
private enum ComposerAttachmentPopoverPage {
    case gifs(GiphySearchViewModel)
    case stickers(StickerLibrary)
}

#Preview("Composer + menu") {
    HStack(spacing: 12) {
        ComposerAttachmentMenu(
            giphyAPIKey: "preview",
            isDisabled: false,
            onAttachFiles: {},
            sendGIF: { _ in },
            stickers: .preview(),
            onCreatePoll: {}
        )
        ComposerAttachmentMenu(
            giphyAPIKey: nil,
            isDisabled: true,
            onAttachFiles: {},
            sendGIF: { _ in }
        )
    }
    .padding()
}
