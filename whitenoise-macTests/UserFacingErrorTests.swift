import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// `UserFacingError` turns every `MarmotKitError` into localized copy. The core's `details` are
/// diagnostics: they are English, can carry ids, and must never reach the screen.
struct UserFacingErrorTests {
    private static let secretDetail = "nsec1qqqqqqqqqqqqqqqqqqqqqqqq relay wss://example failed for 0123abcd"

    /// Every case that carries free-text details, so a new mapping that forwards them is caught.
    private static let detailCarryingErrors: [MarmotKitError] = [
        .InvalidModerationReportConfig(details: secretDetail),
        .InvalidChatPin(details: secretDetail),
        .InvalidMessageDraft(details: secretDetail),
        .InvalidMediaReference(details: secretDetail),
        .MediaAttachmentRejected(kind: .unsupportedFormat, details: secretDetail),
        .MediaUnfetchable(details: secretDetail),
        .MediaDownloadFailed(details: secretDetail),
        .InvalidHex(details: secretDetail),
        .InvalidIdentity(details: secretDetail),
        .InvalidKeyPackageEvent(details: secretDetail),
        .Publish(details: secretDetail),
        .AccountCatchUp(details: secretDetail),
        .StorageBusy(details: secretDetail),
        .StorageClosed(details: secretDetail),
        .StorageFull(details: secretDetail),
        .SecretNotFound(details: secretDetail),
        .KeystoreUnavailable(details: secretDetail),
        .EncryptionFailed(details: secretDetail),
        .Io(details: secretDetail),
        .InvalidSticker(details: secretDetail),
        .StickerNetwork(details: secretDetail),
        .StickerImport(details: secretDetail),
        .InvalidEmojiSet(details: secretDetail),
        .EmojiSetNetwork(details: secretDetail),
        .EmojiImageTooLarge(details: secretDetail),
        .EmojiImageUnsupported(details: secretDetail),
        .EmojiSetLimit(details: secretDetail),
        .Runtime(details: secretDetail),
        .ChatWindowQuery(details: secretDetail),
        .ConversationWindowQuery(details: secretDetail),
        .ConversationWindowPresentation(details: secretDetail),
        .InvalidAppComponent(details: secretDetail),
    ]

    @Test func coreDetailsNeverReachTheMessage() {
        for error in Self.detailCarryingErrors {
            let message = UserFacingError.message(for: error)
            #expect(!message.isEmpty, "\(error)")
            #expect(!message.contains("nsec1"), "\(error)")
            #expect(!message.contains("wss://"), "\(error)")
            #expect(!message.contains("MarmotKitError"), "\(error)")
        }
    }

    @Test func idsCarriedByACaseAreNeverShown() {
        let groupId = String(repeating: "ab", count: 32)
        let errors: [MarmotKitError] = [
            .UnknownGroup(groupIdHex: groupId),
            .NotGroupAdmin(groupIdHex: groupId),
            .GroupRemoved(groupIdHex: groupId),
            .MemberNotInGroup(groupIdHex: groupId, memberIdHex: groupId),
            .EmojiSetChanged(currentEventIdHex: groupId),
            .MissingKeyPackage(account: groupId, reason: .notFound),
        ]
        for error in errors {
            #expect(!UserFacingError.message(for: error).contains(groupId), "\(error)")
        }
    }

    @Test func anOutdatedRecipientIsToldToUpdateRatherThanToOpenTheApp() {
        let outdated = UserFacingError.message(
            for: MarmotKitError.MissingKeyPackage(account: "a", reason: .obsoleteOnly))
        let missing = UserFacingError.message(for: MarmotKitError.MissingKeyPackage(account: "a", reason: .notFound))
        #expect(outdated != missing)
    }

    @Test func aNonCoreErrorKeepsItsOwnDescriptionWithSecretsRedacted() {
        let error = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Bad key nsec1abcdef0123 and \(String(repeating: "f", count: 64))"])
        let message = UserFacingError.message(for: error)
        #expect(message.hasPrefix("Bad key"))
        #expect(!message.contains("nsec1abcdef0123"))
        #expect(!message.contains(String(repeating: "f", count: 64)))
    }

    @Test func aNonCoreErrorWithNoTextFallsBackToTryAgain() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "  "])
        #expect(UserFacingError.message(for: error) == L10n.string("Please try again."))
    }
}
