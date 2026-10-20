//
//  MessageReactionViews.swift
//  whitenoise-mac
//
//  Compact reaction chips shown under a bubble, and the reaction viewer popover that lists who
//  reacted (grouped by emoji), matching the sibling clients' reaction detail panel.
//

import MarmotKit
import SwiftUI

/// A tight row of reaction chips — **one pill per emoji**, each carrying that emoji's own count.
/// Tapping a pill opens the viewer filtered to that emoji; the trailing overflow pill opens it on
/// "All". Chips are view-only — adding/removing is done from the hover React control.
///
struct MessageReactionChips: View {
    let reactions: [MessageReaction]
    /// Emoji kinds the conversation window left out, counted into the overflow pill.
    var omittedKinds: Int = 0
    /// Loaded images for custom-emoji reactions, keyed by the reaction's emoji text.
    var emojiImages: [String: NSImage] = [:]
    /// emoji to focus the viewer on, or nil for the "All" tab.
    let onOpenViewer: (String?) -> Void

    var body: some View {
        let row = MessageReactionChipRow.value(reactions: reactions, omittedKinds: omittedKinds)
        HStack(spacing: Self.pillSpacing) {
            ForEach(row.visible) { reaction in
                MessageReactionChipPill(isSelected: reaction.isOwn) {
                    onOpenViewer(reaction.emoji)
                } label: {
                    ReactionEmojiGlyph(emoji: reaction.emoji, image: emojiImages[reaction.emoji])
                    if reaction.count > 1 {
                        Text(verbatim: MessageReactionChipRow.countLabel(for: reaction.count))
                            .wnFont(.semiBold10.monospacedDigit())
                            // Paired with the pill's own fill: the resting pill is a `background*`
                            // surface, the selected one a `fill*`. The two tokens resolve alike
                            // today, which is exactly why naming the right one matters — see the
                            // pairing rule in `WNNSColor`.
                            .foregroundStyle(
                                reaction.isOwn
                                    ? WNColor.fillContentSecondary
                                    : WNColor.backgroundContentPrimary)
                    }
                }
            }
            if row.hiddenGroupCount > 0 {
                MessageReactionChipPill(isSelected: false) {
                    onOpenViewer(nil)
                } label: {
                    Text(verbatim: "+\(row.hiddenGroupCount)")
                        .wnFont(.semiBold10.monospacedDigit())
                        .foregroundStyle(WNColor.backgroundContentPrimary)
                }
                // "+2" alone says nothing out loud, and the pill's job is to open the full list.
                // The catalog's existing "More" — the message overflow control's label — rather
                // than a reactions-specific string: it is the same plain adjective in all nine
                // translations, and it is what this pill means.
                .accessibilityLabel(L10n.string("More"))
            }
        }
    }
}

extension MessageReactionChips {
    /// The visible pill, sized as the prototype sizes it. The chip overlaps the bubble's bottom
    /// edge by `bubbleOverlap`, so these two together are what the caller's negative top padding
    /// is computed from.
    static let pillHeight: CGFloat = 22
    static let horizontalInset: CGFloat = 7
    /// How far the pill rides up onto the bubble — about a third of it, enough to read as bound to
    /// the message rather than floating under it.
    static let bubbleOverlap: CGFloat = 7
    /// Gap between adjacent pills. Tight enough that the row still reads as one attachment to the
    /// bubble rather than as separate buttons.
    static let pillSpacing: CGFloat = 3
}

/// One reaction pill: emoji (+ its count, or the overflow marker) on the shared capsule.
///
/// Generic over its label rather than taking an emoji and a count, because the overflow pill is
/// the same capsule with different contents — duplicating the background would let the two drift
/// apart, and the palette tests assert the capsule's two states, not the pill's contents.
private struct MessageReactionChipPill<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                label
            }
            .wnFont(.medium12)
            .padding(.horizontal, MessageReactionChips.horizontalInset)
            .frame(height: MessageReactionChips.pillHeight)
            .background {
                GlassCapsuleBackground(
                    fill: isSelected ? WNColor.fillSecondaryActive : WNColor.backgroundPrimary,
                    // The selection signal. A fill step alone is too quiet here — one neutral rung
                    // off the surface is roughly 1.2:1 — so the state is carried by the palette's
                    // selected outline, which is what `borderPrimary` is for.
                    borderColor: isSelected ? WNColor.borderPrimary : WNColor.borderTertiary
                )
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
    }
}

