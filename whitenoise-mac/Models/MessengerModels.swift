import AVFoundation
import AppKit
import Foundation
import ImageIO
import MarmotKit
import UniformTypeIdentifiers

struct AccountItem: Identifiable, Hashable {
    let id: String
    let accountRef: String
    let displayName: String
    let accountIdHex: String
    let npub: String?
    let initials: String
    let pictureURL: String?
    /// Pre-sanitized avatar URL; `ProfileImageAvatarView` still applies `loadRemoteImages`.
    let sanitizedPictureURL: URL?
    let localSigning: Bool
    let externalSigning: Bool
    let isRunning: Bool
    /// True when the account has been signed out (non-destructive): local data is
    /// retained but it is not active until signed back in.
    let signedOut: Bool

    nonisolated init(
        id: String,
        accountRef: String,
        displayName: String,
        accountIdHex: String,
        npub: String? = nil,
        initials: String? = nil,
        pictureURL: String? = nil,
        sanitizedPictureURL: URL? = nil,
        localSigning: Bool = true,
        externalSigning: Bool = false,
        isRunning: Bool = true,
        signedOut: Bool = false
    ) {
        self.id = id
        self.accountRef = accountRef
        self.displayName = displayName
        self.accountIdHex = accountIdHex
        self.npub = npub
        self.initials = initials ?? DisplayText.initials(for: displayName, fallback: accountIdHex)
        self.pictureURL = pictureURL
        self.sanitizedPictureURL =
            sanitizedPictureURL ?? RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
        self.localSigning = localSigning
        self.externalSigning = externalSigning
        self.isRunning = isRunning
        self.signedOut = signedOut
    }
}

/// Whether the local account is still a member of a group, and if not, whether it
/// left voluntarily or was removed. Mirrors the FFI's `SelfMembershipFfi`: ended
/// chats stay in the list so the history remains readable, but the core rejects
/// sends to them (`invalid_transition`), so the composer must not offer to send.
nonisolated enum ChatSelfMembership: Hashable {
    case member
    case left
    case removed

    /// Short badge label for sidebar rows, `nil` while still a member.
    var sidebarBadgeLabel: String? {
        switch self {
        case .member:
            return nil
        case .left:
            return L10n.string("Left")
        case .removed:
            return L10n.string("Removed")
        }
    }

    /// One-line explanation of the ended membership, used by the sidebar badge
    /// tooltip and the composer notice. `nil` while still a member.
    var endedDescription: String? {
        endedDescription(locale: AppLanguage.currentLocale)
    }

    /// The same line resolved against a caller-supplied locale, for the surfaces that are not
    /// rebuilt on a language switch — see `ChatItem.previewNotice(locale:)`.
    func endedDescription(locale: Locale) -> String? {
        switch self {
        case .member:
            return nil
        case .left:
            return L10n.string("You left this group", locale: locale)
        case .removed:
            return L10n.string("You were removed from this group", locale: locale)
        }
    }

    /// Whether this ended membership says so on the row's preview line instead of in a capsule
    /// beside the title.
    ///
    /// Only removal does. Being removed is the one ended state the reader did not choose, so the
    /// row spends its widest slot saying it in the same words the chat itself does
    /// (`MembershipEndedComposerNotice`) rather than compressing it to a "Removed" capsule the
    /// reader has to hover to expand. Leaving stays a capsule: the reader already knows they left,
    /// and the last message is still the more useful thing for that row to show.
    var reportsInChatRowPreviewLine: Bool {
        self == .removed
    }

    /// SF Symbol shown alongside the ended state, `nil` while still a member.
    var endedSymbolName: String? {
        switch self {
        case .member:
            return nil
        case .left:
            return "rectangle.portrait.and.arrow.right"
        case .removed:
            return "person.fill.xmark"
        }
    }

    /// Secondary line shown under `endedDescription` wherever the ended state is
    /// explained (composer notice, group details).
    static var endedHistoryExplanation: String {
        L10n.string("You can keep reading the history, but new messages can't be sent.")
    }
}

nonisolated struct ChatItem: Identifiable, Hashable {
    let id: String
    var title: String
    var publishedTitle: String?
    let subtitle: String
    /// The chat's last message as the row draws it, or empty when the chat has none.
    ///
    /// Deliberately *not* pre-filled with a "No messages yet" placeholder: what an empty chat
    /// says depends on why it is empty — an unanswered invite explains itself here — and the
    /// answer is localized, so it is resolved at render time by `previewPlaceholder(locale:)`.
    ///
    /// `private(set)` so the only in-place writer is `relabelingPreviewSender` below, which
    /// recomposes the attribution prefix from `previewAttribution`.
    private(set) var preview: String
    /// Set when the last message carries attachments, so the row can mark the preview with a
    /// media glyph. Travels with `preview` — anything that carries one forward carries both.
    let previewAttachmentKind: ChatPreviewAttachmentKind?
    /// The parts `preview` was composed from, set only when the line is attributed to another
    /// account. Travels with `preview` for the same reason `previewAttachmentKind` does.
    let previewAttribution: ChatPreviewAttribution?
    let updatedAt: Date?
    let avatarSeed: String
    /// `private(set)` so the only in-place writer is `replacingPeerPresentation` below, which
    /// re-derives `sanitizedPictureURL` alongside it. The two must never disagree.
    private(set) var pictureURL: String?
    /// Pre-sanitized avatar URL for chat rows/headers; the view still applies `loadRemoteImages`.
    private(set) var sanitizedPictureURL: URL?
    /// Decrypted encrypted-Blossom group image. Direct chats leave this nil and use the peer
    /// profile picture instead. The payload id is the component's content hash, so decoded-image
    /// caching naturally invalidates when the group commits a replacement image.
    let groupImagePayload: DownloadedMediaPayload?
    let groupImageHashHex: String?
    let unreadCount: Int
    /// Includes ordinary unread messages and the user's durable manual-unread reminder.
    let hasUnread: Bool
    let manuallyMarkedUnread: Bool
    /// Unread messages in this chat that @-mention the active account.
    let unreadMentionCount: Int
    let isDirect: Bool
    /// True when MDK supplied `.direct`/`.group`; false permits legacy roster enrichment.
    let hasAuthoritativeConversationKind: Bool
    let muted: Bool
    /// Absolute Unix epoch milliseconds for a finite mute; nil means indefinite while muted.
    let mutedUntilMs: Int64?
    let leaveRequestPending: Bool
    let latestMessageDelivery: ChatMessageDeliveryState
    let pendingConfirmation: Bool
    let selfMembership: ChatSelfMembership
    /// Precomputed once from `updatedAt` (which is immutable for a given value) to
    /// avoid re-formatting the date on every chat-row render.
    let timestampLabel: String

    /// Whether this chat has at least one unread @-mention of the active account.
    var hasMention: Bool { unreadMentionCount > 0 }

    /// True when the local account left or was removed from this group.
    var isNoLongerMember: Bool { selfMembership != .member }

    /// True when the local account can use the outbound composer for this chat.
    var canUseComposer: Bool { !pendingConfirmation && !isNoLongerMember }

    /// What the row draws where the last message would go, whenever something other than the last
    /// message belongs there. `nil` means `preview` speaks for itself.
    ///
    /// A removal outranks the last message: the chat is closed to the reader, so what the row has
    /// to report is that fact rather than whatever was said before it. Every other state only
    /// fills the line when there is no message to draw — see `previewPlaceholder(locale:)`.
    func previewNotice(locale: Locale = AppLanguage.currentLocale) -> String? {
        if selfMembership.reportsInChatRowPreviewLine {
            return selfMembership.endedDescription(locale: locale)
        }
        return previewPlaceholder(locale: locale)
    }

    /// What the row draws where the last message would go, for a chat that has no last message.
    /// `nil` means `preview` carries a real message and should be drawn as-is.
    ///
    /// An unanswered invite spends this line saying so, the way the other clients do, rather than
    /// wearing a capsule beside its title: the line is the one part of the row that is otherwise
    /// empty for exactly the chats an invite arrives in, and it has the width to say who invited
    /// you. The `+` badge in the unread slot is the other half of that reading.
    ///
    /// Resolved here rather than baked into `preview` at mapping time because it is localized:
    /// the chat list is not rebuilt on a language switch, so a stored translation would keep the
    /// previous language until some unrelated update happened to rebuild the row.
    func previewPlaceholder(locale: Locale = AppLanguage.currentLocale) -> String? {
        guard preview.isEmpty else { return nil }
        guard ChatRowStatus.status(for: self) == .pendingInvite else {
            return L10n.string("No messages yet", locale: locale)
        }
        // A direct invite's row title is the person who sent it, so this line continues from it.
        // A group invite's title is the group, and the chat-list row carries no welcomer, so it
        // stays subjectless rather than guessing at a name.
        return isDirect
            ? L10n.string("Has invited you to a secure chat", locale: locale)
            : L10n.string("You have been invited to a secure chat", locale: locale)
    }

    /// The other party's account hex, for a direct chat whose peer has actually resolved.
    ///
    /// `avatarSeed` carries that hex, but falls back to the group id whenever no peer resolved —
    /// before roster enrichment lands, and permanently for a note-to-self chat, which has no other
    /// member. Contact affordances must key off this rather than the seed, so they never offer to
    /// act on a group id as though it were a person.
    var directPeerAccountIdHex: String? {
        guard isDirect, avatarSeed != id else { return nil }
        return avatarSeed
    }

    /// A chat row's last-message line with the sender it is attributed to, or the line alone when
    /// nobody's name precedes it.
    ///
    /// The name is bidi-isolated so a peer-controlled display name cannot reorder the message text
    /// that follows it. An empty name means "unattributed" — a member who published no name and
    /// carries no nickname has nothing to put here.
    nonisolated static func attributedPreviewText(body: String, senderName: String?) -> String {
        guard let senderName, !senderName.isEmpty else { return body }
        return
            "\(PeerDisplayText.templateFragment(senderName))\(previewAttributionSeparator)\(body)"
    }

    /// The separator `attributedPreviewText` joins a sender's name to their message with, and the
    /// seam `previewAttributionParts` splits the line back apart on.
    nonisolated static let previewAttributionSeparator = ": "

    /// `preview` split back into the sender's displayed name and their message, or `nil` when this
    /// row's line carries no attribution.
    ///
    /// The chat row sets the name in Bold and leaves the message in the row's ordinary weight, so
    /// it needs the two apart. It cannot rebuild the prefix from `previewAttribution`, whose
    /// `publishedSenderName` is the *published* name — a private nickname would have replaced it in
    /// `preview` through `relabelingPreviewSender`, and the row must show what the line actually
    /// says. So the split is anchored on the tail instead: `previewAttribution.body` is the message
    /// verbatim, which makes everything before its separator the name, however many colons the name
    /// itself contains.
    ///
    /// The name keeps the bidi isolation `attributedPreviewText` wrapped it in — a peer-controlled
    /// display name must not be able to reorder the message text after it, and that holds just as
    /// much when the name is drawn as its own run.
    nonisolated var previewAttributionParts: (senderName: String, body: String)? {
        guard let previewAttribution else { return nil }
        let separated = Self.previewAttributionSeparator + previewAttribution.body
        guard preview.hasSuffix(separated) else { return nil }
        let senderName = String(preview.dropLast(separated.count))
        guard !senderName.isEmpty else { return nil }
        return (senderName, previewAttribution.body)
    }

    /// A copy whose last-message attribution reflects `nickname`, or `self` when this row's
    /// preview is not attributed to that account.
    ///
    /// Recomposing the line beats re-projecting the row: a nickname write must not put chat-list
    /// enrichment (roster + profile FFI) back on a user gesture. Rows the nickname does not touch
    /// return unchanged so an unrelated contact's rename never churns the chat-list generation.
    nonisolated func relabelingPreviewSender(accountIdHex: String, nickname: String?) -> ChatItem {
        guard let previewAttribution,
            ContactNicknames.normalizedHex(previewAttribution.senderAccountIdHex) == accountIdHex
        else { return self }

        let text = Self.attributedPreviewText(
            body: previewAttribution.body,
            senderName: nickname ?? previewAttribution.publishedSenderName
        )
        guard text != preview else { return self }
        var copy = self
        copy.preview = text
        return copy
    }

    /// A copy whose title reflects `nickname`, leaving every other field identical.
    ///
    /// Applying a private nickname must not re-run chat-list enrichment, so a nickname write
    /// patches the affected rows through here instead. `publishedTitle` records the title being
    /// overridden, which is also what restores it when the nickname is cleared.
    nonisolated func applyingNickname(_ nickname: String?) -> ChatItem {
        let published = publishedTitle ?? title
        var copy = self
        if let nickname {
            copy.title = nickname
            copy.publishedTitle = nickname == published ? nil : published
        } else {
            copy.title = published
            copy.publishedTitle = nil
        }
        return copy
    }

    /// A copy whose peer-derived presentation — title, the published name a nickname is
    /// overriding, and the avatar — reflects a profile that resolved after this row was built.
    ///
    /// Mutates a copy rather than re-invoking the memberwise initializer. Listing the carried
    /// fields by hand reads as exhaustive but silently drops any field added to `ChatItem`
    /// later, and every one of them (unread counts, mute and membership state, the preview's
    /// attachment glyph) is row state a profile refresh has no business inventing.
    nonisolated func replacingPeerPresentation(
        displayName: String,
        publishedDisplayName: String?,
        pictureURL: String?
    ) -> ChatItem {
        var copy = self
        copy.title = displayName
        // A private nickname makes `title` the nickname and `publishedTitle` the name the peer
        // actually publishes, so the published name has to be carried explicitly here.
        copy.publishedTitle = publishedDisplayName
        if let pictureURL {
            copy.pictureURL = pictureURL
            copy.sanitizedPictureURL = RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
        }
        return copy
    }

    /// Re-derives the relative spelling against a wall-clock reference date. Views use
    /// this when the calendar day changes; `timestampLabel` remains the cheap mapping-time
    /// value used during ordinary renders.
    nonisolated func timestampLabel(
        at now: Date,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        guard let updatedAt else { return "" }
        return DisplayText.relativeTimestamp(for: updatedAt, now: now, locale: locale)
    }

    init(
        id: String,
        title: String,
        publishedTitle: String? = nil,
        subtitle: String,
        preview: String,
        previewAttachmentKind: ChatPreviewAttachmentKind? = nil,
        previewAttribution: ChatPreviewAttribution? = nil,
        updatedAt: Date?,
        avatarSeed: String,
        pictureURL: String?,
        sanitizedPictureURL: URL? = nil,
        groupImagePayload: DownloadedMediaPayload? = nil,
        groupImageHashHex: String? = nil,
        unreadCount: Int,
        hasUnread: Bool? = nil,
        manuallyMarkedUnread: Bool = false,
        unreadMentionCount: Int = 0,
        isDirect: Bool = false,
        hasAuthoritativeConversationKind: Bool = false,
        muted: Bool = false,
        mutedUntilMs: Int64? = nil,
        leaveRequestPending: Bool = false,
        latestMessageDelivery: ChatMessageDeliveryState = .notApplicable,
        pendingConfirmation: Bool = false,
        selfMembership: ChatSelfMembership = .member
    ) {
        self.id = id
        self.title = title
        self.publishedTitle = publishedTitle
        self.subtitle = subtitle
        self.preview = preview
        self.previewAttachmentKind = previewAttachmentKind
        self.previewAttribution = previewAttribution
        self.updatedAt = updatedAt
        self.avatarSeed = avatarSeed
        self.pictureURL = pictureURL
        self.sanitizedPictureURL =
            sanitizedPictureURL ?? RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
        self.groupImagePayload = groupImagePayload
        self.groupImageHashHex = groupImageHashHex
        self.unreadCount = unreadCount
        self.hasUnread = hasUnread ?? (unreadCount > 0)
        self.manuallyMarkedUnread = manuallyMarkedUnread
        self.unreadMentionCount = unreadMentionCount
        self.isDirect = isDirect
        self.hasAuthoritativeConversationKind = hasAuthoritativeConversationKind
        self.muted = muted
        self.mutedUntilMs = mutedUntilMs
        self.leaveRequestPending = leaveRequestPending
        self.latestMessageDelivery = latestMessageDelivery
        self.pendingConfirmation = pendingConfirmation
        self.selfMembership = selfMembership
        if let updatedAt {
            self.timestampLabel = DisplayText.relativeTimestamp(for: updatedAt)
        } else {
            self.timestampLabel = ""
        }
    }
}

