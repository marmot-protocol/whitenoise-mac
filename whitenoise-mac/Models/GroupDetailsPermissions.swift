//
//  GroupDetailsPermissions.swift
//  whitenoise-mac
//
//  What group info offers the reader: which edits, whether to invite, and what to say when not.
//

import MarmotKit

/// Decided once per render of group info and handed to each section, so no two sections can
/// disagree about what the reader may do.
struct GroupDetailsPermissions: Equatable {
    /// Renames, descriptions, images and the disappearing timer. They are group commits: the core
    /// rejects them from a non-member (`invalid_transition`) and from a member the group does not
    /// let edit it. `canEditGroup` is the core's own answer; the snapshot's admin flag stands in
    /// until the conversation header has loaded.
    let canEditGroup: Bool
    /// The group's name, description and image. Never offered in a direct chat: in mdk a name is
    /// what makes a conversation a group, so renaming a DM would quietly turn it into one.
    let canEditProfile: Bool
    let canInvite: Bool
    /// Whether the roster should say why it has no Add row. Only a member who can't invite is
    /// owed that; a former member and a direct chat lack the row for other reasons.
    let showsAdminOnlyNote: Bool

    init(snapshot: GroupDetailsSnapshot, capabilities: ConversationCapabilitiesFfi?, isDirect: Bool) {
        let isMember = snapshot.selfMembership == .member
        canEditGroup = isMember && (capabilities?.canEditGroup ?? snapshot.isSelfAdmin)
        canEditProfile = !isDirect && canEditGroup
        canInvite = isMember && snapshot.canInvite
        showsAdminOnlyNote = !isDirect && isMember && !snapshot.canInvite
    }
}
