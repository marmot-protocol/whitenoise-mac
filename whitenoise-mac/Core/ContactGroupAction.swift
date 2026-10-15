//
//  ContactGroupAction.swift
//  whitenoise-mac
//
//  Which group commands a member's profile offers when it is opened from group info, and which
//  roster entry that profile is about. Drawn by `ContactGroupActionsSection`.
//

import Foundation

/// The group commands a member's profile offers. Each one is the core's own verdict for this
/// member (`canPromote` / `canDemote` / `canRemove`), so an ordinary member sees none of them.
enum ContactGroupAction: Equatable {
    case promote
    case demote
    case remove

    /// Your own row has no commands here: stepping down as admin lives with Leave in group info,
    /// as it does on iOS, so `canDemote` on yourself is not offered from a profile.
    static func actions(for member: GroupMemberItem) -> [ContactGroupAction] {
        guard !member.isSelf else { return [] }
        var actions: [ContactGroupAction] = []
        if member.canPromote { actions.append(.promote) }
        if member.canDemote { actions.append(.demote) }
        if member.canRemove { actions.append(.remove) }
        return actions
    }

    /// The roster entry for the profile on screen, read from the live group details rather than
    /// captured when the profile opened, so a promotion made from here relabels it in place.
    static func member(accountIdHex: String, in snapshot: GroupDetailsSnapshot?) -> GroupMemberItem? {
        let accountIdHex = accountIdHex.lowercased()
        return snapshot?.members.first { $0.id.lowercased() == accountIdHex }
    }

    /// Whether the profile closes once a removal started from it has finished. It is a profile of
    /// someone in the group, so with them out there is nothing left to act on — back to group info,
    /// as iOS does. A refused removal leaves them listed and the profile stays open to show why;
    /// a profile already replaced by someone else's is not this removal's to close.
    static func closesProfile(
        afterRemoving accountIdHex: String,
        openProfileAccountIdHex: String?,
        in snapshot: GroupDetailsSnapshot?
    ) -> Bool {
        openProfileAccountIdHex?.lowercased() == accountIdHex.lowercased()
            && member(accountIdHex: accountIdHex, in: snapshot) == nil
    }
}
