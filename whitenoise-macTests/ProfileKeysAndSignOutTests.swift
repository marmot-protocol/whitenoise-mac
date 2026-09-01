//
//  ProfileKeysAndSignOutTests.swift
//  whitenoise-macTests
//
//  The two surfaces that handle key material and the way out of an account: the Profile Keys
//  page's export rules, and the sign-out sheet's type-to-confirm gate.
//

import AppKit
import Foundation
import MarmotKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import whitenoise_mac

@Suite
struct AccountWipeConfirmationTests {
    @Test func theChallengeIsTheAccountName() {
        // The common shape: the core reports a label, and `AccountItem` uses it as both the ref and
        // the display name. `DisplayText.short` returns a short string unchanged, so this name is
        // equal to its own shortened form — which must not be read as the derived placeholder, or
        // every account named in under 18 characters would be asked for the fallback instead.
        #expect(
            AccountWipeConfirmation.challenge(
                displayName: "Marmota",
                accountRef: "Marmota",
                fallback: "WIPE"
            ) == "Marmota")
        #expect(
            AccountWipeConfirmation.challenge(
                displayName: "Marmota",
                accountRef: String(repeating: "a", count: 64),
                fallback: "WIPE"
            ) == "Marmota")
    }

    @Test func theChallengeFallsBackWhenTheNameIsTheDerivedPlaceholder() {
        // `AccountItem(summary:)` leaves `displayName` as `DisplayText.short(accountRef)` when the
        // core has no profile metadata and no label — a truncated hex id with an ellipsis in the
        // middle. Asking someone to type that would lock them out of a flow they are entitled to
        // complete, so the gate falls back to a word. Recognised by recomputing the placeholder
        // rather than by guessing at hex-shaped strings.
        let accountRef = String(repeating: "a", count: 64)
        let placeholder = DisplayText.short(accountRef)
        #expect(placeholder.contains("..."))
        #expect(
            AccountWipeConfirmation.challenge(
                displayName: placeholder,
                accountRef: accountRef,
                fallback: "WIPE"
            ) == "WIPE")
    }

    @Test func theChallengeFallsBackWhenTheNameIsBlank() {
        for name in ["", "   ", "\n"] {
            #expect(
                AccountWipeConfirmation.challenge(
                    displayName: name,
                    accountRef: "label",
                    fallback: "WIPE"
                ) == "WIPE")
        }
    }

    @Test func aRealNameIsTrimmedButNotOtherwiseTouched() {
        #expect(
            AccountWipeConfirmation.challenge(
                displayName: "  Open Circuit  ",
                accountRef: "label",
                fallback: "WIPE"
            ) == "Open Circuit")
    }

    @Test func matchingIgnoresSurroundingWhitespaceAndCase() {
        // The gate is a speed bump, not a password: someone who typed their own display name with
        // the wrong capitalisation has demonstrated exactly the intent it checks for. Rejecting
        // that only teaches people to paste, which defeats the point of typing.
        #expect(AccountWipeConfirmation.matches("  marmota ", challenge: "Marmota"))
        #expect(AccountWipeConfirmation.matches("WIPE", challenge: "WIPE"))
        #expect(AccountWipeConfirmation.matches("wipe", challenge: "WIPE"))
    }

    @Test func matchingRejectsAnythingElse() {
        #expect(!AccountWipeConfirmation.matches("", challenge: "Marmota"))
        #expect(!AccountWipeConfirmation.matches("Marmot", challenge: "Marmota"))
        #expect(!AccountWipeConfirmation.matches("Marmota ok", challenge: "Marmota"))
        // An empty challenge must never be clearable, or a `displayName`/`fallback` pair that both
        // came out empty would arm the destructive button with an empty field.
        #expect(!AccountWipeConfirmation.matches("", challenge: ""))
        #expect(!AccountWipeConfirmation.matches("anything", challenge: ""))
    }
}

@Suite
struct PrivateKeyExportTests {
    @Test func theTwoKindsTakeDifferentFilenames() {
        // A raw and an encrypted export landing in the same folder must not collide, and the reader
        // has to be able to tell them apart afterwards — the encrypted one is useless without the
        // password, the raw one is the account.
        let names = Set(PrivateKeyExportKind.allCases.map(\.suggestedFilenameKey))
        #expect(names.count == PrivateKeyExportKind.allCases.count)
        #expect(PrivateKeyExportKind.encrypted.suggestedFilenameKey == "White Noise Encrypted Private Key")
        #expect(PrivateKeyExportKind.raw.suggestedFilenameKey == "White Noise Private Key")
    }

