//
//  MessageReactionViews.swift
//  whitenoise-mac
//
//  Compact reaction chips shown under a bubble, and the reaction viewer popover that lists who
//  reacted (grouped by emoji), matching the sibling clients' reaction detail panel.
//

import SwiftUI

/// A tight, clustered row of reaction chips (emoji + count). Tapping a chip opens the viewer
/// filtered to that emoji; the overflow chip opens it on "All". Chips are view-only —
/// adding/removing is done from the hover React control.
///
/// Colors come from `WNReactionColors`, which is keyed by direction because a chip hangs off the
/// bubble's edge and therefore sits against `fillPrimary` or `backgroundMessageIncoming` — fills
/// that run in opposite directions. A chip for a reaction the local account added takes the
/// `selected` state.
struct MessageReactionChips: View {
    let reactions: [MessageReaction]
    /// Which bubble these chips hang off, which decides the whole chip color set.
    let isOutgoing: Bool
    /// emoji to focus the viewer on, or nil for the "All" tab.
    let onOpenViewer: (String?) -> Void

    private let maxVisibleEmojis = 6

    /// All reacted emojis run together in one pill (deduped by emoji), matching the sibling
    /// clients' single grouped chip rather than a spread of separate capsules.
    private var emojis: String {
        reactions.prefix(maxVisibleEmojis).map(\.emoji).joined()
    }

    private var totalCount: Int {
        reactions.reduce(0) { $0 + $1.count }
    }

    private var isOwn: Bool {
        reactions.contains { $0.isOwn }
    }

    private var colors: WNReactionColorSet {
        WNReactionColors.set(isOutgoing: isOutgoing)
    }

    var body: some View {
        let colors = colors
        Button {
            onOpenViewer(nil)
        } label: {
            HStack(spacing: 3) {
                Text(emojis)
                if totalCount > 1 {
                    Text(verbatim: "\(totalCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isOwn ? colors.contentSelected : colors.content)
                }
            }
            .font(.footnote)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(isOwn ? colors.fillSelected : colors.fill)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
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
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
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
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if canRemove {
                    Text(L10n.string("Tap to remove"))
                        .font(.caption2)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
            Spacer(minLength: 8)
            Text(row.emoji)
                .font(.title3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
