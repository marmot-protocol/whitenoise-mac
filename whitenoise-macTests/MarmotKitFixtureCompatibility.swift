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
            welcomerAccountIdHex: welcomerAccountIdHex,
            viaWelcomeMessageIdHex: viaWelcomeMessageIdHex
        )
    }
}