    @Test func bothKindsWriteTheKeyAsOneLineOfPlainText() {
        // Other Nostr clients' importers read a bech32 string, so the file is the key and a
        // newline — never a wrapper format that only this app can open.
        for kind in PrivateKeyExportKind.allCases {
            #expect(kind.contentType == .plainText)
            let data = kind.fileContents(forKeyMaterial: "nsec1abc")
            #expect(String(decoding: data, as: UTF8.self) == "nsec1abc\n")
        }
    }

    @Test func passwordStrengthLeadsWithLength() {
        // Length is what a scrypt-hardened file actually benefits from, so a long lowercase
        // passphrase outranks a short scramble of four character classes.
        #expect(PrivateKeyExportPasswordStrength.evaluate("") == .low)
        #expect(PrivateKeyExportPasswordStrength.evaluate("Tr0ub4dor&3") == .low)
        #expect(PrivateKeyExportPasswordStrength.evaluate("correcthorsebattery") == .fair)
        #expect(PrivateKeyExportPasswordStrength.evaluate("correct horse battery 9!") == .strong)
    }

    @Test func varietyOnlyLiftsAPasswordThatIsAlreadyLongEnough() {
        // Sixteen characters is the floor for `strong`; below it, variety cannot buy the top rung.
        #expect(PrivateKeyExportPasswordStrength.evaluate("aB3$aB3$aB3$aB3") == .fair)
        #expect(PrivateKeyExportPasswordStrength.evaluate("aB3$aB3$aB3$aB3$") == .strong)
        // …and at sixteen, missing any one class holds it at `fair`.
        #expect(PrivateKeyExportPasswordStrength.evaluate("abcdefghijklmnop") == .fair)
        #expect(PrivateKeyExportPasswordStrength.evaluate("abcdefghijklmn12") == .fair)
        #expect(PrivateKeyExportPasswordStrength.evaluate("abcdefghijklmn1!") == .strong)
    }

    @Test func everyRungHasALabelAndFitsTheBar() {
        for strength in PrivateKeyExportPasswordStrength.allCases {
            #expect(!strength.labelKey.isEmpty)
            #expect(Double(strength.rawValue) <= PrivateKeyExportPasswordStrength.scale)
            #expect(strength.rawValue >= 1)
        }
        #expect(PrivateKeyExportPasswordStrength.low < .fair)
        #expect(PrivateKeyExportPasswordStrength.fair < .strong)
    }

    @Test func exportNeedsTwoMatchingNonEmptyPasswords() {
        // An empty password would produce an `ncryptsec1` file anyone can open, which is worse
        // than the plaintext export because it looks protected.
        #expect(!PrivateKeyExportPasswordEntry.isReady(password: "", confirmation: ""))
        #expect(!PrivateKeyExportPasswordEntry.isReady(password: "secret", confirmation: ""))
        #expect(!PrivateKeyExportPasswordEntry.isReady(password: "secret", confirmation: "secrets"))
        #expect(PrivateKeyExportPasswordEntry.isReady(password: "secret", confirmation: "secret"))
    }

    @Test func theMismatchNoteWaitsForTheFirstKeystroke() {
        // Shown in place of the field guidance, so it must not appear while the confirmation is
        // still empty — the reader has not disagreed with anything yet.
        #expect(!PrivateKeyExportPasswordEntry.showsMismatch(password: "secret", confirmation: ""))
        #expect(PrivateKeyExportPasswordEntry.showsMismatch(password: "secret", confirmation: "s"))
        #expect(!PrivateKeyExportPasswordEntry.showsMismatch(password: "secret", confirmation: "secret"))
    }
}

/// The two key surfaces as the reader meets them: what the Profile Keys page is made of, what it
/// promises about the audit log, and every rule standing between a click on the sign-out sheet and
/// an erased account.
///
/// `.serialized` and `@MainActor` because the destructive-tier test rasterizes under a chosen
/// `NSAppearance`, and `performAsCurrentDrawingAppearance` off the main actor takes the test host
/// down with it.
@Suite(.serialized)
@MainActor
struct ProfileKeysAndSignOutSurfaceTests {
    static func localSigningAccount() -> AccountSummaryFfi { desktopAccount() }