nonisolated enum ChatMessageDeliveryState: Hashable, Sendable {
    case notApplicable
    case pending
    case delivered
    case failed
}

/// Who a chat row's last-message line is attributed to, kept alongside the composed `preview` so
/// a nickname write can recompose the prefix in place.
///
/// Present whenever the last message came from *another* account — including one that published no
/// name, since nicknaming them is exactly what gives that line a prefix. Your own messages read
/// "You:" in every language, which no private label can change, so they never carry one.
nonisolated struct ChatPreviewAttribution: Hashable, Sendable {
    let senderAccountIdHex: String
    /// The name that sender publishes — what the prefix falls back to with no nickname on file,
    /// and what clearing one restores. `nil` for a member who published none.
    let publishedSenderName: String?
    /// The last-message line without its attribution prefix.
    let body: String
}

/// Which attachment glyph a chat row draws ahead of its last-message preview.
///
/// Mirrors MDK's `ChatListAttachmentKindFfi`. `mixed` covers both a message carrying more than
/// one kind at once and one whose kind the core did not report, so an attachment always reads as
/// an attachment even when its media type is unknown.
nonisolated enum ChatPreviewAttachmentKind: Hashable, Sendable {
    case photo
    case video
    case audio
    case file
    case mixed

    var systemImageName: String {
        switch self {
        case .photo:
            "photo"
        case .video:
            "video"
        case .audio:
            "waveform"
        case .file:
            "doc"
        case .mixed:
            "paperclip"
        }
    }
}

/// What one bubble's delivery footer should read right now — the timeline counterpart of the
/// sidebar's `ChatMessageDeliveryState`.
///
/// The core commits an own send locally *before* it publishes, and the only per-message signal it
/// exposes is `sourceMessageIdHex`, which stays nil for both "still going out" and "never made
/// it". Collapsing those two into one red error made every ordinary send flash "not delivered"
/// before settling — most visibly for media, whose larger event spends longer in the publish
/// round-trip. `.sending` covers the in-flight window; the bubble only escalates to `.failed`
/// once the send has been outstanding past `MessageItem.pendingDeliveryGrace`.
nonisolated enum MessageDeliveryIndicator: Hashable, Sendable {
    case none
    case sending
    case delivered
    case failed
}

/// The parts of a `MessageItem` that decide its delivery footer.
nonisolated struct MessageDeliverySignature: Hashable, Sendable {
    let messageId: String
    let sentAt: Date
    let isPendingDelivery: Bool
    let isInvalidated: Bool
    let isOutgoing: Bool
}

// `Sendable` so the timeline window/projection mapping can capture the resolved
// sender-profile map in the off-main `MessageItem.timeline(...)` closure
// (whitenoise-mac#285). All stored properties are value types, so the conformance is
// checked; `nonisolated` opts the value type out of the module's default main-actor
// isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), a prerequisite for `Sendable`.
nonisolated struct ChatPeerProfile: Hashable, Sendable {
    let accountIdHex: String
    let displayName: String?
    let publishedDisplayName: String?
    let pictureURL: String?

    init(
        accountIdHex: String,
        displayName: String?,
        publishedDisplayName: String? = nil,
        pictureURL: String?
    ) {
        self.accountIdHex = accountIdHex
        self.displayName = displayName
        self.publishedDisplayName = publishedDisplayName
        self.pictureURL = pictureURL
    }
}

struct GroupMemberItem: Identifiable, Hashable {
    let id: String
    /// The viewer's private nickname for this member when one is set, else the published name.
    let displayName: String
    /// The published name `displayName` overrides; nil when no nickname applies.
    let publishedDisplayName: String?
    let npub: String
    let accountLabel: String?
    let isLocal: Bool
    let isAdmin: Bool
    let isSelf: Bool
    let canRemove: Bool
    let canPromote: Bool
    let canDemote: Bool

    var initials: String {
        DisplayText.initials(for: displayName, fallback: id)
    }

    var detailLabel: String {
        if isSelf {
            return L10n.string("You")
        }
        if let accountLabel = PeerDisplayText.sanitize(accountLabel) {
            return accountLabel
        }
        return DisplayText.short(npub, head: 12, tail: 8)
    }
}

struct GroupDetailsSnapshot: Hashable {
    let groupIdHex: String
    let endpoint: String
    /// The group's name as the inspector header draws it, falling back to a localized "Unnamed
    /// group" so the header is never blank. A display label, not a name — read `customName` for
    /// anything that has to put the group's own name into a sentence.
    let name: String
    /// The name the group actually carries, or `nil` when it has none. Kept alongside `name`
    /// because the placeholder above is both localized and indistinguishable from a group somebody
    /// really did call "Unnamed group".
    let customName: String?
    let description: String
    let avatarURL: String?
    /// Pre-sanitized once from the group profile avatar URL for details/header rendering.
    let sanitizedAvatarURL: URL?
    let avatarDimension: String?
    let nostrGroupIdHex: String
    let relays: [String]
    let adminIds: [String]
    let archived: Bool
    let pendingConfirmation: Bool
    let selfMembership: ChatSelfMembership
    let members: [GroupMemberItem]
    let isSelfAdmin: Bool
    let isLastAdmin: Bool
    let canInvite: Bool
    let canLeave: Bool
    let requiresSelfDemoteBeforeLeave: Bool
    let leaveRequestPending: Bool
    let leaveRequestedAtMs: UInt64?
    /// Per-group disappearing-message timer in seconds; `0` means messages never expire.
    let disappearingMessageSecs: UInt64

    init(
        groupIdHex: String,
        endpoint: String,
        name: String,
        customName: String? = nil,
        description: String,
        avatarURL: String?,
        sanitizedAvatarURL: URL?,
        avatarDimension: String?,
        nostrGroupIdHex: String,
        relays: [String],
        adminIds: [String],
        archived: Bool,
        pendingConfirmation: Bool,
        selfMembership: ChatSelfMembership,
        members: [GroupMemberItem],
        isSelfAdmin: Bool,
        isLastAdmin: Bool,
        canInvite: Bool,
        canLeave: Bool,
        requiresSelfDemoteBeforeLeave: Bool,
        leaveRequestPending: Bool = false,
        leaveRequestedAtMs: UInt64? = nil,
        disappearingMessageSecs: UInt64
    ) {
        self.groupIdHex = groupIdHex
        self.endpoint = endpoint
        self.name = name
        self.customName = customName
        self.description = description
        self.avatarURL = avatarURL
        self.sanitizedAvatarURL = sanitizedAvatarURL
        self.avatarDimension = avatarDimension
        self.nostrGroupIdHex = nostrGroupIdHex
        self.relays = relays
        self.adminIds = adminIds
        self.archived = archived
        self.pendingConfirmation = pendingConfirmation
        self.selfMembership = selfMembership
        self.members = members
        self.isSelfAdmin = isSelfAdmin
        self.isLastAdmin = isLastAdmin
        self.canInvite = canInvite
        self.canLeave = canLeave
        self.requiresSelfDemoteBeforeLeave = requiresSelfDemoteBeforeLeave
        self.leaveRequestPending = leaveRequestPending
        self.leaveRequestedAtMs = leaveRequestedAtMs
        self.disappearingMessageSecs = disappearingMessageSecs
    }

    var memberCountLabel: String {
        L10n.plural("%lld members", Int64(members.count))
    }

    var disappearingMessagesEnabled: Bool { disappearingMessageSecs > 0 }
}

struct ConversationMetadata: Hashable {
    let memberCount: Int
    let disappearingMessageSecs: UInt64
    let isSelfAdmin: Bool

    var subtitle: String {
        if disappearingMessageSecs > 0 {
            return String(
                format: L10n.string("Disappearing messages: %@"),
                DisappearingMessageOption.option(for: disappearingMessageSecs).label
            )
        }
        return L10n.plural("%lld members", Int64(memberCount))
    }
}

enum GroupDetailsHeaderAvatar {
    static func sanitizedURL(snapshot: GroupDetailsSnapshot?, fallback chat: ChatItem) -> URL? {
        snapshot?.sanitizedAvatarURL ?? chat.sanitizedPictureURL
    }
}

nonisolated struct MessageReaction: Identifiable, Hashable {
    let emoji: String
    let count: Int
    let isOwn: Bool
    let ownReactionMessageId: String?
    /// Account-id-hex of everyone who reacted with this emoji, so the reaction viewer can list them.
    let senders: [String]

    init(emoji: String, count: Int, isOwn: Bool, ownReactionMessageId: String? = nil, senders: [String] = []) {
        self.emoji = emoji
        self.count = count
        self.isOwn = isOwn
        self.ownReactionMessageId = ownReactionMessageId
        self.senders = senders
    }

    var id: String { emoji }

    var label: String {
        count > 1 ? "\(emoji) \(count)" : emoji
    }

    var canRemoveOwnReaction: Bool {
        ownReactionMessageId != nil
    }
}

nonisolated struct MessageReplyContext: Hashable {
    let targetMessageId: String
    /// `var` so a private-nickname write can relabel a quote already on screen without
    /// re-projecting the timeline. See `MessageItem.applyingSenderNickname(_:)`.
    var senderName: String
    let body: String
}

nonisolated struct MessageEditContext: Hashable {
    let targetMessageId: String
    let senderName: String
    let originalBody: String
    let preservedDraft: String
    let preservedMentionSelections: [ComposerMentionSelection]
    let preservedReplyContext: MessageReplyContext?
    let preservedMediaAttachments: [PendingMediaAttachment]
    let preservedMediaUploadStates: [PendingMediaAttachment.ID: PendingMediaUploadState]
}

nonisolated enum MessageMediaKind: Hashable, Sendable {
    case image
    case audio
    case video
    case file

    var systemImageName: String {
        switch self {
        case .image:
            "photo"
        case .audio:
            "waveform"
        case .video:
            "play.rectangle"
        case .file:
            "doc"
        }
    }
}

nonisolated struct MessageMediaAttachment: Identifiable, Hashable {
    let id: String
    let reference: MediaAttachmentReferenceFfi

    var fileName: String {
        reference.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.string("Attachment")
            : reference.fileName
    }

    var mediaType: String {
        reference.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "application/octet-stream"
            : reference.mediaType
    }

    var kind: MessageMediaKind {
        OutgoingMediaAttachmentPolicy.kind(mediaType: mediaType, fileName: fileName)
    }

    var previewLabel: String {
        switch kind {
        case .image:
            return L10n.string("Photo")
        case .audio:
            return L10n.string("Audio")
        case .video:
            return L10n.string("Video")
        case .file:
            return L10n.string("Attachment")
        }
    }

    static func previewText(for attachments: [MessageMediaAttachment]) -> String {
        guard let first = attachments.first else { return "" }
        if attachments.count == 1 {
            return first.previewLabel
        }
        return L10n.plural("%lld attachments", Int64(attachments.count))
    }
}

nonisolated final class DownloadedMediaPayload: @unchecked Sendable, Hashable {
    let id: String
    private let storage: Data

    init(id: String = UUID().uuidString, data: Data) {
        self.id = id
        self.storage = data
    }

    var data: Data {
        storage
    }

    var byteCount: Int {
        storage.count
    }

    static func == (lhs: DownloadedMediaPayload, rhs: DownloadedMediaPayload) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated struct MessageMediaDownload: Hashable, Sendable {
    let payload: DownloadedMediaPayload
    let fileName: String
    let mediaType: String
    let sizeBytes: UInt64
    let sizeLabel: String

    init(
        payload: DownloadedMediaPayload,
        fileName: String,
        mediaType: String,
        sizeBytes: UInt64
    ) {
        self.payload = payload
        self.fileName = fileName
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
        self.sizeLabel = Self.sizeLabel(for: sizeBytes)
    }

    init(
        data: Data,
        fileName: String,
        mediaType: String,
        sizeBytes: UInt64,
        payloadId: String = UUID().uuidString
    ) {
        self.init(
            payload: DownloadedMediaPayload(id: payloadId, data: data),
            fileName: fileName,
            mediaType: mediaType,
            sizeBytes: sizeBytes
        )
    }

    var data: Data {
        payload.data
    }

    func detailText(fallbackMediaType: String) -> String {
        "\(mediaType.nilIfBlank ?? fallbackMediaType) - \(sizeLabel)"
    }

    private static func sizeLabel(for sizeBytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: sizeBytes), countStyle: .file)
    }
}