/// How a reaction tally is split into the pills a chips row actually draws.
///
/// Pure, so the cap and the count clamp are testable without rendering: the row itself only maps
/// this onto pills. The tally arrives from the core already grouped by emoji (the conversation
/// window's `references.reactions`), so this neither groups nor sorts — it keeps the core's
/// deterministic order so a pill does not move under the pointer when someone else reacts.
nonisolated struct MessageReactionChipRow: Equatable {
    /// Emoji groups drawn as their own pill, in the core's order.
    let visible: [MessageReaction]
    /// Emoji groups past the cap, folded into the trailing overflow pill.
    let hiddenGroupCount: Int

    /// How many distinct emojis get a pill before the rest collapse into `+N`.
    static let maxVisibleGroups = 4

    /// `omittedKinds` are emoji groups the core never sent (past the conversation window's cap);
    /// they have no pill of their own, so they always land in the overflow count.
    static func value(
        reactions: [MessageReaction],
        omittedKinds: Int = 0,
        maxVisibleGroups: Int = Self.maxVisibleGroups
    ) -> Self {
        let omitted = max(0, omittedKinds)
        guard reactions.count > maxVisibleGroups else {
            return Self(visible: reactions, hiddenGroupCount: omitted)
        }
        return Self(
            visible: Array(reactions.prefix(maxVisibleGroups)),
            hiddenGroupCount: reactions.count - maxVisibleGroups + omitted
        )
    }

    static func countLabel(for count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }
}

/// What the reaction pill hangs on in a message row.
///
/// The pill is bubble-bound: it rides `MessageReactionChips.bubbleOverlap` up onto the bottom edge
/// of the thing above it. That thing is the caption bubble when the message has one and the media
/// card when it does not — never the compact timestamp, which is a bare line of text with no edge
/// to ride onto. Pulling the pill up over *that* is what drew the reactions on top of the time on
/// an image sent without a caption: the row ended with the timestamp, so the overlap meant for a
/// bubble's padding bit into the metadata instead. The row now emits the chips before the
/// standalone timestamp, and this decides whether they overlap at all.
enum MessageReactionChipPlacement: Equatable {
    /// Overlapping the bottom edge of the bubble or media card above it.
    case ridingSurfaceEdge
    /// Its own row at the stack's normal spacing, because nothing above it has an edge to take the
    /// pill: a sticker is drawn with no surface behind it, and a row that is only a timestamp has
    /// nothing to hang on.
    case ownRow

    static func value(usesSurface: Bool, usesStickerStyle: Bool) -> Self {
        usesSurface && !usesStickerStyle ? .ridingSurfaceEdge : .ownRow
    }

    /// Top padding for the pill inside a stack of `contentSpacing`. The overlap has to cancel that
    /// spacing before it can bite into the surface, so the two are one number here rather than a
    /// subtraction repeated at the call site.
    func topPadding(
        contentSpacing: CGFloat,
        overlap: CGFloat = MessageReactionChips.bubbleOverlap
    ) -> CGFloat {
        switch self {
        case .ownRow:
            return 0
        case .ridingSurfaceEdge:
            return -(contentSpacing + overlap)
        }
    }
}

/// What the reaction viewer needs from outside its own model: how to name a reactor, draw and load
/// a custom emoji, and add or remove the viewer's reaction. Closures rather than the workspace, so
/// the popover can be previewed and tested with plain values.
struct MessageReactionDetailsDependencies {
    var reactor: (String) -> ReactionReactorDisplay
    var emojiImage: (MessageReaction) -> NSImage? = { _ in nil }
    var loadEmojiImages: ([MessageReaction]) -> Void = { _ in }
    /// Reactors the complete read named, so ones outside the window's identity preview get a name
    /// from the profile directory instead of a short key.
    var requestProfiles: (Set<String>) -> Void = { _ in }
    /// Nil where the viewer cannot act on the message.
    var removeOwnReaction: ((MessageReaction) -> Void)?
    /// The configured quick reactions, offered by the viewer's React control.
    var quickReactions: [String] = []
    /// The emoji the viewer already reacted with, which the React control's picker draws selected.
    var selectedEmojis: Set<String> = []
    /// Reacts to the message with an emoji. Nil where the viewer cannot react, which hides the
    /// React control.
    var react: ((String) -> Void)?
}

