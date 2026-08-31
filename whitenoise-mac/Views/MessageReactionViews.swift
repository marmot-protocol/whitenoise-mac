//
//  MessageReactionViews.swift
//  whitenoise-mac
//
//  Compact reaction chips shown under a bubble, and the reaction viewer popover that lists who
//  reacted (grouped by emoji), matching the sibling clients' reaction detail panel.
//

import SwiftUI

/// A tight row of reaction chips — **one pill per emoji**, each carrying that emoji's own count.
/// Tapping a pill opens the viewer filtered to that emoji; the trailing overflow pill opens it on
/// "All". Chips are view-only — adding/removing is done from the hover React control.
///
struct MessageReactionChips: View {
    let reactions: [MessageReaction]
    /// emoji to focus the viewer on, or nil for the "All" tab.
    let onOpenViewer: (String?) -> Void

    var body: some View {
        let row = MessageReactionChipRow.value(reactions: reactions)
        HStack(spacing: Self.pillSpacing) {
            ForEach(row.visible) { reaction in
                MessageReactionChipPill(isSelected: reaction.isOwn) {
                    onOpenViewer(reaction.emoji)
                } label: {
                    Text(reaction.emoji)
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
/// this onto pills. The tally arrives from the core already grouped by emoji
/// (`TimelineReactionSummaryFfi.byEmoji`, a `BTreeMap` keyed on the emoji), so this neither groups
/// nor sorts — it keeps the core's deterministic order so a pill does not move under the pointer
/// when someone else reacts.
nonisolated struct MessageReactionChipRow: Equatable {
    /// Emoji groups drawn as their own pill, in the core's order.
    let visible: [MessageReaction]
    /// Emoji groups past the cap, folded into the trailing overflow pill.
    let hiddenGroupCount: Int

    /// How many distinct emojis get a pill before the rest collapse into `+N`.
    static let maxVisibleGroups = 4

    static func value(
        reactions: [MessageReaction],
        maxVisibleGroups: Int = Self.maxVisibleGroups
    ) -> Self {
        guard reactions.count > maxVisibleGroups else {
            return Self(visible: reactions, hiddenGroupCount: 0)
        }
        return Self(
            visible: Array(reactions.prefix(maxVisibleGroups)),
            hiddenGroupCount: reactions.count - maxVisibleGroups
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

/// Reaction viewer: a horizontal "All / per-emoji" filter row over a list of reactors (avatar +
/// name + their emoji). Your own row can be tapped to remove your reaction.
struct MessageReactionDetailsView: View {
    @Environment(WorkspaceState.self) private var workspace
    let message: MessageItem
    @Binding var selectedEmoji: String?

    private struct ReactorRow: Identifiable {
        let reactor: WorkspaceState.ReactionReactorDisplay
        let emoji: String
        let reaction: MessageReaction
        var id: String { "\(reactor.accountIdHex)|\(emoji)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            reactorList
                .frame(maxHeight: .infinity)
        }
        // A definite height so the reactor list fills the popover and shows several rows at once,
        // rather than collapsing to a single intrinsic row.
        .frame(width: 320, height: 420)
    }

    private var totalCount: Int {
        message.reactions.reduce(0) { $0 + $1.count }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterButton(emoji: nil, label: L10n.string("All"), count: totalCount)
                ForEach(message.reactions) { reaction in
                    filterButton(emoji: reaction.emoji, label: reaction.emoji, count: reaction.count)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// The active filter, but only while its emoji still has reactions — so removing your last
    /// reaction of an emoji falls the viewer back to "All" instead of showing an empty list with
    /// no pill highlighted.
    private var effectiveEmoji: String? {
        guard let selectedEmoji, message.reactions.contains(where: { $0.emoji == selectedEmoji }) else {
            return nil
        }
        return selectedEmoji
    }

    private func filterButton(emoji: String?, label: String, count: Int) -> some View {
        let isSelected = effectiveEmoji == emoji
        return Button {
            selectedEmoji = emoji
        } label: {
            HStack(spacing: 5) {
                Text(label)
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

    private var rows: [ReactorRow] {
        let filtered =
            effectiveEmoji.map { emoji in message.reactions.filter { $0.emoji == emoji } }
            ?? message.reactions
        let unsorted = filtered.flatMap { reaction in
            reaction.senders.map { sender in
                ReactorRow(
                    reactor: workspace.reactionReactorDisplay(accountIdHex: sender),
                    emoji: reaction.emoji,
                    reaction: reaction
                )
            }
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

    private var reactorList: some View {
        let reactorRows = rows
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(reactorRows) { row in
                    reactorRow(row)
                    if row.id != reactorRows.last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func reactorRow(_ row: ReactorRow) -> some View {
        let canRemove = row.reactor.isSelf && row.reaction.canRemoveOwnReaction
        if canRemove {
            // A `Button` (not a tap gesture) so removing your reaction is keyboard/VoiceOver
            // reachable.
            Button {
                Task { await workspace.removeReaction(row.reaction, from: message) }
            } label: {
                reactorRowContent(row, canRemove: true)
            }
            .buttonStyle(.plain)
        } else {
            reactorRowContent(row, canRemove: false)
        }
    }

    private func reactorRowContent(_ row: ReactorRow, canRemove: Bool) -> some View {
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
                if canRemove {
                    Text(L10n.string("Tap to remove"))
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
            Spacer(minLength: 8)
            Text(row.emoji)
                .wnFont(.medium16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