nonisolated enum MessageMediaGridPresentation {
    static let maxVisibleItems = 6

    static func visibleCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), maxVisibleItems)
    }

    static func hiddenCount(totalCount: Int) -> Int {
        max(0, totalCount - maxVisibleItems)
    }

    static func rowCounts(totalCount: Int) -> [Int] {
        switch visibleCount(totalCount: totalCount) {
        case 1: [1]
        case 2: [2]
        case 3: [3]
        case 4: [2, 2]
        case 5: [3, 2]
        case 6...: [3, 3]
        default: []
        }
    }

    static func rowRanges(totalCount: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for count in rowCounts(totalCount: totalCount) {
            ranges.append(start..<(start + count))
            start += count
        }
        return ranges
    }

    static func tileSide(rowCount: Int, maxWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        guard rowCount > 0 else { return 1 }
        let totalSpacing = CGFloat(rowCount - 1) * spacing
        return max(1, (maxWidth - totalSpacing) / CGFloat(rowCount))
    }

    static func gridHeight(totalCount: Int, maxWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        let rows = rowCounts(totalCount: totalCount)
        guard !rows.isEmpty else { return 0 }
        let tileHeights = rows.reduce(0) { partial, count in
            partial + tileSide(rowCount: count, maxWidth: maxWidth, spacing: spacing)
        }
        return tileHeights + CGFloat(rows.count - 1) * spacing
    }
}

nonisolated enum MediaDurationLabel {
    /// Stands in for a duration that is not known yet — an audio attachment still downloading,
    /// whose length only its payload can reveal. Deliberately unlocalized: it is the digits of
    /// `string(for:)` blanked out, so it has to occupy the same monospaced slot.
    static let placeholder = "--:--"

    static func string(for durationSeconds: Double) -> String {
        // The duration can be peer-derived (see MediaWaveformAnalyzer), so it may be
        // NaN, ±Infinity, negative, or larger than Int.max. The trapping Int(_:)
        // initializer would crash on non-finite or out-of-range values, so clamp the
        // floored duration into the representable range before converting.
        let total: Int
        if durationSeconds.isFinite {
            let flooredSeconds = durationSeconds.rounded(.down)
            if flooredSeconds <= 0 {
                total = 0
            } else if flooredSeconds >= Double(Int.max) {
                total = Int.max
            } else {
                total = Int(flooredSeconds)
            }
        } else {
            total = 0
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum MediaDownloadState: Equatable {
    case idle
    case loading
    case loaded(MessageMediaDownload)
    case failed(String)

    /// The case name alone, for the public half of a download-failure log line.
    ///
    /// Spelled out rather than derived with `String(describing:)`, which would carry the associated
    /// values along with the case: `.failed`'s reason is the core's own text and `.loaded`'s payload
    /// is the file, and neither belongs in a `.public` field. A new case has to be named here, which
    /// is the point.
    var logLabel: String {
        switch self {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded: "loaded"
        case .failed: "failed"
        }
    }
}

/// Blossom upload status for one composer attachment. Attachments upload as soon as they are
/// staged so the blob is usually already up by the time Send is pressed — but the upload never
/// gates Send: an unfinished one is handed to the outgoing message and awaited there
/// (`PendingOutgoingMediaMessage`).
nonisolated enum PendingMediaUploadState: Hashable, Sendable {
    case uploading
    case uploaded(MediaAttachmentReferenceFfi)
    case failed

    /// The published reference, once the blob is on Blossom. `nil` while in flight or after a
    /// failure, which is exactly the "not sendable yet" condition the composer gates on.
    var reference: MediaAttachmentReferenceFfi? {
        guard case .uploaded(let reference) = self else { return nil }
        return reference
    }

    var isUploaded: Bool { reference != nil }
}

/// Where a sent-but-not-yet-published media message has got to.
///
/// Both in-flight cases render identically — one spinner over the whole bubble, never a badge per
/// attachment — because the user pressed Send once and is waiting for one thing to happen. They
/// stay distinct so a retry knows whether it has to re-upload or only re-publish.
nonisolated enum PendingOutgoingMediaMessageState: Hashable, Sendable {
    case uploading
    case publishing
    case failed

    var isInFlight: Bool {
        self != .failed
    }
}

/// A media message the user has already sent, still on its way to the relay.
///
/// Send does not wait for Blossom: pressing it empties the composer and parks the attachments
/// here, where the bubble renders them from the plaintext we are still holding while the uploads
/// finish. This is the row the transcript shows in the gap between "sent" and "published".
nonisolated struct PendingOutgoingMediaMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let attachments: [PendingMediaAttachment]
    let caption: String
    let createdAt: Date
    var state: PendingOutgoingMediaMessageState
    /// The plaintext digests of this message's blobs, stamped once every upload has handed back a
    /// reference and empty until then.
    ///
    /// The published row carries the same digests, which is what lets the transcript retire this
    /// bubble the moment the row it became is on screen. It has to: the core commits an own send
    /// locally *inside* the publish call, so the real row can arrive through the timeline
    /// subscription while the relay round-trip is still in flight — and until then both rendered.
    var publishedPlaintextSHAs: Set<String> = []

    init(
        id: UUID = UUID(),
        attachments: [PendingMediaAttachment],
        caption: String,
        createdAt: Date = Date(),
        state: PendingOutgoingMediaMessageState = .uploading
    ) {
        self.id = id
        self.attachments = attachments
        self.caption = caption
        self.createdAt = createdAt
        self.state = state
    }

    /// Attachments that render as grid tiles, matching `MessageItem.visualMediaAttachments` so a
    /// pending bubble and the published one it becomes lay out the same way.
    var visualAttachments: [PendingMediaAttachment] {
        attachments.filter { $0.kind == .image || $0.kind == .video }
    }

    var nonvisualAttachments: [PendingMediaAttachment] {
        attachments.filter { $0.kind == .audio || $0.kind == .file }
    }

    /// The one audio attachment that carries this message's loading state inside its own row, or
    /// `nil` when the bubble has to fall back to the centered overlay.
    ///
    /// An audio row has a natural home for progress — the circular well the play button lands in,
    /// which `MessageAudioRow` reserves at the same size whatever the row's state. A grid of tiles
    /// and a document row do not, so a message carrying either keeps the overlay; lighting up both
    /// treatments would give one Send press two loading indicators.
    var inlineLoadingAudioAttachment: PendingMediaAttachment? {
        guard attachments.count == 1, let only = attachments.first, only.kind == .audio else { return nil }
        return only
    }
}

/// Where a sent-but-not-yet-published text message has got to.
///
/// Text has no upload leg, so this looks thinner than the media states — but it carries a wait
/// media does not: `.queued`. Sends in one conversation publish in the order Send was pressed,
/// which means a message can be waiting on the one ahead of it without having reached the core at
/// all. While it is there, nothing else on screen represents it: the composer emptied on the Send
/// press and the core has no row to project yet.
nonisolated enum PendingOutgoingTextMessageState: Hashable, Sendable {
    /// Waiting for the send ahead of it in this conversation. This row is the only thing carrying
    /// the message — a relay that takes the predecessor thirty seconds to give up on used to be
    /// thirty seconds with the message nowhere at all.
    case queued
    /// Handed to the core, which commits and projects an own send locally *before* it publishes,
    /// so the real row normally takes this one's place within a frame or two.
    case publishing
    /// The publish failed and the core retracted its local projection, leaving this row the only
    /// copy of what the user wrote. It keeps the text and owns the retry.
    case failed

    var isInFlight: Bool {
        self != .failed
    }
}

/// A text message the user has already sent, still on its way to the relay.
///
/// The counterpart of `PendingOutgoingMediaMessage`, and here for the same reason: Send empties the
/// composer without waiting, so something has to hold the message in the meantime. Media always
/// needed it for the uploads; text needs it for the two windows where the core cannot speak for the
/// message — before the send reaches it, and after a failed publish rolls its projection back.
nonisolated struct PendingOutgoingTextMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Exactly the bytes handed to the core: mentions already canonicalized, ends already trimmed.
    /// Also how the published row is recognized, the way a media message uses its plaintext
    /// digests — text is its own digest.
    let text: String
    /// Carried so a retry re-sends the message as the reply it was, rather than as a loose message
    /// under the one it was answering.
    let replyContext: MessageReplyContext?
    let createdAt: Date
    var state: PendingOutgoingTextMessageState
    /// How many own rows in this transcript already carried `text` when the publish began, or nil
    /// until it has begun.
    ///
    /// The retirement key, and the reason it is a count rather than a flag: the core commits an own
    /// send locally inside the publish call, so the real row can arrive while the round-trip is
    /// still going and both would render at once. Comparing against the count taken *before* the
    /// publish is what distinguishes "the row for this message has arrived" from "this conversation
    /// already contained an identical message" — a flag would hide the second `ok` of a
    /// conversation behind the first one.
    var ownBodyCountBeforePublish: Int?

    init(
        id: UUID = UUID(),
        text: String,
        replyContext: MessageReplyContext? = nil,
        createdAt: Date = Date(),
        state: PendingOutgoingTextMessageState = .queued
    ) {
        self.id = id
        self.text = text
        self.replyContext = replyContext
        self.createdAt = createdAt
        self.state = state
    }
}

/// One row in the transcript's pending tail, whichever kind of send produced it.
///
/// The two pending lists are separate — they wait on entirely different things — but they share one
/// stretch of transcript, so they cannot each render their own `ForEach`: that orders every text
/// row before every media row, and a photo sent before a sentence would appear after it.
nonisolated enum PendingOutgoingMessageRow: Identifiable, Hashable, Sendable {
    case text(PendingOutgoingTextMessage)
    case media(PendingOutgoingMediaMessage)

    var id: UUID {
        switch self {
        case .text(let message): message.id
        case .media(let message): message.id
        }
    }

    var createdAt: Date {
        switch self {
        case .text(let message): message.createdAt
        case .media(let message): message.createdAt
        }
    }
}

nonisolated struct PendingMediaAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let fileName: String
    let mediaType: String
    let data: Data
    /// SHA-256 of `data`, the digest a media reference carries as `plaintextSha256`.
    ///
    /// Computed once here rather than on demand: it is how a published row is recognized as one of
    /// *these* bytes — by `MessageBubble` looking for a plaintext it already holds, and by the
    /// placeholder's own retirement — and both would otherwise rehash megabytes inside a render.
    let plaintextSHA256: String
    let dim: String?
    let thumbhash: String?
    let durationSeconds: Double?
    let waveformSamples: [CGFloat]
    /// Set only for audio the user recorded here, in the composer. Such a recording is not a
    /// staged media file: it takes the composer over on its own and is sent as an audio-only
    /// message, so it never mixes with text or other attachments. Audio *files* the user
    /// attaches stay ordinary media and leave this `false`.
    let isVoiceMessage: Bool

    init(
        id: UUID = UUID(),
        fileName: String,
        mediaType: String,
        data: Data,
        dim: String?,
        thumbhash: String? = nil,
        durationSeconds: Double? = nil,
        waveformSamples: [CGFloat] = [],
        isVoiceMessage: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.mediaType = mediaType
        self.data = data
        self.plaintextSHA256 = MessageMediaDiskCacheKey.plaintextDigest(for: data)
        self.dim = dim
        self.thumbhash = thumbhash
        self.durationSeconds = durationSeconds
        self.waveformSamples = waveformSamples
        self.isVoiceMessage = isVoiceMessage
    }

    var kind: MessageMediaKind {
        OutgoingMediaAttachmentPolicy.kind(mediaType: mediaType, fileName: fileName)
    }

    var uploadRequest: MediaUploadAttachmentRequestFfi {
        MediaUploadAttachmentRequestFfi(
            fileName: fileName,
            mediaType: mediaType,
            plaintext: data,
            dim: dim,
            thumbhash: thumbhash
        )
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    var durationLabel: String? {
        guard let durationSeconds else { return nil }
        return MediaDurationLabel.string(for: durationSeconds)
    }
}

nonisolated struct VoiceRecordingResult: Sendable {
    let url: URL
    let fileName: String
    let durationSeconds: Double
    let waveformSamples: [CGFloat]
}

nonisolated enum OutgoingMediaAttachmentPolicy {
    /// Recognizes a draft attachment as audio recorded in this composer.
    ///
    /// A persisted draft crosses the FFI boundary as a plain media record with no "recorded
    /// here" flag, so a restored recording is identified by the exact name
    /// `MediaPlaybackTempStore.prepareVoiceRecordingFile` gave it — `voice-<UUID>.m4a`.
    /// Requiring the UUID stem keeps a user's own `voice-notes.m4a` an ordinary attachment.
    static func isVoiceRecordingFileName(_ fileName: String, mediaType: String) -> Bool {
        guard supportedAudioMediaTypes.contains(mediaType.lowercased()) else { return false }
        let name = fileName.lowercased()
        guard name.hasSuffix(".m4a") else { return false }
        let stem = name.dropLast(".m4a".count)
        guard stem.hasPrefix("voice-") else { return false }
        return UUID(uuidString: String(stem.dropFirst("voice-".count))) != nil
    }

    static let supportedAudioMediaTypes: Set<String> = [
        "audio/aac",
        "audio/mp4",
        "audio/mpeg",
        "audio/wav",
        "audio/x-m4a",
        "audio/x-wav",
    ]

    static let supportedVideoMediaTypes: Set<String> = [
        "video/mp4",
        "video/quicktime",
    ]

    static let supportedDocumentMediaTypes: Set<String> = [
        "application/json",
        "application/msword",
        "application/pdf",
        "application/rtf",
        "application/vnd.ms-excel",
        "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "text/csv",
        "text/json",
        "text/plain",
        "text/rtf",
    ]

    static let supportedDocumentExtensions: Set<String> = [
        "csv",
        "doc",
        "docx",
        "json",
        "pdf",
        "ppt",
        "pptx",
        "rtf",
        "txt",
        "xls",
        "xlsx",
    ]

    static let fileImporterAllowedTypes: [UTType] = {
        var types: [UTType] = [.image, .movie, .audio, .pdf, .plainText, .rtf, .commaSeparatedText, .json]
        for ext in supportedDocumentExtensions.sorted() {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }()

    static func canonicalMediaType(_ mediaType: String) -> String {
        let base =
            mediaType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? mediaType
        let canonical = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return canonical == "image/jpg" ? "image/jpeg" : canonical
    }

    static func isDecodableImageMediaType(_ mediaType: String) -> Bool {
        let canonical = canonicalMediaType(mediaType)
        guard canonical.hasPrefix("image/") else { return false }
        return canonical != "image/svg+xml"
    }

    static func isSupported(mediaType: String, fileName: String? = nil) -> Bool {
        let canonical = canonicalMediaType(mediaType)
        if isDecodableImageMediaType(canonical) { return true }
        if supportedVideoMediaTypes.contains(canonical) { return true }
        if supportedAudioMediaTypes.contains(canonical) { return true }
        if supportedDocumentMediaTypes.contains(canonical) { return true }
        if let fileName,
            let fileExtension = fileName.split(separator: ".").last.map(String.init)
        {
            return supportedDocumentExtensions.contains(fileExtension.lowercased())
        }
        return false
    }

    static func mediaType(typeIdentifier: String?, fileName: String?, fallbackKind: MessageMediaKind?) -> String? {
        if let typeIdentifier,
            let type = UTType(typeIdentifier),
            let mediaType = type.preferredMIMEType
        {
            return canonicalMediaType(mediaType)
        }
        if let fileName,
            let fileExtension = fileName.split(separator: ".").last.map(String.init),
            let mediaType = mediaType(forFileExtension: fileExtension)
        {
            return canonicalMediaType(mediaType)
        }
        switch fallbackKind {
        case .video:
            return "video/mp4"
        case .audio:
            return "audio/mp4"
        case .image:
            return "image/jpeg"
        case .file, .none:
            return nil
        }
    }

    /// App-controlled extension-to-MIME mapping used for scratch suffix inference and as
    /// the first lookup in `mediaType(forFileExtension:)`. Extensions outside this list
    /// must not influence scratch paths even when UTType recognizes them.
    private static func allowlistedMediaType(forFileExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "gif":
            return "image/gif"
        case "heic":
            return "image/heic"
        case "jpeg", "jpg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "webp":
            return "image/webp"
        case "aac":
            return "audio/aac"
        case "m4a":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "mov":
            return "video/quicktime"
        case "mp4", "m4v":
            return "video/mp4"
        case "txt":
            return "text/plain"
        case "csv":
            return "text/csv"
        case "json":
            return "application/json"
        case "rtf":
            return "application/rtf"
        case "pdf":
            return "application/pdf"
        case "doc":
            return "application/msword"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls":
            return "application/vnd.ms-excel"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt":
            return "application/vnd.ms-powerpoint"
        case "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default:
            return nil
        }
    }

    static func mediaType(forFileExtension fileExtension: String) -> String? {
        if let allowlisted = allowlistedMediaType(forFileExtension: fileExtension) {
            return allowlisted
        }
        return UTType(filenameExtension: fileExtension.lowercased())?.preferredMIMEType
    }

    static func fileExtension(for mediaType: String, fileName: String? = nil) -> String {
        if let fileName,
            let ext = fileName.split(separator: ".").last.map(String.init),
            !ext.isEmpty
        {
            return ext.lowercased()
        }
        switch canonicalMediaType(mediaType) {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/heic":
            return "heic"
        case "image/webp":
            return "webp"
        case "video/mp4":
            return "mp4"
        case "video/quicktime":
            return "mov"
        case "audio/aac", "audio/mp4", "audio/x-m4a":
            return "m4a"
        case "audio/mpeg":
            return "mp3"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "application/pdf":
            return "pdf"
        case "application/json", "text/json":
            return "json"
        case "application/rtf", "text/rtf":
            return "rtf"
        case "text/csv":
            return "csv"
        case "text/plain":
            return "txt"
        case "application/msword":
            return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
            return "docx"
        case "application/vnd.ms-excel":
            return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
            return "xlsx"
        case "application/vnd.ms-powerpoint":
            return "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
            return "pptx"
        default:
            return "bin"
        }
    }

    /// Canonical scratch-file suffix for decrypted media handoff.
    ///
    /// Peer `fileName` is consulted only when `mediaType` is empty or generic
    /// (`application/octet-stream`). In that case an allowlisted extension maps to a known
    /// media type and the returned suffix is always app-controlled; peer basename or
    /// extension text is never copied into the path.
    static func scratchFileExtension(for mediaType: String, fileName: String?) -> String {
        let canonical = canonicalMediaType(mediaType)
        if shouldInferKindFromFileName(canonicalMediaType: canonical),
            let fileName,
            let fileExtension = fileName.split(separator: ".").last.map(String.init),
            let resolved = allowlistedMediaType(forFileExtension: fileExtension)
        {
            return Self.fileExtension(for: canonicalMediaType(resolved))
        }
        return fileExtension(for: canonical)
    }

    static func kind(mediaType: String, fileName: String? = nil) -> MessageMediaKind {
        let canonical = canonicalMediaType(mediaType)
        if let kind = kind(canonicalMediaType: canonical) { return kind }
        // Only generic/unknown media types should defer to the filename. Concrete
        // document types like `application/pdf` must remain authoritative even if a
        // mismatched extension is supplied.
        if shouldInferKindFromFileName(canonicalMediaType: canonical),
            let fileName,
            let fileExtension = fileName.split(separator: ".").last.map(String.init),
            let resolved = Self.mediaType(forFileExtension: fileExtension),
            let kind = kind(canonicalMediaType: canonicalMediaType(resolved))
        {
            return kind
        }
        return .file
    }

    private static func kind(canonicalMediaType canonical: String) -> MessageMediaKind? {
        if isDecodableImageMediaType(canonical) { return .image }
        if canonical.hasPrefix("video/") { return .video }
        if canonical.hasPrefix("audio/") { return .audio }
        return nil
    }

    private static func shouldInferKindFromFileName(canonicalMediaType canonical: String) -> Bool {
        canonical.isEmpty || canonical == "application/octet-stream"
    }
}

nonisolated struct OutgoingMediaPasteboardAttachment: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case fileURL(URL)
        case imageData(Data, typeIdentifier: String?)
    }

    let payload: Payload
}

