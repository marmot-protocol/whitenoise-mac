import Foundation
import MarmotKit

/// The one place an error becomes copy the user reads.
///
/// `MarmotKitError.errorDescription` is `String(reflecting:)`, so a core error reaching the UI as
/// `localizedDescription` printed `MarmotKit.MarmotKitError.UnknownGroup(groupIdHex: "…")`, in
/// English and with whatever ids or details it carried. Every `MarmotKitError` case is mapped here
/// to a localized sentence; the core's `details` strings are diagnostics and are never shown.
///
/// The switch is exhaustive on purpose. When a MarmotKit release adds a case, the build fails
/// here until someone decides what the user should read. Wording is shared with iOS where iOS has
/// it, so the two apps say the same thing and reuse the same translations.
nonisolated enum UserFacingError {
    static func message(for error: Error) -> String {
        if let error = error as? MarmotKitError {
            return message(for: error)
        }
        if let error = error as? Nip46ErrorFfi {
            return nip46Message(error)
        }
        // Any other MarmotKit error is a binding fault (a Rust panic, a malformed buffer) whose
        // description is diagnostic English — a panic's message verbatim. Since 0.16.0 the generated
        // subscription receives throw these, so they reach the same surfaces core errors do.
        if String(reflecting: type(of: error)).hasPrefix("MarmotKit.") {
            return L10n.string("Something went wrong. Please try again.")
        }
        let text = sanitized(error.localizedDescription)
        return text.isEmpty ? L10n.string("Please try again.") : text
    }

    static func message(for error: MarmotKitError) -> String {
        switch error {
        // MARK: Blocking and reporting
        case .UserBlocked:
            L10n.string("Unblock this person before sending a message.")
        case .BlockListUnavailable:
            L10n.string("The block list is unavailable. Please try again.")
        case .BlockPublicationUncertain:
            L10n.string("The block-list update could not be confirmed. Retry the same change to check its status.")
        case .ModerationReportingNotConfigured, .InvalidModerationReportConfig:
            L10n.string("Reporting to White Noise isn’t available in this version of the app.")
        case .InvalidReportedPublicKey:
            L10n.string("This person can’t be reported.")
        case .CannotReportSelf:
            L10n.string("You can’t report yourself.")
        case .ModerationReportRateLimited:
            L10n.string("You’ve sent a lot of reports recently. Try again later.")

        // MARK: Messages and drafts
        case .InvalidEditTarget:
            L10n.string("This message can't be edited.")
        case .MessageDraftRevisionConflict:
            L10n.string("The saved draft changed. Your text has been preserved.")
        case .EventTooLarge(let artifact, _):
            eventTooLargeMessage(artifact)
        case .GroupSendQueueFull:
            L10n.string("This chat is still catching up. Wait for it to finish, then resend your message.")
        case .GroupUnrecoverableRepairRequired:
            L10n.string("This conversation needs to be rejoined before you can send messages.")
        case .Publish:
            L10n.string("Couldn’t publish to your relays. Check your connection and try again.")
        case .TransportClosed:
            L10n.string("Couldn’t reach your relays. Check your connection and try again.")

        // MARK: Accounts and setup
        case .DuplicateIdentity:
            L10n.string("Identity already signed in on this device")
        case .UnknownAccount:
            L10n.string("This account isn’t signed in on this Mac.")
        case .AccountUnlinked:
            L10n.string(
                "Your other devices removed this device from the account. Remove this profile here, then link this device again."
            )
        case .AccountSetupRecoveryRequired:
            L10n.string("Incomplete identity setup needs approval to recover.")
        case .AccountSetupRetryRequired, .AccountSetupKeyPackageRecoveryAvailable:
            L10n.string("Identity setup can be resumed. Try importing again.")
        case .AccountSetupResetNotApplicable:
            L10n.string("This incomplete identity setup could not be recovered.")
        case .OnboardingRequired:
            L10n.string("Finish account setup before using this account.")
        case .OnboardingActionUnavailable:
            L10n.string("Setup changed. Review the latest options and try again.")
        case .AccountWorkerBusy, .AccountSessionBusy:
            L10n.string("This account is still catching up. Try again in a moment.")
        case .AccountWorkerResponseTimedOut:
            L10n.string("The operation may have completed. Refreshing the conversation is required before retrying.")
        case .AccountCatchUp:
            L10n.string("Couldn’t catch up on messages. Check your connection and try again.")
        case .ConsentRequired:
            L10n.string("This needs your permission to share usage data first.")

        // MARK: Keys and signers
        case .SecretNotFound:
            L10n.string("This account’s private key isn’t stored on this Mac.")
        case .KeystoreUnavailable:
            L10n.string("Your Keychain is unavailable. Unlock your Mac, then try again.")
        case .EmptyPassphrase:
            L10n.string("Enter a password to protect your backup.")
        case .EncryptionFailed:
            L10n.string("Couldn’t encrypt your private key. Please try again.")
        case .Io:
            L10n.string("Couldn’t read or write a file on this Mac. Please try again.")
        case .ExternalSignerUnavailable:
            L10n.string("Your signer is unavailable.")
        case .ExternalSignerMismatch:
            L10n.string("Your signer is signed in to a different account.")
        case .ExternalSignerRejected:
            L10n.string("Your signer declined the request.")
        case .Nip46(let reason):
            nip46Message(reason)

        // MARK: People and invitations
        case .MissingKeyPackage(_, .obsoleteOnly):
            L10n.string("This person's app is out of date. Ask them to update it and open it, then try again.")
        case .MissingKeyPackage:
            L10n.string(
                "This person has no compatible invitation key available. Ask them to open White Noise and try again.")
        case .InvalidKeyPackageEvent:
            L10n.string("This person’s invitation key can’t be used. Ask them to open White Noise and try again.")
        case .MissingMemberInboxRoute:
            L10n.string("This person has no inbox relay White Noise can use, so they can’t be invited yet.")
        case .DirectoryLookupIncomplete:
            L10n.string("Couldn't finish looking this person up on relays. Check your connection and try again.")
        case .InvalidIdentity:
            L10n.string("That isn’t a valid public key.")
        case .FollowListUnavailable:
            L10n.string("Couldn't reach your relays to update your follow list. Nothing changed — try again.")
        case .FollowListTooLarge:
            L10n.string("Your follow list is too large to change here. No follows were changed.")

        // MARK: Groups
        case .UnknownGroup:
            L10n.string("This chat is no longer available on this Mac.")
        case .GroupInviteNotPending:
            L10n.string("This invitation is no longer pending.")
        case .CreatedGroupProjectionUnavailable:
            L10n.string("The chat was created but isn’t showing yet. It will appear shortly, so don’t create it again.")
        case .GroupHydrationPending:
            L10n.string("This chat is still loading. Try again in a moment.")
        case .DirectConversationIndexNotReady, .ChatPresentationNotReady, .ConversationWindowNotReady:
            L10n.string("Your chats are still loading. Try again in a moment.")
        case .NotGroupAdmin:
            L10n.string("Only admins of this group can do that.")
        case .AdminCannotSelfRemove:
            L10n.string("Step down as admin before you leave this group.")
        case .LeaveAlreadyRequested:
            L10n.string("You’re already leaving this group.")
        case .LeaveNotBlocked:
            L10n.string("This leave is no longer blocked.")
        case .WouldRemoveLastAdmin:
            L10n.string("A group needs at least one admin. Make another member an admin first.")
        case .DisbandingUnsupportedMembers:
            L10n.string("Some members’ apps can’t end this group yet. Ask them to update White Noise.")
        case .DisbandingNotEnabled:
            L10n.string("Ending this group isn’t turned on for it.")
        case .AccountDevicesActivationRefused:
            L10n.string("This group can’t use multiple devices yet.")
        case .GroupDisbanding:
            L10n.string("This group is ending, so it can’t be changed.")
        case .GroupRemoved:
            L10n.string("You were removed from this group and can no longer send messages here.")
        case .GroupCatchingUp:
            L10n.string("Group not changed. Try again once this chat has synced.")
        case .GroupCommitUndelivered:
            L10n.string("Group not changed. Try again once the last change has reached every relay.")
        case .GroupRecoveryUnsettled:
            L10n.string("This chat is still settling. Try rejoining again in a moment.")
        case .GroupRecoverySourceMismatch:
            L10n.string("This rejoin offer is no longer current. Review the latest offer and try again.")
        case .MemberNotInGroup:
            L10n.string("This person isn’t a member of this group.")
        case .AlreadyAdmin:
            L10n.string("This person is already an admin.")
        case .NotAdmin:
            L10n.string("This person isn’t an admin.")

        // MARK: Media
        case .MediaAttachmentRejected(let kind, _):
            kind == .unsupportedFormat
                ? L10n.string("Unsupported attachment")
                : L10n.string("Attachment couldn’t be read")
        case .InvalidMediaReference:
            L10n.string("This attachment can’t be sent in this chat.")
        case .AttachmentModeRequired:
            L10n.string("Download settings need to be refreshed. Reopen the app and try again.")
        case .AttachmentAccountSignedOut:
            L10n.string("Sign in to download attachments.")
        case .MediaUnfetchable:
            L10n.string("No safe download location is available for this attachment.")
        case .MediaDownloadFailed:
            L10n.string("Attachment download failed. Please try again.")
        case .MediaReferenceStaleEpoch:
            L10n.string("The group changed before this attachment was sent. Attach the file again.")
        case .MediaReferenceEpochUnsettled:
            L10n.string("This chat is still syncing. Wait a moment, then send the attachment again.")

        // MARK: Stickers
        case .InvalidSticker:
            L10n.string("This sticker pack isn’t valid.")
        case .StickerNotFound:
            L10n.string("Couldn’t find this sticker pack.")
        case .StickerNetwork:
            L10n.string("Couldn’t reach the sticker pack’s relays. Check your connection and try again.")
        case .StickerImport, .StickerImportUnsupported:
            L10n.string("This sticker pack can’t be imported.")

        // MARK: Emoji sets
        case .InvalidEmojiSet:
            L10n.string("This emoji set isn’t valid, or none of its emoji could be installed.")
        case .EmojiSetNotFound:
            L10n.string("Couldn’t find this emoji set.")
        case .EmojiSetNetwork:
            L10n.string("Couldn’t reach the emoji set’s relays or image hosts. Check your connection and try again.")
        case .EmojiSetChanged:
            L10n.string("This emoji set was updated. Review the new version, then install it.")
        case .EmojiSetLimit:
            L10n.string("You’ve reached the limit for installed emoji. Remove a set, then try again.")
        case .EmojiImageTooLarge:
            L10n.string("An emoji in this set is too large to install.")
        case .EmojiImageUnsupported:
            L10n.string("An emoji in this set uses an unsupported image format.")
        case .EmojiSetInstallCancelled:
            L10n.string("Emoji set installation was cancelled.")

        // MARK: Storage and runtime
        case .StorageFull:
            L10n.string("This device is out of storage. Free up some space and try again.")
        case .StorageBusy:
            L10n.string("White Noise is busy saving. Try again in a moment.")
        case .StorageClosed, .RuntimeStopping:
            L10n.string("White Noise is shutting down. Reopen it, then try again.")
        case .RuntimeBusy:
            L10n.string("Another copy of White Noise is using this data. Quit it, then try again.")
        case .ConversationWindowTimedOut:
            L10n.string("This chat took too long to load. Please try again.")
        case .ConversationWindowMessageNotRetained, .ConversationWindowInvalidTarget,
            .ConversationWindowAnchorOutside, .ChatWindowAnchorOutside:
            L10n.string("The selected message is no longer available.")

        // Host or core faults: a malformed request, a stale or closed window, an internal error.
        // Nothing the user did can be corrected from the message, and the details are for logs.
        case .InvalidProductAnalyticsConfiguration, .InvalidProductObservation, .InvalidGroupMembershipPage,
            .InvalidCachedIdentityPage, .InvalidPublicEventReferences, .InvalidChatPin, .InvalidMessageDraft,
            .InvalidHex, .InvalidAppComponent, .InvalidChatListQuery, .ChatWindowInvalidLimit, .ChatWindowStale,
            .ChatWindowClosed, .ChatWindowQuery, .ConversationWindowInvalidLimit, .ConversationWindowStale,
            .ConversationWindowWrongGeneration, .ConversationWindowClosed, .ConversationWindowQuery,
            .ConversationWindowPresentation, .Runtime:
            L10n.string("Something went wrong. Please try again.")
        }
    }

    /// Every relay that would carry it refuses it for size. Since MarmotKit 0.16.0 MDK knows
    /// relay limits (the White Noise preset, the deployment list and relays' NIP-11 documents) and
    /// refuses up front, so nothing was sent and nothing is retried: the user has to change what
    /// they are sending.
    private static func eventTooLargeMessage(_ artifact: OversizedArtifactFfi) -> String {
        switch artifact {
        case .applicationMessage:
            L10n.string(
                "This chat's relays refused this message because it's too large. Shorten it or send fewer attachments."
            )
        case .welcome:
            // A create or invite whose Welcome fits none of an invitee's inbox relays: nothing was
            // created or sent.
            L10n.string(
                "The invitation is too large for this person's inbox relays, so it wasn't sent. Try inviting fewer people at once."
            )
        case .commit:
            L10n.string("This group change is too large for this chat's relays, so it wasn't made.")
        case .other:
            // Account-level publishes: KeyPackage, block list, sticker list, profile, follow and
            // relay lists.
            L10n.string("Your relays refused this update because it's too large. Nothing was changed.")
        }
    }

    /// The app has no NIP-46 sign-in yet, so these reach the user only through an account some
    /// other client set up; the wording stays with what the user can do about their signer.
    private static func nip46Message(_ reason: Nip46ErrorFfi) -> String {
        switch reason {
        case .Rejected, .Cancelled:
            L10n.string("Your signer declined the request.")
        case .Mismatch:
            L10n.string("Your signer is signed in to a different account.")
        case .LoggedOut:
            L10n.string("Your signer signed this account out. Connect it again to continue.")
        case .PermissionApprovalRequired:
            L10n.string("Review and approve your signer's permissions, then try again.")
        case .Timeout, .Unavailable, .RelayPublish, .Disconnected, .Busy:
            L10n.string("Your signer is unavailable.")
        case .Invalid, .ProxyConfig, .Unsupported, .Storage, .RequestNotFound:
            L10n.string("Something went wrong with your signer. Please try again.")
        }
    }

    /// Framework errors can echo input. Never let a secret key or a long hex blob reach the UI.
    private static func sanitized(_ raw: String) -> String {
        String(
            raw
                .replacing(/nsec1[a-z0-9]+/.ignoresCase(), with: "nsec1…")
                .replacing(/[0-9a-fA-F]{64,}/, with: "…")
                .prefix(4_000)
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