/// Reaction viewer: a horizontal "All / per-emoji" filter row over a list of reactors (avatar +
/// name + their emoji). Your own row can be clicked to remove your reaction, and the React control
/// beside the filters adds one without leaving the popover.
///
/// It lists MDK's complete `messageReactions` read, not only the conversation window's bounded
/// preview. A preview that is already complete shows at once, so a small tally opens with no wait;
/// a truncated one waits for the read, with a spinner only once the read is slower than
/// `MessageReactionDetailsPresentation.loadingIndicatorDelay`.
struct MessageReactionDetailsView: View {
    let model: MessageReactionsViewModel
    /// The window's preview for the message, which carries the viewer's own react or un-react
    /// before the complete read catches up.
    let projected: MessageReactionDetails
    @Binding var selectedEmoji: String?
    let dependencies: MessageReactionDetailsDependencies

    init(
        model: MessageReactionsViewModel,
        projected: MessageReactionDetails,
        selectedEmoji: Binding<String?>,
        dependencies: MessageReactionDetailsDependencies
    ) {
        self.model = model
        self.projected = projected
        self._selectedEmoji = selectedEmoji
        self.dependencies = dependencies
    }

    var body: some View {
        let content = model.content(projected: projected)
        VStack(spacing: 0) {
            switch content {
            case .details(let details, let refreshFailed):
                let selection = MessageReactionDetailsPresentation.selection(
                    selectedEmoji, availableEmojis: details.reactions.map(\.emoji))
                HStack(spacing: 0) {
                    MessageReactionFilterRow(
                        details: details,
                        selectedEmoji: selection,
                        emojiImage: dependencies.emojiImage
                    ) { selectedEmoji = $0 }
                    if let react = dependencies.react {
                        MessageReactionAddButton(
                            quickReactions: dependencies.quickReactions,
                            selectedEmojis: dependencies.selectedEmojis,
                            onPick: react
                        )
                        .padding(.trailing, 14)
                    }
                }
                Divider()
                if refreshFailed {
                    MessageReactionRefreshFailedRow { model.retry() }
                }
                MessageReactionReactorList(
                    details: details,
                    selectedEmoji: selection,
                    removesSeveralReactions: projected.omittedKinds > 0
                        || details.unreactMayRemoveSeveralReactions,
                    dependencies: dependencies
                )
                .frame(maxHeight: .infinity)
                .task(id: details.reactions) {
                    dependencies.loadEmojiImages(details.reactions)
                }
            case .loading:
                MessageReactionDetailsLoadingView(showsIndicator: model.showsLoadingIndicator)
            case .failed:
                ContentUnavailableView {
                    Label(L10n.string("Couldn’t load reactions"), systemImage: "exclamationmark.triangle")
                } actions: {
                    Button(L10n.string("Retry")) { model.retry() }
                        .buttonStyle(.wnSecondary)
                }
            case .empty:
                ContentUnavailableView {
                    Label(L10n.string("No reactions"), systemImage: "face.smiling")
                } description: {
                    Text(L10n.string("This message has no reactions, or it’s no longer available."))
                }
            }
        }
        // A definite height so the reactor list fills the popover and shows several rows at once,
        // rather than collapsing to a single intrinsic row.
        .frame(width: 320, height: 420, alignment: .top)
        .task(id: model.reactorAccountIds) {
            dependencies.requestProfiles(model.reactorAccountIds)
        }
    }
}

private struct MessageReactionDetailsLoadingView: View {
    let showsIndicator: Bool