@MainActor
enum OutgoingMediaPasteboardReader {
    private static let preferredImagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.png.identifier),
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.tiff.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
    ]
    private static let legacyFilenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static func attachments(from pasteboard: NSPasteboard) -> [OutgoingMediaPasteboardAttachment] {
        let itemAttachments = pasteboard.pasteboardItems?.compactMap(attachment(from:)) ?? []
        if !itemAttachments.isEmpty {
            return itemAttachments
        }
        let fileAttachments = legacyFileURLs(from: pasteboard)
            .map { OutgoingMediaPasteboardAttachment(payload: .fileURL($0)) }
        if !fileAttachments.isEmpty {
            return fileAttachments
        }
        if let imageData = imageDataFromPasteboardFallback(pasteboard) {
            return [
                OutgoingMediaPasteboardAttachment(
                    payload: .imageData(imageData, typeIdentifier: UTType.tiff.identifier)
                )
            ]
        }
        return []
    }

    private static func attachment(from item: NSPasteboardItem) -> OutgoingMediaPasteboardAttachment? {
        if let url = fileURL(from: item) {
            return OutgoingMediaPasteboardAttachment(payload: .fileURL(url))
        }
        if let image = imageData(from: item) {
            return OutgoingMediaPasteboardAttachment(
                payload: .imageData(image.data, typeIdentifier: image.typeIdentifier)
            )
        }
        return nil
    }

    private static func fileURL(from item: NSPasteboardItem) -> URL? {
        guard let value = item.string(forType: .fileURL),
            let url = URL(string: value),
            url.isFileURL
        else {
            return nil
        }
        return url
    }

    private static func imageData(from item: NSPasteboardItem) -> (data: Data, typeIdentifier: String?)? {
        for type in orderedImagePasteboardTypes(from: item) {
            guard let data = item.data(forType: type), !data.isEmpty else { continue }
            return (data, type.rawValue)
        }
        return nil
    }

    private static func orderedImagePasteboardTypes(from item: NSPasteboardItem) -> [NSPasteboard.PasteboardType] {
        var ordered = preferredImagePasteboardTypes.filter { item.types.contains($0) }
        for type in item.types where !ordered.contains(type) && isImagePasteboardType(type) {
            ordered.append(type)
        }
        return ordered
    }

    private static func isImagePasteboardType(_ type: NSPasteboard.PasteboardType) -> Bool {
        UTType(type.rawValue)?.conforms(to: .image) == true
    }

    private static func legacyFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let paths = pasteboard.propertyList(forType: legacyFilenamesPasteboardType) as? [String] else {
            return []
        }
        return paths.map(URL.init(fileURLWithPath:)).filter(\.isFileURL)
    }

    private static func imageDataFromPasteboardFallback(_ pasteboard: NSPasteboard) -> Data? {
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        return image.tiffRepresentation
    }
}

nonisolated enum OutgoingMediaDraftProcessor {
    static let maxAttachmentCount = 10
    static let maxLongEdge: CGFloat = 2048
    static let maxImageAttachmentBytes = 10 * 1024 * 1024
    static let maxAttachmentBytes = 50 * 1024 * 1024

    enum Failure: LocalizedError {
        case unsupportedImage
        case unsupportedAttachment
        case encodingFailed
        case attachmentTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedImage:
                return L10n.string("That image could not be opened.")
            case .unsupportedAttachment:
                return L10n.string("That file type is not supported.")
            case .encodingFailed:
                return L10n.string("That attachment could not be prepared.")
            case .attachmentTooLarge:
                return L10n.string("That attachment is too large to send.")
            }
        }
    }

    private struct SendableAttachment: @unchecked Sendable {
        let attachment: PendingMediaAttachment
    }

    static func preparedAttachment(fromFileURL url: URL) async throws -> PendingMediaAttachment {
        let prepared = try await Task.detached(priority: .userInitiated) { () async throws -> SendableAttachment in
            let resourceValues = try url.resourceValues(forKeys: [
                .contentTypeKey, .nameKey, .fileSizeKey, .isDirectoryKey,
            ])
            guard resourceValues.isDirectory != true else {
                throw Failure.unsupportedAttachment
            }
            if let fileSize = resourceValues.fileSize, fileSize > maxAttachmentBytes {
                throw Failure.attachmentTooLarge(fileSize)
            }
            let data = try readAttachmentData(from: url)
            return try await SendableAttachment(
                attachment: preparedAttachmentValue(
                    from: data,
                    fileName: resourceValues.name ?? url.lastPathComponent,
                    typeIdentifier: resourceValues.contentType?.identifier
                ))
        }.value
        return prepared.attachment
    }

    static func preparedAttachment(
        fromPastedImageData data: Data,
        typeIdentifier: String?
    ) async throws -> PendingMediaAttachment {
        let prepared = try await Task.detached(priority: .userInitiated) { () async throws -> SendableAttachment in
            let attachment = try await preparedAttachmentValue(
                from: data,
                fileName: "pasted-image-\(Int(Date().timeIntervalSince1970)).jpg",
                typeIdentifier: typeIdentifier
            )
            return SendableAttachment(attachment: attachment)
        }.value
        return prepared.attachment
    }

    private static func readAttachmentData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Read at most one byte past the cap so URLs without fileSize cannot force
        // unbounded buffering before the raw-size guard runs.
        let data = try handle.read(upToCount: maxAttachmentBytes + 1) ?? Data()
        try enforceRawAttachmentSize(data)
        return data
    }

    static func preparedVoiceAttachment(from recording: VoiceRecordingResult) async throws -> PendingMediaAttachment {
        let prepared = try await Task.detached(priority: .userInitiated) { () throws -> SendableAttachment in
            defer { try? FileManager.default.removeItem(at: recording.url) }
            let data = try Data(contentsOf: recording.url)
            guard data.count <= maxAttachmentBytes else {
                throw Failure.attachmentTooLarge(data.count)
            }
            return SendableAttachment(
                attachment: PendingMediaAttachment(
                    fileName: sanitizedFileName(
                        recording.fileName,
                        fallbackStem: "voice-\(Int(Date().timeIntervalSince1970))",
                        fallbackExtension: "m4a"
                    ),
                    mediaType: "audio/mp4",
                    data: data,
                    dim: nil,
                    durationSeconds: recording.durationSeconds,
                    // Kept at the resolution the meter recorded it at, not folded down to the
                    // playback waveform's buckets: the staged recording draws one bar per 40 ms of
                    // sound, and it has to have a level per bar to draw.
                    waveformSamples: MediaWaveformAnalyzer.normalized(
                        recording.waveformSamples,
                        count: VoiceRecordingWaveform.storedSampleCount(
                            forMeteredCount: recording.waveformSamples.count
                        )
                    ),
                    isVoiceMessage: true
                ))
        }.value
        return prepared.attachment
    }

    private static func preparedAttachmentValue(
        from data: Data,
        fileName: String?,
        typeIdentifier: String?
    ) async throws -> PendingMediaAttachment {
        // Keep the raw-size invariant in the common funnel too, so no caller can
        // branch into image decoding with unbounded data.
        try enforceRawAttachmentSize(data)
        let kind = kind(for: typeIdentifier, fileName: fileName)
        if kind == .image {
            return try imageAttachment(from: data, fileName: fileName)
        }
        guard
            let mediaType = OutgoingMediaAttachmentPolicy.mediaType(
                typeIdentifier: typeIdentifier,
                fileName: fileName,
                fallbackKind: kind
            ),
            OutgoingMediaAttachmentPolicy.isSupported(mediaType: mediaType, fileName: fileName)
        else {
            throw Failure.unsupportedAttachment
        }
        let videoDim = kind == .video ? await MediaVideoMetadata.dim(from: data, mediaType: mediaType) : nil
        return try genericAttachment(
            from: data,
            fileName: fileName,
            mediaType: mediaType,
            kind: kind,
            videoDim: videoDim
        )
    }

    private static func enforceRawAttachmentSize(_ data: Data) throws {
        guard data.count <= maxAttachmentBytes else {
            throw Failure.attachmentTooLarge(data.count)
        }
    }

    private static func kind(for typeIdentifier: String?, fileName: String?) -> MessageMediaKind? {
        if let typeIdentifier, let type = UTType(typeIdentifier) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .pdf) || type.conforms(to: .text) {
                return .file
            }
        }
        if let fileName,
            let fileExtension = fileName.split(separator: ".").last.map(String.init),
            let mediaType = OutgoingMediaAttachmentPolicy.mediaType(forFileExtension: fileExtension)
        {
            return OutgoingMediaAttachmentPolicy.kind(mediaType: mediaType, fileName: fileName)
        }
        return nil
    }

    private static func genericAttachment(
        from data: Data,
        fileName: String?,
        mediaType: String,
        kind: MessageMediaKind?,
        videoDim: String?
    ) throws -> PendingMediaAttachment {
        let sanitizedName = sanitizedFileName(
            fileName,
            fallbackStem: kind == .audio
                ? "audio-\(Int(Date().timeIntervalSince1970))" : "attachment-\(Int(Date().timeIntervalSince1970))",
            fallbackExtension: OutgoingMediaAttachmentPolicy.fileExtension(for: mediaType, fileName: fileName)
        )
        let audioMetadata = kind == .audio ? MediaWaveformAnalyzer.metadata(from: data, mediaType: mediaType) : nil
        return PendingMediaAttachment(
            fileName: sanitizedName,
            mediaType: mediaType,
            data: data,
            dim: videoDim,
            durationSeconds: audioMetadata?.durationSeconds,
            waveformSamples: audioMetadata?.samples ?? []
        )
    }

    private static func imageAttachment(from data: Data, fileName: String?) throws -> PendingMediaAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw Failure.unsupportedImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxLongEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unsupportedImage
        }
        let encoded = try encodeJPEG(image)
        guard encoded.count <= maxImageAttachmentBytes else {
            throw Failure.attachmentTooLarge(encoded.count)
        }
        return PendingMediaAttachment(
            fileName: sanitizedImageFileName(fileName),
            mediaType: "image/jpeg",
            data: encoded,
            dim: "\(image.width)x\(image.height)"
        )
    }

    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        for quality in [0.86, 0.74, 0.62, 0.52] as [CGFloat] {
            if let data = jpegData(from: image, quality: quality), data.count <= maxImageAttachmentBytes {
                return data
            }
        }
        throw Failure.encodingFailed
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func sanitizedImageFileName(_ fileName: String?) -> String {
        let name = sanitizedFileName(
            fileName,
            fallbackStem: "photo-\(Int(Date().timeIntervalSince1970))",
            fallbackExtension: "jpg"
        )
        let lower = name.lowercased()
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") {
            return name
        }
        return "\(name).jpg"
    }

    private static func sanitizedFileName(
        _ fileName: String?,
        fallbackStem: String,
        fallbackExtension: String
    ) -> String {
        let base = fileName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .last
            .map(String.init)
        let stem = base?
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        guard let stem, !stem.isEmpty else {
            return "\(fallbackStem).\(fallbackExtension)"
        }
        let capped = String(stem.prefix(120))
        if capped.contains(".") {
            return capped
        }
        return "\(capped).\(fallbackExtension)"
    }
}

