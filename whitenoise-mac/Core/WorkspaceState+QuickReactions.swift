//
//  WorkspaceState+QuickReactions.swift
//  whitenoise-mac
//
//  Live mutation API for the shared quick-reaction preference.
//

import Foundation

@MainActor
extension WorkspaceState {
    @discardableResult
    func replaceQuickReaction(at index: Int, with candidate: String) -> Bool {
        guard quickReactions.indices.contains(index),
            let emoji = QuickReactionSet.validatedEmoji(candidate),
            !quickReactions.enumerated().contains(where: { $0.offset != index && $0.element == emoji })
        else { return false }

        guard quickReactions[index] != emoji else { return true }
        quickReactions[index] = emoji
        quickReactionStore.save(quickReactions)
        return true
    }

    func moveQuickReaction(at index: Int, by offset: Int) {
        let destination = index + offset
        guard quickReactions.indices.contains(index),
            quickReactions.indices.contains(destination),
            index != destination
        else { return }

        quickReactions.swapAt(index, destination)
        quickReactionStore.save(quickReactions)
    }

    func restoreDefaultQuickReactions() {
        quickReactionStore.reset()
        quickReactions = ChatReactionDefaults.quick
    }
}