    var body: some View {
        Group {
            if showsIndicator {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MessageReactionRefreshFailedRow: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.string("Couldn’t refresh reactions."))
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            Spacer(minLength: 8)
            // `.link` draws in AppKit's link color, system blue, and ignores `.tint`; only a
            // foreground style overrides it.
            Button(L10n.string("Retry"), action: onRetry)
                .buttonStyle(.link)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .wnFont(.semiBold10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct MessageReactionFilterRow: View {
    let details: MessageReactionDetails
    let selectedEmoji: String?
    let emojiImage: (MessageReaction) -> NSImage?
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MessageReactionFilterPill(isSelected: selectedEmoji == nil, count: details.totalCount) {
                    onSelect(nil)
                } label: {
                    Text(L10n.string("All"))
                }
                ForEach(details.reactions) { reaction in
                    MessageReactionFilterPill(isSelected: selectedEmoji == reaction.emoji, count: reaction.count) {
                        onSelect(reaction.emoji)
                    } label: {
                        ReactionEmojiGlyph(emoji: reaction.emoji, image: emojiImage(reaction))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

/// Opens the same quick-reaction picker as the hover React control. It sits outside the filters'
/// scroll view so it stays reachable however many emoji kinds the message carries.
private struct MessageReactionAddButton: View {
    @State private var isPickerPresented = false
    let quickReactions: [String]
    let selectedEmojis: Set<String>
    let onPick: (String) -> Void

    var body: some View {
        Button {
            isPickerPresented = true
        } label: {
            Image(systemName: "face.smiling")
                .wnFont(.semiBold12)
                // A filter pill at rest: a button on a `background*` surface takes the
                // fill/fill-content pair.
                .foregroundStyle(WNColor.fillContentSecondary)
                .frame(width: 30, height: 30)
                .background(WNColor.fillSecondary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("React"))
        .help(L10n.string("React"))
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            QuickReactionPicker(emojis: quickReactions, selectedEmojis: selectedEmojis) { emoji in
                isPickerPresented = false
                onPick(emoji)
            }
        }
    }
}

private struct MessageReactionFilterPill<Label: View>: View {
    let isSelected: Bool
    let count: Int
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                label
                Text(verbatim: "\(count)")
                    .wnFont(.semiBold10)
            }
            .wnFont(.semiBold12)
            // The viewer's filter pills are buttons on a `background*` surface, so they take the
            // fill/fill-content pairs: `fillPrimary` when active, `fillSecondary` at rest.
            .foregroundStyle(isSelected ? WNColor.fillContentPrimary : WNColor.fillContentSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(isSelected ? WNColor.fillPrimary : WNColor.fillSecondary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MessageReactionReactorList: View {
    let details: MessageReactionDetails
    let selectedEmoji: String?
    let removesSeveralReactions: Bool
    let dependencies: MessageReactionDetailsDependencies

    fileprivate struct Row: Identifiable {
        let reactor: ReactionReactorDisplay
        let reaction: MessageReaction
        var id: String { "\(reactor.accountIdHex)|\(reaction.emoji)" }
    }

    var body: some View {
        let rows = rows
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    MessageReactionReactorRow(
                        row: row,
                        emojiImage: dependencies.emojiImage(row.reaction),
                        removesSeveralReactions: removesSeveralReactions,
                        onRemove: row.reactor.isSelf && row.reaction.canRemoveOwnReaction
                            ? dependencies.removeOwnReaction : nil
                    )
                    if row.id != rows.last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var rows: [Row] {
        let filtered =
            selectedEmoji.map { emoji in details.reactions.filter { $0.emoji == emoji } } ?? details.reactions
        let unsorted = filtered.flatMap { reaction in
            reaction.senders.map { Row(reactor: dependencies.reactor($0), reaction: reaction) }
        }
        // Local account first, then by display name.
        return unsorted.sorted { lhs, rhs in
            if lhs.reactor.isSelf != rhs.reactor.isSelf { return lhs.reactor.isSelf }
            let comparison = lhs.reactor.name.localizedCaseInsensitiveCompare(rhs.reactor.name)
            return comparison == .orderedSame
                ? lhs.reactor.accountIdHex < rhs.reactor.accountIdHex
                : comparison == .orderedAscending
        }
    }
}

private struct MessageReactionReactorRow: View {
    let row: MessageReactionReactorList.Row
    let emojiImage: NSImage?
    let removesSeveralReactions: Bool
    let onRemove: ((MessageReaction) -> Void)?

    var body: some View {
        if let onRemove {
            // A `Button` (not a tap gesture) so removing your reaction is keyboard/VoiceOver
            // reachable.
            Button {
                onRemove(row.reaction)
            } label: {
                MessageReactionReactorRowContent(
                    row: row, emojiImage: emojiImage, removeHint: removeHint)
            }
            .buttonStyle(.plain)
        } else {
            MessageReactionReactorRowContent(row: row, emojiImage: emojiImage, removeHint: nil)
        }
    }

    private var removeHint: String {
        removesSeveralReactions
            ? L10n.string("Tap to remove all your reactions") : L10n.string("Tap to remove")
    }
}

private struct MessageReactionReactorRowContent: View {
    let row: MessageReactionReactorList.Row
    let emojiImage: NSImage?
    let removeHint: String?

    var body: some View {
        HStack(spacing: 10) {
            ProfileImageAvatarView(
                seed: row.reactor.accountIdHex,
                initials: row.reactor.name,
                sanitizedPictureURL: row.reactor.sanitizedPictureURL,
                size: 32,
                isSelected: false
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(row.reactor.isSelf ? L10n.string("You") : row.reactor.name)
                    .wnFont(.medium12)
                    .lineLimit(1)
                if let removeHint {
                    Text(removeHint)
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
            Spacer(minLength: 8)
            ReactionEmojiGlyph(emoji: row.reaction.emoji, image: emojiImage, size: 20)
                .wnFont(.medium16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

#if DEBUG
    private enum MessageReactionDetailsPreviewData {
        static let me = String(repeating: "11", count: 32)
        static let names = [
            me: "Pepi", String(repeating: "22", count: 32): "Ana", String(repeating: "33", count: 32): "Bruno",
        ]

        static let projected = MessageReactionDetails(
            reactions: [
                MessageReaction(emoji: "👍", count: 3, isOwn: true, senders: [me, String(repeating: "22", count: 32)]),
                MessageReaction(emoji: "🔥", count: 1, isOwn: false, senders: [String(repeating: "33", count: 32)]),
            ],
            omittedKinds: 1,
            totalCount: 5
        )

        struct ReadFailure: Error {}

        static func model(
            loadingIndicatorDelay: Duration = MessageReactionDetailsPresentation.loadingIndicatorDelay,
            _ load: @escaping MessageReactionsViewModel.Loader
        ) -> MessageReactionsViewModel {
            let model = MessageReactionsViewModel(
                messageIdHex: "message", viewerAccountIdHex: me, loadingIndicatorDelay: loadingIndicatorDelay,
                load: load)
            model.start()
            return model
        }

        static func model(_ reactions: [TimelineUserReactionFfi]) -> MessageReactionsViewModel {
            model { reactions }
        }

        static let complete =
            names.keys.sorted().enumerated().map { index, sender in
                TimelineUserReactionFfi(
                    reactionMessageIdHex: "r\(index)", targetMessageIdHex: "message", sender: sender, emoji: "👍",
                    reactedAt: UInt64(index))
            } + [
                TimelineUserReactionFfi(
                    reactionMessageIdHex: "r9", targetMessageIdHex: "message",
                    sender: String(repeating: "33", count: 32),
                    emoji: "🔥", reactedAt: 9),
                TimelineUserReactionFfi(
                    reactionMessageIdHex: "r10", targetMessageIdHex: "message",
                    sender: String(repeating: "44", count: 32),
                    emoji: "🎉", reactedAt: 10),
            ]

        static let dependencies = MessageReactionDetailsDependencies(
            reactor: { id in
                ReactionReactorDisplay(
                    accountIdHex: id, name: names[id] ?? DisplayText.short(id), sanitizedPictureURL: nil,
                    isSelf: id == me)
            },
            removeOwnReaction: { _ in },
            quickReactions: ChatReactionDefaults.quick,
            selectedEmojis: ["👍"],
            react: { _ in }
        )
    }

    #Preview("Reaction details") {
        @Previewable @State var selected: String?
        MessageReactionDetailsView(
            model: MessageReactionDetailsPreviewData.model(MessageReactionDetailsPreviewData.complete),
            projected: MessageReactionDetailsPreviewData.projected,
            selectedEmoji: $selected,
            dependencies: MessageReactionDetailsPreviewData.dependencies
        )
    }

    #Preview("Reaction details – loading") {
        @Previewable @State var selected: String?
        // The preview tally is truncated, so it waits on a read that never answers.
        MessageReactionDetailsView(
            model: MessageReactionDetailsPreviewData.model(loadingIndicatorDelay: .zero) {
                Thread.sleep(forTimeInterval: 3600)
                return []
            },
            projected: MessageReactionDetailsPreviewData.projected,
            selectedEmoji: $selected,
            dependencies: MessageReactionDetailsPreviewData.dependencies
        )
    }

    #Preview("Reaction details – failed") {
        @Previewable @State var selected: String?
        MessageReactionDetailsView(
            model: MessageReactionDetailsPreviewData.model { throw MessageReactionDetailsPreviewData.ReadFailure() },
            projected: MessageReactionDetailsPreviewData.projected,
            selectedEmoji: $selected,
            dependencies: MessageReactionDetailsPreviewData.dependencies
        )
    }

    #Preview("Reaction details – empty") {
        @Previewable @State var selected: String?
        MessageReactionDetailsView(
            model: MessageReactionDetailsPreviewData.model([]),
            // The viewer's own reactions follow the window, so an empty state needs an empty one.
            projected: MessageReactionDetails(reactions: []),
            selectedEmoji: $selected,
            dependencies: MessageReactionDetailsPreviewData.dependencies
        )
    }
#endif