nonisolated enum MediaWaveformAnalyzer {
    struct Metadata: Equatable, Sendable {
        let durationSeconds: Double?
        let samples: [CGFloat]
    }

    static let sampleCount = 36
    static let fallbackSamples: [CGFloat] = fallback()
    static let chunkFrameCapacityCeiling: AVAudioFrameCount = 65_536
    static let maxChunkBytes: Int = 4 * 1024 * 1024
    static let maxChannelCount: AVAudioChannelCount = 32
    static let maxAnalyzedFrames: AVAudioFramePosition = 48_000 * 60 * 30

    static func normalized(_ values: [CGFloat], count: Int = sampleCount) -> [CGFloat] {
        let bounded = values.map { min(1, max(0.05, $0)) }
        guard !bounded.isEmpty else { return fallback(count: count) }
        if bounded.count == count { return bounded }
        let bucketSize = Double(bounded.count) / Double(count)
        return (0..<count).map { index in
            let start = Int((Double(index) * bucketSize).rounded(.down))
            let end = min(bounded.count, Int((Double(index + 1) * bucketSize).rounded(.up)))
            let slice = bounded[max(0, start)..<max(start + 1, end)]
            return max(0.08, slice.reduce(0, +) / CGFloat(slice.count))
        }
    }

    static func fallback(count: Int = sampleCount) -> [CGFloat] {
        (0..<count).map { index in
            let phase = CGFloat(index % 9) / 8
            return 0.24 + sin(phase * .pi) * 0.48
        }
    }

    static func chunkFrameCapacity(
        channelCount: AVAudioChannelCount,
        bytesPerSample: Int
    ) -> AVAudioFrameCount {
        let channels = max(1, Int(channelCount))
        let sampleBytes = max(1, bytesPerSample)
        let perFrameBytes = channels * sampleBytes
        let framesInBudget = max(1, maxChunkBytes / perFrameBytes)
        return AVAudioFrameCount(min(framesInBudget, Int(chunkFrameCapacityCeiling)))
    }

    static func analyzedFrameCount(totalFrames: AVAudioFramePosition) -> AVAudioFramePosition {
        guard totalFrames > 0 else { return 0 }
        return min(totalFrames, maxAnalyzedFrames)
    }

    static func nextChunkFrameCount(
        analyzedFrames: AVAudioFramePosition,
        framesProcessed: AVAudioFramePosition,
        chunkCapacity: AVAudioFrameCount
    ) -> AVAudioFrameCount {
        let remaining = analyzedFrames - framesProcessed
        guard remaining > 0 else { return 0 }
        return AVAudioFrameCount(min(AVAudioFramePosition(chunkCapacity), remaining))
    }

    static func bucketIndex(
        forFrame frame: AVAudioFramePosition,
        analyzedFrames: AVAudioFramePosition,
        bucketCount: Int = sampleCount
    ) -> Int {
        guard analyzedFrames > 0, bucketCount > 0 else { return 0 }
        let index = Int(frame * AVAudioFramePosition(bucketCount) / analyzedFrames)
        return min(bucketCount - 1, max(0, index))
    }

    static func metadata(from data: Data, mediaType: String) -> Metadata {
        TemporaryOutgoingMediaFile.withURL(
            data: data,
            fileExtension: OutgoingMediaAttachmentPolicy.fileExtension(for: mediaType),
            fallback: Metadata(durationSeconds: nil, samples: fallback())
        ) { url in
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let sampleRate = format.sampleRate
                let totalFrames = file.length
                let duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : nil

                let analyzedFrames = analyzedFrameCount(totalFrames: totalFrames)
                guard analyzedFrames > 0 else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                let channelCount = format.channelCount
                guard channelCount > 0, channelCount <= maxChannelCount else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                let bitsPerChannel = Int(format.streamDescription.pointee.mBitsPerChannel)
                let bytesPerSample =
                    bitsPerChannel > 0
                    ? (bitsPerChannel + 7) / 8
                    : MemoryLayout<Float>.size
                let chunkCapacity = chunkFrameCapacity(
                    channelCount: channelCount,
                    bytesPerSample: bytesPerSample
                )

                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                var peaks = [Float](repeating: 0, count: sampleCount)
                var counts = [Int](repeating: 0, count: sampleCount)
                var framesProcessed: AVAudioFramePosition = 0

                while true {
                    let toRead = nextChunkFrameCount(
                        analyzedFrames: analyzedFrames,
                        framesProcessed: framesProcessed,
                        chunkCapacity: chunkCapacity
                    )
                    guard toRead > 0 else { break }
                    buffer.frameLength = 0
                    try file.read(into: buffer, frameCount: toRead)
                    let read = Int(buffer.frameLength)
                    guard read > 0, let channel = buffer.floatChannelData?[0] else { break }
                    for offset in 0..<read {
                        let bucket = bucketIndex(
                            forFrame: framesProcessed + AVAudioFramePosition(offset),
                            analyzedFrames: analyzedFrames
                        )
                        let value = abs(channel[offset])
                        if value > peaks[bucket] { peaks[bucket] = value }
                        counts[bucket] += 1
                    }
                    framesProcessed += AVAudioFramePosition(read)
                }

                guard framesProcessed > 0 else {
                    return Metadata(durationSeconds: duration, samples: fallback())
                }

                let samples = (0..<sampleCount).map { index -> CGFloat in
                    guard counts[index] > 0 else { return 0.08 }
                    return CGFloat(min(1, max(0.05, sqrt(peaks[index]))))
                }
                return Metadata(durationSeconds: duration, samples: normalized(samples))
            } catch {
                return Metadata(durationSeconds: nil, samples: fallback())
            }
        }
    }
}

nonisolated final class MessageAudioMetadataCache: @unchecked Sendable {
    typealias Analyzer = @Sendable (DownloadedMediaPayload, String) -> MediaWaveformAnalyzer.Metadata

    static let shared = MessageAudioMetadataCache()

    private let lock = NSLock()
    private let entryLimit: Int
    private let analyzer: Analyzer
    private var cached: [String: MediaWaveformAnalyzer.Metadata] = [:]
    private var accessOrder: [String] = []
    private var inFlight: [String: Task<MediaWaveformAnalyzer.Metadata, Never>] = [:]
    private var generation = 0

    init(
        entryLimit: Int = 128,
        analyzer: @escaping Analyzer = { payload, mediaType in
            MediaWaveformAnalyzer.metadata(from: payload.data, mediaType: mediaType)
        }
    ) {
        self.entryLimit = max(1, entryLimit)
        self.analyzer = analyzer
    }

    func metadata(for download: MessageMediaDownload) async -> MediaWaveformAnalyzer.Metadata {
        await metadata(for: download.payload, mediaType: download.mediaType)
    }

    func metadata(
        for payload: DownloadedMediaPayload,
        mediaType: String
    ) async -> MediaWaveformAnalyzer.Metadata {
        let key = payload.id
        let task: Task<MediaWaveformAnalyzer.Metadata, Never>
        let taskGeneration: Int

        // Scoped `withLock` rather than manual lock/unlock: `lock()`/`unlock()` are unavailable
        // from async contexts (a lock must not be held across a suspension). The critical
        // sections here are fully synchronous — the `await`s happen *outside* the lock — so the
        // behavior is unchanged; resolve what to do under the lock, then suspend without it.
        enum Lookup {
            case cached(MediaWaveformAnalyzer.Metadata)
            case awaitInFlight(Task<MediaWaveformAnalyzer.Metadata, Never>)
            case started(Task<MediaWaveformAnalyzer.Metadata, Never>, generation: Int)
        }

        let lookup: Lookup = lock.withLock {
            if let value = cached[key] {
                markRecentlyUsed(key)
                return .cached(value)
            }
            if let existing = inFlight[key] {
                return .awaitInFlight(existing)
            }
            let started = Task.detached(priority: .utility) { [analyzer] in
                analyzer(payload, mediaType)
            }
            inFlight[key] = started
            return .started(started, generation: generation)
        }

        switch lookup {
        case .cached(let value):
            return value
        case .awaitInFlight(let existing):
            return await existing.value
        case .started(let started, let gen):
            task = started
            taskGeneration = gen
        }

        let value = await task.value

        lock.withLock {
            if generation == taskGeneration {
                inFlight[key] = nil
                cached[key] = value
                markRecentlyUsed(key)
                trimIfNeeded()
            }
        }

        return value
    }

    func clear() {
        let tasks: [Task<MediaWaveformAnalyzer.Metadata, Never>]
        lock.lock()
        generation += 1
        cached.removeAll()
        accessOrder.removeAll()
        tasks = Array(inFlight.values)
        inFlight.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    #if DEBUG
        var cachedEntryCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return cached.count
        }
    #endif

    private func markRecentlyUsed(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimIfNeeded() {
        while cached.count > entryLimit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            cached[oldest] = nil
        }
    }
}

nonisolated private enum MediaVideoMetadata {
    static func dim(from data: Data, mediaType: String) async -> String? {
        await TemporaryOutgoingMediaFile.withURL(
            data: data,
            fileExtension: OutgoingMediaAttachmentPolicy.fileExtension(for: mediaType),
            fallback: nil as String?
        ) { url in
            let asset = AVURLAsset(url: url)
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    return nil
                }
                async let naturalSize = track.load(.naturalSize)
                async let preferredTransform = track.load(.preferredTransform)
                let (size, transform) = try await (naturalSize, preferredTransform)
                let transformed = size.applying(transform)
                let width = max(1, Int(abs(transformed.width).rounded()))
                let height = max(1, Int(abs(transformed.height).rounded()))
                return "\(width)x\(height)"
            } catch {
                return nil
            }
        }
    }
}

nonisolated enum TemporaryOutgoingMediaFile {
    static func withURL<T>(
        data: Data,
        fileExtension: String,
        directoryResolver: () throws -> URL = { try OutgoingMediaMetadataTempStore.directoryURL() },
        fallback: T,
        _ work: (URL) -> T
    ) -> T {
        guard
            let url = makeTempURL(
                data: data,
                fileExtension: fileExtension,
                directoryResolver: directoryResolver
            )
        else {
            return fallback
        }
        defer { OutgoingMediaMetadataTempStore.remove(at: url) }
        return work(url)
    }

    static func withURL<T>(
        data: Data,
        fileExtension: String,
        directoryResolver: () throws -> URL = { try OutgoingMediaMetadataTempStore.directoryURL() },
        fallback: T,
        _ work: (URL) async -> T
    ) async -> T {
        guard
            let url = makeTempURL(
                data: data,
                fileExtension: fileExtension,
                directoryResolver: directoryResolver
            )
        else {
            return fallback
        }
        defer { OutgoingMediaMetadataTempStore.remove(at: url) }
        return await work(url)
    }

    private static func makeTempURL(
        data: Data,
        fileExtension: String,
        directoryResolver: () throws -> URL
    ) -> URL? {
        guard let directory = try? directoryResolver() else {
            return nil
        }
        return try? OutgoingMediaMetadataTempStore.materialize(
            data: data,
            fileExtension: fileExtension,
            directory: directory
        )
    }
}

nonisolated enum MessagePresentation: Hashable {
    case chat
    case agentStreamStart
    case agentActivity
    case agentOperation
    case groupSystem
    case unsupported

    var isChatBubble: Bool {
        self == .chat
    }

    var systemImage: String {
        switch self {
        case .chat:
            return "text.bubble"
        case .agentStreamStart:
            return "sparkles"
        case .agentActivity:
            return "waveform.path"
        case .agentOperation:
            return "hammer"
        case .groupSystem:
            return "person.2"
        case .unsupported:
            return "questionmark.bubble"
        }
    }

    var debugLabel: String {
        switch self {
        case .chat:
            return "chat"
        case .agentStreamStart:
            return "agent-stream-start"
        case .agentActivity:
            return "agent-activity"
        case .agentOperation:
            return "agent-operation"
        case .groupSystem:
            return "group-system"
        case .unsupported:
            return "unsupported"
        }
    }
}

