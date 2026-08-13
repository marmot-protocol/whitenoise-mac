import Foundation
import MarmotKit

nonisolated extension SendSummaryFfi {
    /// Test convenience for fixtures that do not exercise maintenance deferral.
    init(published: UInt32, messageIds: [String]) {
        self.init(published: published, messageIds: messageIds, maintenanceDisposition: .ready)
    }
}

nonisolated extension AppGroupEncryptedMediaComponentFfi {
    /// Test convenience for older fixture shapes. Required media components model v1 explicitly.
    init(
        componentId: UInt32,
        component: String,
        required: Bool,
        mediaFormat: String,
        allowedLocatorKinds: [String],
        defaultBlobEndpoints: [AppBlobEndpointFfi]
    ) {
        self.init(
            componentId: componentId,
            component: component,
            required: required,
            version: required ? .v1 : nil,
            mediaFormat: mediaFormat,
            allowedLocatorKinds: allowedLocatorKinds,
            defaultBlobEndpoints: defaultBlobEndpoints
        )
    }
}

nonisolated extension AppGroupRecordFfi {
    /// Test convenience for current-profile, recoverable group fixtures.
    init(
        groupIdHex: String,
        endpoint: String,
        name: String,
        description: String,
        admins: [String],
        relays: [String],
        nostrGroupIdHex: String,
        avatarUrl: String?,
        avatarDim: String?,
        avatarThumbhash: String?,
        imageHashHex: String?,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi,
        disappearingMessageSecs: UInt64,
        archived: Bool,
        pendingConfirmation: Bool,
        selfMembership: SelfMembershipFfi,
        welcomerAccountIdHex: String?,
        viaWelcomeMessageIdHex: String?
    ) {
        self.init(
            groupIdHex: groupIdHex,
            protocolProfile: .current,
            endpoint: endpoint,
            profilePresent: true,
            name: name,
            description: description,
            admins: admins,
            relays: relays,
            nostrGroupIdHex: nostrGroupIdHex,
            avatarUrl: avatarUrl,
            avatarDim: avatarDim,
            avatarThumbhash: avatarThumbhash,
            imageHashHex: imageHashHex,
            encryptedMedia: encryptedMedia,
            disappearingMessageSecs: disappearingMessageSecs,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            unrecoverable: false,
            selfMembership: selfMembership,
            leaveRequestPending: false,
            leaveRequestedAtMs: nil,
            disbanding: false,
            disbandRequest: nil,
            disbanded: false,
            welcomerAccountIdHex: welcomerAccountIdHex,
            viaWelcomeMessageIdHex: viaWelcomeMessageIdHex
        )
    }
}

nonisolated extension GroupDetailsFfi {
    init(group: AppGroupRecordFfi, members: [GroupMemberDetailsFfi]) {
        let lifecycleState: GroupLifecycleStateFfi =
            if group.disbanded {
                .disbanded
            } else if group.unrecoverable {
                .unrecoverable
            } else {
                .stable
            }
        self.init(
            group: group,
            members: members,
            mlsState: AppGroupMlsStateFfi(
                groupIdHex: group.groupIdHex,
                protocolProfile: group.protocolProfile,
                lifecycleState: lifecycleState,
                epoch: 0,
                memberCount: UInt32(members.count),
                unrecoverable: group.unrecoverable,
                requiredAppComponents: [],
                disbandingEnabled: false,
                disbanding: group.disbanding,
                disbandingBlockers: [],
                disbandRequest: group.disbandRequest
            )
        )
    }
}

nonisolated extension ChatListMessagePreviewFfi {
    init(
        messageIdHex: String,
        sender: String,
        senderDisplayName: String?,
        plaintext: String,
        contentTokens: MarkdownDocumentFfi,
        kind: UInt64,
        timelineAt: UInt64,
        deleted: Bool
    ) {
        self.init(
            messageIdHex: messageIdHex,
            sender: sender,
            senderDisplayName: senderDisplayName,
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: kind,
            timelineAt: timelineAt,
            deleted: deleted,
            attachmentKind: nil,
            attachmentCount: 0,
            deliveryState: .notApplicable
        )
    }
}