    /// Three groups and no fourth.
    ///
    /// The page used to open with a subtitle and an Account group — an avatar and a line reporting
    /// the signing mode — restating an identity the reader had just come through the drawer's
    /// profile card to reach, and it used to end with Account Removal, which now lives whole inside
    /// the sign-out sheet where the confirmation is. The page is built from this list, so a fourth
    /// group is an edit here rather than a stack that quietly grew one.
    @MainActor
    @Test func theProfileKeysPageIsThreeGroupsAndTheExportOneNeedsALocalKey() {
        #expect(
            ProfileKeysPageContents.groups(localSigning: true) == [.publicKey, .privateKey, .export]
        )
        // An externally-signed account has no key on this Mac, so there is nothing to export.
        #expect(ProfileKeysPageContents.groups(localSigning: false) == [.publicKey, .privateKey])

        for group in ProfileKeysPageContents.groups(localSigning: true) {
            #expect(!L10n.string(group.titleKey).isEmpty, "\(group) has no heading")
        }
    }

    /// The privacy contract this page inherited from the backup sheet it replaced.
    ///
    /// On macOS the eye, the copy button and the raw export all go through the core's `revealNsec`,
    /// which writes an audit line and downgrades that account's audit data mode — so the page has to
    /// say so, and has to say the key itself is not written down. A comment cannot make that
    /// promise; the shipped string is the promise, which is why it is asserted word for word.
    @MainActor
    @Test func thePrivateKeyGroupDisclosesTheAuditLogInTheShippedWords() {
        let disclosure = ProfileKeysPageContents.auditLogDisclosure

        #expect(
            disclosure.contains(
                "White Noise notes the date and time of each reveal, copy or export in this account's audit log"
            )
        )
        #expect(disclosure.contains("Your private key is never written to the log."))
    }

    /// An export starts from a clean error, so the sheet above it can only ever be showing one this
    /// export produced.
    ///
    /// `lastError` is shared app-wide state. A failure from minutes ago — a profile save, a relay
    /// write — used to render under the password fields as though this export had produced it, and
    /// would stop a successful export from ever dismissing the sheet, since the sheet closes only on
    /// a clean run.
    @MainActor
    @Test func anExportClearsTheSharedErrorOnTheWayIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-export-error-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = FakeMarmotRuntime(accounts: [Self.localSigningAccount()])
        let destination = root.appending(path: "key.txt")
        let state = WorkspaceState(
            privateKeyExportDestinationPicker: { _, _ in destination },
            clientFactory: { runtime }
        )
        await state.bootstrap()

        // A failure left behind by something else entirely.
        state.lastError = "Could not reach relay.example.com"

        let didExport = await state.exportActiveAccountPrivateKey(PrivateKeyExportKind.encrypted, passphrase: "secret")

        #expect(didExport)
        #expect(
            state.lastError == nil,
            "the sheet would render a stale failure as though this export had produced it"
        )
        #expect(SignOutSheetDecisions.dismissesAfterTeardown(lastError: state.lastError))
    }

    /// The sheet is the whole confirmation task, so every rule standing between a click and an
    /// erased account is one of these.
    ///
    /// A second alert on top of it would ask the same question twice and give the reader two places
    /// to look for what is about to happen — so both exits are decided here, by one toggle and one
    /// button.
    @MainActor
    @Test func theSignOutSheetOwnsBothExitsBehindOneToggleAndOneGate() {
        // Off by default: the promise Sign Out has always made on this app is that the account's
        // local data stays. Arming the wipe on open would quietly invert it for everyone who signs
        // out without reading.
        #expect(!SignOutSheetDecisions.wipesLocalDataByDefault)
        #expect(
            SignOutSheetDecisions.teardown(wipesLocalData: SignOutSheetDecisions.wipesLocalDataByDefault)
                == .signOut
        )
        #expect(SignOutSheetDecisions.teardown(wipesLocalData: true) == .removeAccount)

        // The type-to-confirm gate is what the armed toggle costs, and only then.
        #expect(
            SignOutSheetDecisions.canSignOut(isTearingDown: false, wipesLocalData: false, isConfirmed: false)
        )
        #expect(
            !SignOutSheetDecisions.canSignOut(isTearingDown: false, wipesLocalData: true, isConfirmed: false),
            "a wipe ran without the account's name being typed"
        )
        #expect(
            SignOutSheetDecisions.canSignOut(isTearingDown: false, wipesLocalData: true, isConfirmed: true)
        )
        // And nothing is armed while a teardown is already running.
        #expect(
            !SignOutSheetDecisions.canSignOut(isTearingDown: true, wipesLocalData: false, isConfirmed: true)
        )

        // A failed teardown stays on screen: dismissing would take the sheet's own error view away
        // with the error still unread, leaving the reader unsure whether they are signed in.
        #expect(SignOutSheetDecisions.dismissesAfterTeardown(lastError: nil))
        #expect(!SignOutSheetDecisions.dismissesAfterTeardown(lastError: "Sign out failed"))

        // Both progress labels say which teardown is running, since the two take different times
        // and only one of them is destructive.
        #expect(!L10n.string(SignOutTeardown.signOut.progressLabelKey).isEmpty)
        #expect(!L10n.string(SignOutTeardown.removeAccount.progressLabelKey).isEmpty)
        #expect(
            SignOutTeardown.signOut.progressLabelKey != SignOutTeardown.removeAccount.progressLabelKey
        )
    }

    /// Both exits actually reach the core, and the wipe is the one that takes the account off this
    /// Mac.
    @MainActor
    @Test func theSheetsTwoExitsRunTheTwoDifferentTeardowns() async throws {
        for teardown in [SignOutTeardown.signOut, .removeAccount] {
            let account = Self.localSigningAccount()
            let runtime = FakeMarmotRuntime(accounts: [account])
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            let active = try #require(state.activeAccount)

            switch teardown {
            case .signOut:
                await state.signOutAccount(active)
            case .removeAccount:
                await state.removeAccount(active)
            }

            #expect(state.lastError == nil)
            #expect(state.activeAccount == nil)
            #expect(state.signedInAccounts.isEmpty)

            switch teardown {
            case .signOut:
                #expect(!state.accounts.isEmpty, "signing out must leave the account on this Mac")
            case .removeAccount:
                #expect(state.accounts.isEmpty, "the wipe left the account behind")
            }
        }
    }

    /// Signing out is a decision the sheet takes, not the row that opens it.
    ///
    /// The drawer's row used to raise a confirmation dialog and, before that, to call the teardown
    /// itself. What replaced both is `SignOutSheet` — and the rule that matters is that the *sheet*
    /// chooses which teardown runs, from its toggle, so nothing upstream of it can pick one.
    @MainActor
    @Test func whichTeardownRunsIsTheSheetsDecisionAndNotItsCallers() {
        #expect(SignOutSheetDecisions.teardown(wipesLocalData: false) == .signOut)
        #expect(SignOutSheetDecisions.teardown(wipesLocalData: true) == .removeAccount)
        #expect(SignOutTeardown.signOut != SignOutTeardown.removeAccount)
    }

    /// The destructive tier is a ground, not a quiet button with red text.
    ///
    /// Rasterized and read back rather than named in source: what the reader has is a red button,
    /// and the specific regression — a disabled destructive button that still looks live — is a
    /// colour question that only a render can answer. Disabled swaps to the neutral pair, so a gate
    /// that has not been cleared cannot look like an armed one.
    @MainActor
    @Test func theDestructiveTierDrawsARedGroundAndFadesToNeutralWhenDisabled() throws {
        func fill(disabled: Bool, appearance: NSAppearance.Name) throws -> NSColor {
            let button = Button(L10n.string("Sign Out")) {}
                .buttonStyle(.wnDestructive)
                .controlSize(.large)
                .disabled(disabled)
                .padding(20)
                .background(WNColor.backgroundPrimary)
            let rep = try #require(HostedView.render(button, appearance: appearance, scale: 2))
            return try #require(
                rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            )
        }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let armed = try fill(disabled: false, appearance: appearance)
            let gated = try fill(disabled: true, appearance: appearance)

            // Red, by a wide margin, in both appearances — the palette's `fillDestructive`.
            #expect(
                armed.redComponent > armed.greenComponent + 0.25,
                "the armed destructive button is not drawing a red ground in \(appearance.rawValue)"
            )
            #expect(armed.redComponent > armed.blueComponent + 0.25)

            // …and the disabled one is a neutral, not a faded red.
            let spread =
                max(gated.redComponent, gated.greenComponent, gated.blueComponent)
                - min(gated.redComponent, gated.greenComponent, gated.blueComponent)
            #expect(
                spread < 0.12,
                "a gate that has not been cleared still looks like a live destructive button in \(appearance.rawValue)"
            )
        }

        // No radius of its own: the tier asks the one shape table, like every other.
        let rect = CGRect(x: 0, y: 0, width: 180, height: 44)
        #expect(
            WNButtonMetrics.backgroundShape(.rounded, for: .large).path(in: rect)
                == RoundedRectangle(
                    cornerRadius: WNButtonMetrics.cornerRadius(for: .large), style: .continuous
                ).path(in: rect)
        )
    }
}