nonisolated struct MessageItem: Identifiable, Hashable {
    let id: String
    let groupIdHex: String
    let sourceMessageIdHex: String?
    /// Authenticated MLS epoch and pinned retention decision for this exact message.
    let sourceEpoch: UInt64?
    let retentionSeconds: UInt64?
    let retentionExpiresAt: UInt64?
    let replyTargetIdHex: String?
    let senderAccountIdHex: String
    /// The viewer's private nickname for the sender when one is set, else the resolved
    /// published name. `var` so a nickname write can relabel rows already materialized in a
    /// timeline window — see `applyingSenderNickname(_:)`.
    var senderName: String
    /// The published sender name `senderName` overrides; nil when no nickname applies. Carried on
    /// the row so clearing a nickname restores the real name without consulting a profile cache.
    var publishedSenderName: String?
    let senderPictureURL: String?
    let body: String
    /// Canonical plaintext used when editing or forwarding. For edited messages, `body` is the
    /// roster-resolved display text while this retains stable npub mention tokens.
    let wireBody: String
    /// Pre-rendered Markdown display model for the message body. The Marmot core supplies
    /// parsed tokens; `MessageItem` converts them once so SwiftUI body/layout passes do not
    /// rebuild attributed strings or enumerated block arrays while scrolling.
    /// `var` for the same reason `senderName` is: the label a mention resolves to can change under
    /// a materialized row (the viewer sets or clears a private nickname), and rewriting the runs
    /// that name that person is far cheaper than re-projecting the window — see
    /// `applyingMentionLabel(bech32:name:)`.
    var contentMarkdown: MarkdownDisplayDocument?
    var mentionNames: MarkdownMentionNames
    let trimmedBody: String
    let sentAt: Date
    let timelineAt: UInt64
    let timelineKind: UInt64
    let isDeleted: Bool
    let invalidationStatus: String?
    let isEdited: Bool
    let isOutgoing: Bool
    let reactions: [MessageReaction]
    var replyContext: MessageReplyContext?
    let mediaAttachments: [MessageMediaAttachment]
    let visualMediaAttachments: [MessageMediaAttachment]
    let nonvisualMediaAttachments: [MessageMediaAttachment]
    let hasBubbleContent: Bool
    let presentation: MessagePresentation
    let timeLabel: String
    let statusLabel: String?
    let metadataLabel: String

    /// Whether the bubble should render the parsed Markdown AST instead of plain text.
    var rendersMarkdown: Bool { contentMarkdown != nil }
    nonisolated func applyingSenderNickname(_ nickname: String?) -> MessageItem? {
        let published = publishedSenderName ?? senderName
        var copy = self
        if let nickname {
            copy.senderName = nickname
            copy.publishedSenderName = nickname == published ? nil : published
        } else {
            copy.senderName = published
            copy.publishedSenderName = nil
        }
        return copy == self ? nil : copy
    }

    /// Relabels this row's mentions of one person — `bech32` is the npub the mention travels as,
    /// `name` the label it should now read as (nil restores the truncated-bech32 fallback).
    ///
    /// Returns nil when this row does not mention them, so a rename touches only the bubbles that
    /// actually name the renamed person instead of re-rendering the window. The rewrite works off
    /// the `nostr:` link the projection put on every mention run, so it also upgrades a mention
    /// that was rendered before the roster was known and is still showing truncated bech32.
    nonisolated func applyingMentionLabel(bech32: String, name: String?) -> MessageItem? {
        guard let relabeled = contentMarkdown?.relabelingMention(bech32: bech32, name: name) else { return nil }
        var copy = self
        copy.contentMarkdown = relabeled
        // Kept in step with the rendered runs: `mentionNames` is what equality compares, and it is
        // what the next projection of this window will be built from.
        copy.mentionNames[bech32] = name
        return copy
    }

    /// Relabels the sender of the message this row quotes. A quote stores a resolved name rather
    /// than an account id, so the timeline store resolves the quoted row and hands over its
    /// post-relabel `senderName`. Returns nil when nothing changes.
    nonisolated func applyingReplyContextSenderName(_ senderName: String) -> MessageItem? {
        guard var context = replyContext, context.senderName != senderName else { return nil }
        context.senderName = senderName
        var copy = self
        copy.replyContext = context
        return copy
    }

    /// A single rendered emoji, including multi-scalar flags, skin tones, keycaps, and
    /// joined families. Used by the chat row to opt into the large, bubble-free treatment.
    var singleEmoji: String? { EmojiPresentation.singleEmoji(in: trimmedBody) }

    /// The sender's avatar URL, passed through the remote-image policy for incoming-bubble avatars.
    var senderSanitizedPictureURL: URL? { RemoteImageURLPolicy.sanitizedURL(from: senderPictureURL) }

    /// Plain text and a single Markdown paragraph reserve the metadata slot at the
    /// end of the final text line (under the bottom-trailing overlay). Structured
    /// Markdown reserves a separate row so its block semantics remain intact.
    var supportsInlineMetadata: Bool {
        contentMarkdown == nil || contentMarkdown?.inlineParagraph != nil
    }

    /// Body text shown when the bubble uses the plain `Text` fallback instead of the
    /// pre-rendered Markdown AST. Strips bidi embedding/override/isolate controls while
    /// preserving unrelated format characters such as ZWJ/ZWNJ.
    var rawBubbleDisplayBody: String {
        PeerDisplayText.strippingBidiControls(body)
    }

    /// Re-derives the date-sensitive portion of the label after a calendar-day change.
    nonisolated func timeLabel(
        at now: Date,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        DisplayText.messageTimestamp(for: sentAt, now: now, locale: locale)
    }

    /// Spoken counterpart of the delivery marker, so VoiceOver says "Sending" while the icon is a
    /// clock instead of announcing a failure the send has not had yet.
    nonisolated func statusLabel(for indicator: MessageDeliveryIndicator) -> String? {
        switch indicator {
        case .none:
            return nil
        case .sending:
            return L10n.string("Sending")
        case .delivered:
            return L10n.string("Sent")
        case .failed:
            return invalidationStatus != nil
                ? L10n.string("Did not reach group") : L10n.string("Not delivered")
        }
    }

    /// Rebuilds the rendered metadata while preserving the message's edited suffix and re-reading
    /// the delivery state, which is time-sensitive while a send is still in flight.
    nonisolated func metadataLabel(
        at now: Date,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        metadataLabel(at: now, indicator: deliveryIndicator(at: now), locale: locale)
    }

    /// Variant for the bubble, which resolves the marker on its own schedule: the timestamp is
    /// only re-derived on calendar-day changes, while the delivery marker flips on a much shorter
    /// timer, so the two cannot share one reference date.
    nonisolated func metadataLabel(
        at now: Date,
        indicator: MessageDeliveryIndicator,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        var parts = [timeLabel(at: now, locale: locale)]
        if isEdited {
            parts.append(L10n.string("Edited"))
        }
        if let statusLabel = statusLabel(for: indicator) {
            parts.append(statusLabel)
        }
        return parts.joined(separator: "  ")
    }

    // `nonisolated` so the timeline record → view-model mapping (`MessageItem.timeline`)
    // can build items in the off-main window/projection closure (whitenoise-mac#285)
    // without inheriting the module's default main-actor isolation.
    nonisolated init(
        id: String,
        groupIdHex: String = "",
        sourceMessageIdHex: String? = nil,
        sourceEpoch: UInt64? = nil,
        retentionSeconds: UInt64? = nil,
        retentionExpiresAt: UInt64? = nil,
        replyTargetIdHex: String? = nil,
        senderAccountIdHex: String? = nil,
        senderName: String,
        publishedSenderName: String? = nil,
        senderPictureURL: String? = nil,
        body: String,
        wireBody: String? = nil,
        contentMarkdown: MarkdownDocumentFfi? = nil,
        mentionNames: MarkdownMentionNames = [:],
        sentAt: Date,
        timelineAt: UInt64? = nil,
        timelineKind: UInt64 = 9,
        isDeleted: Bool = false,
        invalidationStatus: String? = nil,
        isEdited: Bool = false,
        isOutgoing: Bool,
        reactions: [MessageReaction] = [],
        replyContext: MessageReplyContext? = nil,
        mediaAttachments: [MessageMediaAttachment] = [],
        presentation: MessagePresentation = .chat
    ) {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let partitionedAttachments = Self.partitionMediaAttachments(mediaAttachments)

        self.id = id
        self.groupIdHex = groupIdHex
        self.sourceMessageIdHex = Self.nonBlank(sourceMessageIdHex)
        self.sourceEpoch = sourceEpoch
        self.retentionSeconds = retentionSeconds
        self.retentionExpiresAt = retentionExpiresAt
        self.replyTargetIdHex = Self.nonBlank(replyTargetIdHex)
        self.senderAccountIdHex = senderAccountIdHex ?? senderName
        self.senderName = senderName
        self.publishedSenderName = publishedSenderName
        self.senderPictureURL = senderPictureURL
        self.body = body
        self.wireBody = wireBody ?? body
        // Built here — once, off-main — rather than during a body pass, so a layout pass never
        // rewrites it (whitenoise-mac#205). It no longer needs to know which bubble it will land
        // in: a mention takes the mentioned person's accent, which reads on either one.
        self.contentMarkdown = contentMarkdown.map {
            MarkdownDisplayDocument(document: $0, mentionNames: mentionNames)
        }
        self.mentionNames = mentionNames
        self.trimmedBody = trimmedBody
        self.sentAt = sentAt
        // `timelineAt` is normally supplied by the core mapping; the fallback derives it from
        // `sentAt`. A pre-epoch, non-finite, or oversized `sentAt` would trap the `UInt64(_:)`
        // conversion, so clamp the floored timestamp into the representable range first.
        let fallbackTimeline = sentAt.timeIntervalSince1970
        let resolvedTimelineAt: UInt64
        if let timelineAt = timelineAt {
            resolvedTimelineAt = timelineAt
        } else if fallbackTimeline.isFinite {
            let flooredTimeline = fallbackTimeline.rounded(.down)
            if flooredTimeline <= 0 {
                resolvedTimelineAt = 0
            } else if flooredTimeline >= Double(UInt64.max) {
                resolvedTimelineAt = UInt64.max
            } else {
                resolvedTimelineAt = UInt64(flooredTimeline)
            }
        } else {
            resolvedTimelineAt = 0
        }
        self.timelineAt = resolvedTimelineAt
        self.timelineKind = timelineKind
        self.isDeleted = isDeleted
        self.invalidationStatus = invalidationStatus
        self.isEdited = isEdited
        self.isOutgoing = isOutgoing
        self.reactions = reactions
        self.replyContext = replyContext
        self.mediaAttachments = mediaAttachments
        self.visualMediaAttachments = partitionedAttachments.visual
        self.nonvisualMediaAttachments = partitionedAttachments.nonvisual
        self.hasBubbleContent = replyContext != nil || !trimmedBody.isEmpty
        self.presentation = presentation
        let timeLabel = DisplayText.messageTimestamp(for: sentAt)
        self.timeLabel = timeLabel
        let statusLabel: String?
        if presentation.isChatBubble {
            if invalidationStatus != nil {
                statusLabel = L10n.string("Did not reach group")
            } else if isOutgoing && Self.nonBlank(sourceMessageIdHex) == nil {
                statusLabel = L10n.string("Not delivered")
            } else {
                statusLabel = isOutgoing ? L10n.string("Sent") : nil
            }
        } else {
            statusLabel = nil
        }
        self.statusLabel = statusLabel
        var metadataParts = [timeLabel]
        if isEdited {
            metadataParts.append(L10n.string("Edited"))
        }
        if let statusLabel {
            metadataParts.append(statusLabel)
        }
        self.metadataLabel = metadataParts.joined(separator: "  ")
    }

    func applyingEdit(plaintext editedPlaintext: String) -> MessageItem {
        let wireBody = MessageItem.displayText(
            presentation: presentation,
            plaintext: editedPlaintext,
            tags: [],
            deleted: isDeleted,
            hasMediaAttachments: !mediaAttachments.isEmpty
        )
        let body = MentionDisplayResolver.resolve(in: wireBody, mentionNames: mentionNames)
        return MessageItem(
            id: id,
            groupIdHex: groupIdHex,
            sourceMessageIdHex: sourceMessageIdHex,
            sourceEpoch: sourceEpoch,
            retentionSeconds: retentionSeconds,
            retentionExpiresAt: retentionExpiresAt,
            replyTargetIdHex: replyTargetIdHex,
            senderAccountIdHex: senderAccountIdHex,
            senderName: senderName,
            publishedSenderName: publishedSenderName,
            senderPictureURL: senderPictureURL,
            body: body,
            wireBody: wireBody,
            contentMarkdown: nil,
            mentionNames: mentionNames,
            sentAt: sentAt,
            timelineAt: timelineAt,
            timelineKind: timelineKind,
            isDeleted: isDeleted,
            invalidationStatus: invalidationStatus,
            isEdited: true,
            isOutgoing: isOutgoing,
            reactions: reactions,
            replyContext: replyContext,
            mediaAttachments: mediaAttachments,
            presentation: presentation
        )
    }

    nonisolated private static func partitionMediaAttachments(_ attachments: [MessageMediaAttachment]) -> (
        visual: [MessageMediaAttachment], nonvisual: [MessageMediaAttachment]
    ) {
        var visual: [MessageMediaAttachment] = []
        var nonvisual: [MessageMediaAttachment] = []

        for attachment in attachments {
            switch attachment.kind {
            case .image, .video:
                visual.append(attachment)
            case .audio, .file:
                nonvisual.append(attachment)
            }
        }

        return (visual, nonvisual)
    }

    var debugTitle: String {
        "kind \(timelineKind) - \(presentation.debugLabel)"
    }

    var debugDetail: String {
        var parts = ["\(DisplayText.short(id, head: 10, tail: 8)) - \(timelineAt)"]
        if let sourceMessageIdHex {
            parts.append("source \(DisplayText.short(sourceMessageIdHex, head: 10, tail: 8))")
        }
        if let replyTargetIdHex {
            parts.append("reply \(DisplayText.short(replyTargetIdHex, head: 10, tail: 8))")
        }
        return parts.joined(separator: " - ")
    }

    private var hasCopyableBody: Bool {
        !trimmedBody.isEmpty
    }

    var replyPreviewText: String {
        if !trimmedBody.isEmpty {
            return trimmedBody
        }
        return MessageMediaAttachment.previewText(for: mediaAttachments)
    }

    private nonisolated static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the row carries real content the user can act on.
    ///
    /// Invalidated rows count. Convergence retired them, but they are still drawn with their own
    /// content and their own failure marker, so to the reader they are a failed message like any
    /// other — and a failed message the app refuses to retry, forward, edit, copy or delete is a
    /// bubble the user is simply stuck with. Only a deleted row, whose body is a placeholder rather
    /// than anything the user wrote, is excluded.
    private var isActionableContent: Bool {
        !isDeleted
    }

    private var isActionableChatBubble: Bool {
        presentation.isChatBubble && isActionableContent
    }

    var supportsChatActions: Bool {
        isActionableChatBubble
    }

    /// The core commits outgoing messages locally before publishing them. A missing source
    /// event id therefore means this bubble has not reached the relays yet.
    var isPendingDelivery: Bool {
        presentation.isChatBubble
            && isOutgoing
            && !isDeleted
            && invalidationStatus == nil
            && sourceMessageIdHex == nil
    }

    /// Whether this row may be re-driven to the relays at `now`.
    ///
    /// Keyed on the marker the bubble is actually wearing, so retry appears exactly when the row
    /// starts reading as an error and never before. That is time-sensitive on purpose: a send still
    /// inside `pendingDeliveryGrace` reads as "Sending", and offering to retry something the app is
    /// telling the user is still going out invites a second click on a first attempt that has not
    /// finished.
    ///
    /// Invalidated rows qualify too — they wear the same marker, so refusing them here would be the
    /// app showing a failure and then declining to do the one thing a failure asks for. The retry
    /// is `retryGroupConvergence`, which re-drives what the core is holding for the conversation.
    func canRetryDelivery(at now: Date) -> Bool {
        guard presentation.isChatBubble, isOutgoing, !isDeleted else { return false }
        return deliveryIndicator(at: now) == .failed
    }

    /// How long an own send may stay unconfirmed before its bubble stops reading as "Sending" and
    /// starts reading as an error. Publishing is a relay round-trip whose payload the composer has
    /// already uploaded, so this only has to outlast a slow network — not a transfer.
    static let pendingDeliveryGrace: TimeInterval = 15

    /// What the bubble's delivery footer should show at `now`.
    ///
    /// `.none` for the rows that never carried a marker (incoming, uninvalidated). Invalidation is
    /// terminal — convergence already decided the message lost — so it fails immediately rather
    /// than waiting out the grace window.
    func deliveryIndicator(at now: Date) -> MessageDeliveryIndicator {
        guard presentation.isChatBubble else { return .none }
        if invalidationStatus != nil { return .failed }
        guard isOutgoing else { return .none }
        guard isPendingDelivery else { return .delivered }
        return pendingDeliveryGraceRemaining(at: now) == nil ? .failed : .sending
    }

    /// Time left before `deliveryIndicator(at:)` escalates this send to `.failed`, or nil once the
    /// window has passed (or never applied).
    ///
    /// Measured from `sentAt`, not from when the bubble appeared: a message left pending across a
    /// relaunch has already had its grace and should read as failed on sight rather than restart
    /// the countdown. `sentAt` is second-granular and can round slightly ahead of the wall clock,
    /// so the remainder is clamped to the full window.
    func pendingDeliveryGraceRemaining(at now: Date) -> TimeInterval? {
        guard isPendingDelivery else { return nil }
        let remaining = Self.pendingDeliveryGrace - now.timeIntervalSince(sentAt)
        guard remaining > 0 else { return nil }
        return min(remaining, Self.pendingDeliveryGrace)
    }

    /// The parts of a row that decide its delivery footer. Used as the identity of the view's
    /// grace-window timer so it restarts when delivery actually moves, not on every unrelated
    /// re-render (a new reaction, a resolved sender name).
    var deliverySignature: MessageDeliverySignature {
        MessageDeliverySignature(
            messageId: id,
            sentAt: sentAt,
            isPendingDelivery: isPendingDelivery,
            isInvalidated: invalidationStatus != nil,
            isOutgoing: isOutgoing
        )
    }

    var canCopyText: Bool {
        isActionableContent && hasCopyableBody
    }

    var canReact: Bool {
        isActionableChatBubble
    }

    var canReply: Bool {
        isActionableChatBubble
    }

    var canDelete: Bool {
        isActionableChatBubble && isOutgoing
    }

    var canForward: Bool {
        isActionableChatBubble && hasCopyableBody
    }

    var canEdit: Bool {
        isActionableChatBubble && isOutgoing && hasCopyableBody && mediaAttachments.isEmpty
    }

    /// Whether the hover actions offer "download every attachment on this message". Own messages
    /// qualify too — the local copy of a sent photo is only in the app until it is downloaded.
    var canDownloadMediaAttachments: Bool {
        isActionableChatBubble && !mediaAttachments.isEmpty
    }

    /// One gesture, two jobs: a lone attachment downloads itself, several download together, and
    /// the hover tooltip and the context menu both have to say which before the click.
    var mediaDownloadActionTitle: String {
        Self.mediaDownloadActionTitle(forAttachmentCount: mediaAttachments.count)
    }

    /// The same wording for a gesture that targets a subset of the message: the image gallery's
    /// button saves the photo on screen, so it is a "Download" even on a message carrying five.
    static func mediaDownloadActionTitle(forAttachmentCount count: Int) -> String {
        count > 1
            ? L10n.string("Download attachments")
            : L10n.string("Download")
    }
}