nonisolated extension ChatListRowFfi {
    init(
        groupIdHex: String,
        archived: Bool,
        pendingConfirmation: Bool,
        title: String,
        groupName: String,
        avatarUrl: String?,
        avatar: ChatListAvatarFfi?,
        lastMessage: ChatListMessagePreviewFfi?,
        unreadCount: UInt64,
        hasUnread: Bool,
        unreadMentionCount: UInt64,
        unreadMention: Bool,
        firstUnreadMessageIdHex: String?,
        lastReadMessageIdHex: String?,
        lastReadTimelineAt: UInt64?,
        updatedAt: UInt64,
        selfMembership: SelfMembershipFfi,
        leaveRequestPending: Bool = false,
        conversationKind: ChatConversationKindFfi? = nil
    ) {
        let previewTimelineAt = lastMessage?.timelineAt ?? 0
        let activitySortAt = previewTimelineAt > 0 ? previewTimelineAt : updatedAt
        self.init(
            groupIdHex: groupIdHex,
            pinned: false,
            pinnedPosition: nil,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            lifecycleState: .stable,
            disbanding: false,
            disbandRequest: nil,
            title: title,
            groupName: groupName,
            avatarUrl: avatarUrl,
            avatar: avatar,
            lastMessage: lastMessage,
            unreadCount: unreadCount,
            hasUnread: hasUnread,
            manuallyMarkedUnread: hasUnread && unreadCount == 0,
            unreadMentionCount: unreadMentionCount,
            unreadMention: unreadMention,
            firstUnreadMessageIdHex: firstUnreadMessageIdHex,
            lastReadMessageIdHex: lastReadMessageIdHex,
            lastReadTimelineAt: lastReadTimelineAt,
            conversationCreatedAt: activitySortAt,
            activitySortAt: activitySortAt,
            updatedAt: updatedAt,
            selfMembership: selfMembership,
            // Mirrors mdk's `conversation_kind`: a non-blank group name is a group before the
            // member count is even consulted. A blank name stays `.unknown` here because this
            // shim carries no member count — which is what mdk returns in that case too.
            conversationKind: conversationKind
                ?? (groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unknown : .group),
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: leaveRequestPending,
            leaveRequestedAtMs: leaveRequestPending ? 1_700_000_000_000 : nil
        )
    }
}

nonisolated extension GroupManagementStateFfi {
    init(
        myAccountIdHex: String,
        isSelfAdmin: Bool,
        isLastAdmin: Bool,
        canInvite: Bool,
        canLeave: Bool,
        requiresSelfDemoteBeforeLeave: Bool,
        leaveRequestPending: Bool = false,
        leaveRequestedAtMs: UInt64? = nil,
        memberActions: [GroupMemberActionStateFfi]
    ) {
        self.init(
            myAccountIdHex: myAccountIdHex,
            isSelfAdmin: isSelfAdmin,
            isLastAdmin: isLastAdmin,
            canInvite: canInvite,
            canLeave: canLeave,
            requiresSelfDemoteBeforeLeave: requiresSelfDemoteBeforeLeave,
            leaveRequestPending: leaveRequestPending,
            leaveRequestedAtMs: leaveRequestedAtMs,
            lifecycleState: .stable,
            disbandingEnabled: false,
            disbanding: false,
            canEnableDisbanding: false,
            canDisband: false,
            disbandingBlockers: [],
            disbandRequest: nil,
            memberActions: memberActions
        )
    }
}

nonisolated extension TimelineMessageRecordFfi {
    init(
        messageIdHex: String,
        sourceMessageIdHex: String?,
        direction: String,
        groupIdHex: String,
        sender: String,
        plaintext: String,
        contentTokens: MarkdownDocumentFfi,
        kind: UInt64,
        tags: [MessageTagFfi],
        timelineAt: UInt64,
        receivedAt: UInt64,
        replyToMessageIdHex: String?,
        replyPreview: TimelineReplyPreviewFfi?,
        mediaJson: String?,
        media: [MediaAttachmentReferenceFfi],
        agentTextStreamJson: String?,
        groupSystem: GroupSystemEventFfi?,
        reactions: TimelineReactionSummaryFfi,
        deleted: Bool,
        deletedByMessageIdHex: String?,
        invalidationStatus: String?
    ) {
        self.init(
            messageIdHex: messageIdHex,
            sourceMessageIdHex: sourceMessageIdHex,
            sourceEpoch: nil,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
            direction: direction,
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: kind,
            tags: tags,
            timelineAt: timelineAt,
            receivedAt: receivedAt,
            replyToMessageIdHex: replyToMessageIdHex,
            replyPreview: replyPreview,
            mediaJson: mediaJson,
            media: media,
            agentTextStreamJson: agentTextStreamJson,
            groupSystem: groupSystem,
            reactions: reactions,
            deleted: deleted,
            deletedByMessageIdHex: deletedByMessageIdHex,
            invalidationStatus: invalidationStatus
        )
    }
}

nonisolated extension MarkdownDocumentFfi {
    init(blocks: [MarkdownBlockFfi], truncated: Bool) {
        self.init(
            blocks: blocks,
            truncated: truncated,
            blankLinesBefore: Data(repeating: 0, count: blocks.count)
        )
    }
}

nonisolated extension MarkdownListItemFfi {
    init(blocks: [MarkdownBlockFfi], checked: Bool?) {
        self.init(
            blocks: blocks,
            checked: checked,
            blankLinesBefore: Data(repeating: 0, count: blocks.count)
        )
    }
}