/// Which delete scopes the local account may perform on one message. Derived from conversation
/// type, message ownership, and the local account's admin role in *this* conversation.
///
/// Delete-for-me hides the message locally and never publishes. Delete-for-everyone publishes a
/// group-wide tombstone (self-retraction, or an admin moderating another member's group message).
/// A direct message is never removable for everyone by anyone but its author — an admin role from
/// another group, or an admin flag on a DM's own two-member group, must never grant it, which the
/// `isGroup` guard below enforces structurally.
nonisolated struct MessageDeletionCapability: Equatable {
    let canDeleteForMe: Bool
    let canDeleteForEveryone: Bool

    static let none = MessageDeletionCapability(canDeleteForMe: false, canDeleteForEveryone: false)

    var canDelete: Bool { canDeleteForMe || canDeleteForEveryone }

    /// - Parameters:
    ///   - isActionable: a real, non-deleted message bubble the user can act on.
    ///   - isDirectConversation: a two-member direct message rather than a group.
    ///   - isOwnMessage: the local account authored the message.
    ///   - isSelfGroupAdmin: the local account is admin/owner of THIS group. Ignored for DMs.
    static func resolve(
        isActionable: Bool,
        isDirectConversation: Bool,
        isOwnMessage: Bool,
        isSelfGroupAdmin: Bool
    ) -> MessageDeletionCapability {
        guard isActionable else { return .none }
        let forEveryone = isOwnMessage || (!isDirectConversation && isSelfGroupAdmin)
        return MessageDeletionCapability(canDeleteForMe: true, canDeleteForEveryone: forEveryone)
    }
}

/// Immutable account/conversation scope captured when a deletion action is opened. Confirmation
/// and async mutation paths use this instead of consulting the workspace's mutable selection.
nonisolated struct MessageDeletionTarget: Hashable {
    let message: MessageItem
    let accountId: String
    let accountRef: String
    let groupIdHex: String
    let isDirectConversation: Bool
    let isSelfGroupAdmin: Bool
}

extension MessageItem {
    // Hand-written `Equatable`/`Hashable` so equality and hashing stay O(1) instead of
    // recursively walking `contentMarkdown`'s pre-rendered Markdown tree.
    //
    // `contentMarkdown` is a deterministic display projection of the message content
    // (the core's `contentTokens`), fully determined by the content-bearing fields
    // compared below — chiefly `body`, `mentionNames`, `isDeleted`, and `presentation`. Two items that
    // agree on those always carry the same AST, so excluding it from equality is sound
    // while avoiding an O(AST) traversal on every comparison. That traversal otherwise
    // ran for each row whenever SwiftUI diffed the transcript (and on any Set/Dictionary
    // use), adding up across a live-update burst. The remaining fields are the
    // independent inputs; rendered labels are compared too because they are cheap and
    // directly displayed by the row. The rest of the stored properties (`trimmedBody`, the
    // media partitions, `hasBubbleContent`) are pure functions of these, so comparing them
    // too would be redundant.
    nonisolated static func == (lhs: MessageItem, rhs: MessageItem) -> Bool {
        lhs.id == rhs.id
            && lhs.groupIdHex == rhs.groupIdHex
            && lhs.sourceMessageIdHex == rhs.sourceMessageIdHex
            && lhs.replyTargetIdHex == rhs.replyTargetIdHex
            && lhs.senderAccountIdHex == rhs.senderAccountIdHex
            && lhs.senderName == rhs.senderName
            && lhs.senderPictureURL == rhs.senderPictureURL
            && lhs.body == rhs.body
            && lhs.wireBody == rhs.wireBody
            && lhs.mentionNames == rhs.mentionNames
            && lhs.sentAt == rhs.sentAt
            && lhs.timelineAt == rhs.timelineAt
            && lhs.timelineKind == rhs.timelineKind
            && lhs.isDeleted == rhs.isDeleted
            && lhs.invalidationStatus == rhs.invalidationStatus
            && lhs.isEdited == rhs.isEdited
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.reactions == rhs.reactions
            && lhs.replyContext == rhs.replyContext
            && lhs.mediaAttachments == rhs.mediaAttachments
            && lhs.presentation == rhs.presentation
            && lhs.timeLabel == rhs.timeLabel
            && lhs.statusLabel == rhs.statusLabel
            && lhs.metadataLabel == rhs.metadataLabel
    }

    // Hashes a cheap, well-distributed subset of the equality fields. Hashing only a
    // subset is valid — equal values still hash equally — and keeps the message id (which
    // is unique per message) doing the bulk of the distribution work.
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(replyTargetIdHex)
        hasher.combine(timelineAt)
        hasher.combine(isEdited)
    }
}

enum WorkspaceSelection: Equatable {
    case chat(String)
    case settings(SettingsPage)
}

enum SettingsPage: Equatable {
    case overview
    case preferences
    case profile
    case identityKeys
    case relays
    case keyPackages
    case appearance
    case privacySecurity
    case notifications
    case storage
    case developerMode

    /// The drawer's cards, ported from `wn-ios-prototype`'s hub: a group of destinations per
    /// question the reader is asking. One flat column of ten rows gave no signal that Relays and
    /// Appearance are answers to different questions.
    ///
    /// The split follows the order that was already here rather than reordering to match the
    /// prototype row for row — the order encodes its own decision (see `sidebarPages`), and it
    /// falls into these three groups without being disturbed:
    ///
    /// - who you are and how you reach the network,
    /// - how the app treats you,
    /// - and what only a developer wants.
    static let sidebarGroups: [[SettingsPage]] = [
        [
            .profile,
            .identityKeys,
            .notifications,
            .appearance,
            .privacySecurity,
            .storage,
            .relays,
            .keyPackages,
        ],
        [
            .preferences,
            .developerMode,
        ],
    ]

    /// Every drawer destination in order, derived from the cards so the two cannot disagree.
    ///
    /// Preferences sits next to Appearance rather than at the top: both are day-to-day
    /// choices about how the app treats you, and neither is what someone opens settings for.
    /// Leading with the startup toggles made a rarely-touched page read as the main one.
    static let sidebarPages: [SettingsPage] = sidebarGroups.flatMap { $0 }

    /// Localized against an explicit locale rather than the stored language preference, so
    /// the settings sidebar can localize with the `\.locale` environment value and be
    /// re-rendered on a language switch instead of showing the previous language until the
    /// row is rebuilt (see `L10n.string(_:locale:)`).
    func title(in locale: Locale) -> String {
        L10n.string(titleKey, locale: locale)
    }

    private var titleKey: String {
        switch self {
        case .overview:
            "Settings"
        case .preferences:
            "Preferences"
        case .profile:
            "Profile"
        case .identityKeys:
            "Profile Keys"
        case .relays:
            "Relays"
        case .keyPackages:
            "Key Packages"
        case .appearance:
            "Appearance"
        case .privacySecurity:
            "Privacy & Security"
        case .notifications:
            "Notifications"
        case .storage:
            "Storage"
        case .developerMode:
            "Developer mode"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "gearshape"
        case .preferences:
            "slider.horizontal.3"
        case .profile:
            "person.crop.circle"
        case .identityKeys:
            "key"
        case .relays:
            "antenna.radiowaves.left.and.right"
        case .keyPackages:
            "shippingbox"
        case .appearance:
            "circle.lefthalf.filled"
        case .privacySecurity:
            "hand.raised"
        case .notifications:
            "bell"
        case .storage:
            "externaldrive"
        case .developerMode:
            "wrench.and.screwdriver"
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:
            L10n.string("System")
        case .light:
            L10n.string("Light")
        case .dark:
            L10n.string("Dark")
        }
    }
}

enum LocalNotificationAuthorizationStatus: String, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    var canPostNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        }
    }
}

struct NotificationSettingsSnapshot: Equatable {
    var localNotificationsEnabled: Bool
    /// Whether the account asks the White Noise push service for a generic
    /// wake-up. It carries no message content — see `NotificationPreviewMode`
    /// for what a delivered notification is allowed to say.
    var nativePushEnabled: Bool

    static let defaults = NotificationSettingsSnapshot(
        localNotificationsEnabled: false,
        nativePushEnabled: false
    )
}

/// Controls how much of an incoming message is revealed in a macOS local
/// notification. macOS renders notification content as banners, persists it in
/// Notification Center, and shows it on the lock screen, so for an E2EE
/// messenger the notification body is content that leaves the app's control.
/// This lets a user trade convenience for privacy, mirroring the conservative,
/// individually-toggleable defaults used elsewhere in Privacy & Security.
enum NotificationPreviewMode: String, CaseIterable, Identifiable {
    /// Show the sender/group name and the decrypted message text (legacy behavior).
    case full
    /// Show who the message is from (and the group name), but never the message text.
    case senderOnly
    /// Reveal nothing: generic "New message" with no sender, group, or content.
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full:
            L10n.string("Show message preview")
        case .senderOnly:
            L10n.string("Sender only")
        case .hidden:
            L10n.string("Hide all")
        }
    }

    var detail: String {
        switch self {
        case .full:
            L10n.string("Notifications show who sent the message and its contents.")
        case .senderOnly:
            L10n.string("Notifications show who sent the message but not its contents.")
        case .hidden:
            L10n.string("Notifications only say a new message arrived.")
        }
    }

    /// The notification this mode would actually post, written out. The choice's
    /// name says what is withheld; this says what is shown, which is the thing a
    /// reader is really deciding about.
    var example: String {
        switch self {
        case .full:
            L10n.string("Alice · Can you send the latest version?")
        case .senderOnly:
            L10n.string("Alice · New message")
        case .hidden:
            L10n.string("White Noise · New message")
        }
    }
}

struct PrivacySecuritySettingsSnapshot: Equatable {
    var relayTelemetryEnabled: Bool
    var relayTelemetryIntervalSeconds: UInt64
    /// Audit logging is a single on/off choice on macOS. Records are always written
    /// with `AuditDataModeFfi.obfuscatedSensitiveData`; this client never asks the
    /// core for the full-data posture.
    var auditLoggingEnabled: Bool
    var telemetryCredentialsAvailable: Bool
    var auditLogCredentialsAvailable: Bool

    static let defaults = PrivacySecuritySettingsSnapshot(
        relayTelemetryEnabled: false,
        relayTelemetryIntervalSeconds: 60,
        auditLoggingEnabled: false,
        telemetryCredentialsAvailable: false,
        auditLogCredentialsAvailable: false
    )
}

struct DiagnosticsInfoItem: Identifiable, Equatable {
    let title: String
    let value: String

    var id: String { title }
}

enum RelaySettingsSection: String, CaseIterable, Identifiable {
    case nip65 = "NIP-65"
    case inbox = "Inbox"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nip65:
            rawValue
        case .inbox:
            L10n.string("Inbox")
        }
    }

    var description: String {
        switch self {
        case .nip65:
            L10n.string("Profile relay list")
        case .inbox:
            L10n.string("Message delivery relays")
        }
    }
}

struct ProfileDraft: Equatable {
    var name: String
    var displayName: String
    var about: String
    var picture: String {
        didSet {
            guard picture != oldValue else { return }
            sanitizedPictureURL = RemoteImageURLPolicy.sanitizedURL(from: picture)
        }
    }
    private(set) var sanitizedPictureURL: URL?
    var banner: String
    var nip05: String
    var lud16: String

    init(
        name: String = "",
        displayName: String = "",
        about: String = "",
        picture: String = "",
        banner: String = "",
        nip05: String = "",
        lud16: String = ""
    ) {
        self.name = name
        self.displayName = displayName
        self.about = about
        self.picture = picture
        self.sanitizedPictureURL = RemoteImageURLPolicy.sanitizedURL(from: picture)
        self.banner = banner
        self.nip05 = nip05
        self.lud16 = lud16
    }
}

struct RelaySettingsSnapshot: Equatable {
    var nip65: [String]
    var inbox: [String]
    var defaultRelays: [String]
    var bootstrapRelays: [String]
    var publishedNip65: [String]
    var publishedInbox: [String]
    var missing: [String]
    var isComplete: Bool

    static let defaults = RelaySettingsSnapshot(
        nip65: MarmotClient.seedRelays,
        inbox: MarmotClient.seedRelays,
        defaultRelays: MarmotClient.seedRelays,
        bootstrapRelays: MarmotClient.seedRelays,
        publishedNip65: MarmotClient.seedRelays,
        publishedInbox: MarmotClient.seedRelays,
        missing: [],
        isComplete: true
    )

    func relays(for section: RelaySettingsSection) -> [String] {
        switch section {
        case .nip65: nip65
        case .inbox: inbox
        }
    }

    mutating func setRelays(_ relays: [String], for section: RelaySettingsSection) {
        switch section {
        case .nip65:
            nip65 = relays
        case .inbox:
            inbox = relays
        }
    }

    var publishRelays: [String] {
        firstNonEmpty([defaultRelays, nip65, inbox])
    }

    var networkBootstrapRelays: [String] {
        firstNonEmpty([bootstrapRelays, defaultRelays, nip65, inbox])
    }

    private func firstNonEmpty(_ candidates: [[String]]) -> [String] {
        candidates
            .map(Self.normalizedRelayURLs)
            .first { !$0.isEmpty }
            ?? MarmotClient.seedRelays
    }

    nonisolated private static func normalizedRelayURLs(_ relays: [String]) -> [String] {
        var seen = Set<String>()
        return
            relays
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

struct KeyPackageItem: Identifiable, Equatable {
    let accountRef: String?
    let accountIdHex: String
    let keyPackageId: String
    let keyPackageRefHex: String
    let eventIdHex: String
    let publishedAt: Date?
    let keyPackageBytes: UInt64
    let sourceRelays: [String]
    let isLocal: Bool
    let isRelayDiscovered: Bool

    var id: String {
        if !eventIdHex.isEmpty { return eventIdHex }
        if !keyPackageRefHex.isEmpty { return keyPackageRefHex }
        return keyPackageId
    }

    var sourceLabel: String {
        statusLabels.joined(separator: " + ")
    }

    var statusLabels: [String] {
        var labels: [String] = []
        if isLocal {
            labels.append(L10n.string("Local"))
        }
        if isRelayDiscovered {
            labels.append(L10n.string("Synced"))
        }
        return labels.isEmpty ? [L10n.string("Unknown")] : labels
    }

    var publishedLabel: String {
        guard let publishedAt else { return L10n.string("Unknown") }
        return DisplayText.dateTimeTimestamp(for: publishedAt)
    }
}

struct NewChatRecipient: Equatable {
    let sourceQuery: String
    let memberRef: String
    let accountIdHex: String
    let npub: String
    let displayName: String?
    let publishedDisplayName: String?
    let pictureURL: String?
    /// Pre-sanitized once from the peer-controlled raw URL so recipient rows only read it.
    let sanitizedPictureURL: URL?

    init(
        sourceQuery: String,
        memberRef: String,
        accountIdHex: String,
        npub: String,
        displayName: String?,
        publishedDisplayName: String? = nil,
        pictureURL: String?
    ) {
        self.sourceQuery = sourceQuery
        self.memberRef = memberRef
        self.accountIdHex = accountIdHex
        self.npub = npub
        self.displayName = PeerDisplayText.sanitize(displayName)
        self.publishedDisplayName = PeerDisplayText.sanitize(publishedDisplayName)
        self.pictureURL = pictureURL
        self.sanitizedPictureURL = RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
    }

    var title: String {
        displayName ?? DisplayText.short(accountIdHex)
    }

    var subtitle: String {
        npub.isEmpty ? DisplayText.short(accountIdHex, head: 12, tail: 10) : npub
    }

    func matches(query: String) -> Bool {
        sourceQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Which panel of the new-chat flow the drawer shows while the composer is visible.
enum ComposePane: Equatable {
    case newChat
    case chooseMembers
    case nameGroup
}

/// A person reachable from the compose flow. Derived from already-loaded chats (direct-chat
/// peers and group rosters) because the core exposes no contact-enumeration call.
struct ComposeContact: Identifiable, Equatable {
    let accountIdHex: String
    let npub: String
    let displayName: String?
    let publishedDisplayName: String?
    let pictureURL: String?
    let sanitizedPictureURL: URL?
    let lastActivity: Date?

    var id: String { accountIdHex }

    init(
        accountIdHex: String,
        npub: String,
        displayName: String?,
        publishedDisplayName: String? = nil,
        pictureURL: String?,
        lastActivity: Date?
    ) {
        self.accountIdHex = accountIdHex
        self.npub = npub
        self.displayName = PeerDisplayText.sanitize(displayName)
        self.publishedDisplayName = PeerDisplayText.sanitize(publishedDisplayName)
        self.pictureURL = pictureURL
        self.sanitizedPictureURL = RemoteImageURLPolicy.sanitizedURL(from: pictureURL)
        self.lastActivity = lastActivity
    }

    var title: String {
        displayName ?? DisplayText.short(npub.isEmpty ? accountIdHex : npub)
    }

    var searchableNames: [String] {
        [title, publishedDisplayName].compactMap { $0 }
    }

    var subtitle: String {
        DisplayText.short(npub.isEmpty ? accountIdHex : npub, head: 12, tail: 8)
    }

    var memberRef: String {
        npub.isEmpty ? accountIdHex : npub
    }

    var recipient: NewChatRecipient {
        NewChatRecipient(
            sourceQuery: "",
            memberRef: memberRef,
            accountIdHex: accountIdHex,
            npub: npub,
            displayName: displayName,
            publishedDisplayName: publishedDisplayName,
            pictureURL: pictureURL
        )
    }
}

enum ChatFilter {
    static func filtered(_ chats: [ChatItem], query: String) -> [ChatItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return chats }
        return chats.filter { chat in
            chat.title.localizedCaseInsensitiveContains(needle)
                || chat.publishedTitle?.localizedCaseInsensitiveContains(needle) == true
                || chat.subtitle.localizedCaseInsensitiveContains(needle)
                || chat.preview.localizedCaseInsensitiveContains(needle)
        }
    }
}

enum ChatListFilter: String, CaseIterable {
    case active
    case unread
    case archived

    var title: String {
        switch self {
        case .active:
            return L10n.string("Chats")
        case .unread:
            return L10n.string("Unread")
        case .archived:
            return L10n.string("Archived")
        }
    }

    var systemImage: String {
        switch self {
        case .active:
            return "bubble.left.and.bubble.right"
        case .unread:
            return "circle.fill"
        case .archived:
            return "archivebox"
        }
    }
}

nonisolated enum DisplayText {
    // Cached so per-message timestamp formatting during mapping does not re-resolve the
    // calendar or rebuild a format style for every message.
    private static let calendar = Calendar.autoupdatingCurrent
    private static let timeOnlyStyle = Date.FormatStyle(date: .omitted, time: .shortened)
    private static let dateTimeStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
    private static let longDateTimeStyle = Date.FormatStyle(date: .long, time: .shortened)
    private static let weekdayStyle = Date.FormatStyle.dateTime.weekday(.abbreviated)
    private static let monthDayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
    private static let dayHeaderStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)

    static func short(_ value: String, head: Int = 8, tail: Int = 6) -> String {
        guard value.count > head + tail + 3 else { return value }
        return "\(value.prefix(head))...\(value.suffix(tail))"
    }

    /// Breaks an opaque identifier into fixed-size groups so a reader can check it a chunk at a
    /// time, and so a long key has somewhere to wrap. Matches `formatPublicKey` on the other
    /// clients, which is what makes a displayed npub look the same across them.
    ///
    /// Display only — the grouped string is never what gets copied.
    static func grouped(_ value: String, every size: Int = 4) -> String {
        guard size > 0 else { return value }
        return stride(from: 0, to: value.count, by: size)
            .map { offset in
                let start = value.index(value.startIndex, offsetBy: offset)
                let end = value.index(start, offsetBy: size, limitedBy: value.endIndex) ?? value.endIndex
                return String(value[start..<end])
            }
            .joined(separator: " ")
    }

    static func initials(for value: String, fallback: String) -> String {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
        let parts =
            source
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        if !letters.isEmpty { return letters }
        return String(source.prefix(2)).uppercased()
    }

    static func relativeTimestamp(for date: Date, now: Date = Date(), locale: Locale = AppLanguage.currentLocale)
        -> String
    {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(timeOnlyStyle.locale(AppLanguage.twelveHourLocale(for: locale)))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(weekdayStyle.locale(locale))
        }
        return date.formatted(monthDayStyle.locale(locale))
    }

    static func messageTimestamp(for date: Date, now: Date = Date(), locale: Locale = AppLanguage.currentLocale)
        -> String
    {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(timeOnlyStyle.locale(AppLanguage.twelveHourLocale(for: locale)))
        }
        return dateTimeTimestamp(for: date, locale: locale)
    }

    static func dateTimeTimestamp(for date: Date, locale: Locale = AppLanguage.currentLocale) -> String {
        date.formatted(dateTimeStyle.locale(locale))
    }

    static func longDateTimeTimestamp(for date: Date, locale: Locale = AppLanguage.currentLocale) -> String {
        date.formatted(longDateTimeStyle.locale(locale))
    }

    static func timelineDayLabel(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.string("Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return L10n.string("Yesterday")
        }
        return date.formatted(dayHeaderStyle.locale(locale))
    }
}

nonisolated struct TimelineMessageDisplayItem: Identifiable {
    let message: MessageItem
    let dayLabel: String?

    var id: String { message.id }

    static func make(
        from messages: [MessageItem],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = AppLanguage.currentLocale
    ) -> [TimelineMessageDisplayItem] {
        var previousDate: Date?
        return messages.map { message in
            let beginsDay = previousDate.map { !calendar.isDate($0, inSameDayAs: message.sentAt) } ?? true
            previousDate = message.sentAt
            return TimelineMessageDisplayItem(
                message: message,
                dayLabel: beginsDay
                    ? DisplayText.timelineDayLabel(
                        for: message.sentAt,
                        now: now,
                        calendar: calendar,
                        locale: locale
                    )
                    : nil
            )
        }
    }
}

extension AccountItem {
    static let samples: [AccountItem] = [
        AccountItem(
            id: "account-jeff",
            accountRef: "jeff",
            displayName: "Jeff",
            accountIdHex: "93f7d85ef9279a03e21b7a0f0716db579d45bbab0a664707d0af6c2e2d25aa11",
            initials: "JG"
        ),
        AccountItem(
            id: "account-lab",
            accountRef: "lab",
            displayName: "Lab",
            accountIdHex: "f46f35698b7d724aa0d746c7f6ef463d979df5e45756b7519e87f98535a44c01",
            initials: "LB"
        ),
        AccountItem(
            id: "account-field",
            accountRef: "field",
            displayName: "Field",
            accountIdHex: "20b014f1701db12b8d4732ad506ce310419eb86539913b010fe09f114d9ae51f",
            initials: "FD"
        ),
    ]
}

extension ChatItem {
    static let samples: [ChatItem] = [
        ChatItem(
            id: "chat-design",
            title: "Marmot Design",
            subtitle: "8 members",
            preview: "The desktop shell can own layout while Rust owns identity and transport.",
            updatedAt: Date().addingTimeInterval(-820),
            avatarSeed: "chat-design",
            pictureURL: nil,
            unreadCount: 3
        ),
        ChatItem(
            id: "chat-nvk",
            title: "NVK",
            subtitle: "Direct message",
            preview: "Let's keep the left rail fast for account switching.",
            updatedAt: Date().addingTimeInterval(-7_600),
            avatarSeed: "chat-nvk",
            pictureURL: nil,
            unreadCount: 0,
            isDirect: true
        ),
        ChatItem(
            id: "chat-relays",
            title: "Relay Ops",
            subtitle: "5 members",
            preview: "EU and US White Noise relays both caught up on the last run.",
            updatedAt: Date().addingTimeInterval(-90_000),
            avatarSeed: "chat-relays",
            pictureURL: nil,
            unreadCount: 1
        ),
    ]
}

extension MessageItem {
    static let samples: [String: [MessageItem]] = [
        "chat-design": [
            MessageItem(
                id: "m1",
                senderName: "NVK",
                body:
                    "We should keep accounts visible all the time. Switching identities is core, not a settings errand.",
                sentAt: Date().addingTimeInterval(-4_500),
                isOutgoing: false
            ),
            MessageItem(
                id: "m2",
                senderName: "Jeff",
                body: "Agree. Narrow account rail, wider chat drawer, detail area does the heavy lifting.",
                sentAt: Date().addingTimeInterval(-3_900),
                isOutgoing: true
            ),
            MessageItem(
                id: "m3",
                senderName: "Shaka",
                body: "I will wire the app frame around MarmotKit so real accounts and chats have a place to land.",
                sentAt: Date().addingTimeInterval(-800),
                isOutgoing: false
            ),
        ],
        "chat-nvk": [
            MessageItem(
                id: "m4",
                senderName: "NVK",
                body: "Desktop should feel denser than mobile without turning into a spreadsheet.",
                sentAt: Date().addingTimeInterval(-7_600),
                isOutgoing: false
            )
        ],
        "chat-relays": [
            MessageItem(
                id: "m5",
                senderName: "Relay Ops",
                body: "Seed relays now point at the EU and US White Noise relays for the initial Marmot runtime.",
                sentAt: Date().addingTimeInterval(-90_000),
                isOutgoing: false
            )
        ],
    ]
}
