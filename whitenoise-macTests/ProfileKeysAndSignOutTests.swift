//
//  ProfileKeysAndSignOutTests.swift
//  whitenoise-macTests
//
//  The two surfaces that handle key material and the way out of an account: the Profile Keys
//  page's export rules, and the sign-out sheet's type-to-confirm gate.
//

import Foundation
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

@Suite
struct ProfileKeysSourceContractTests {
    private static func viewsDirectory() -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "whitenoise-mac")
            .appending(path: "Views")
    }

    private static func source(_ relativePath: String...) throws -> String {
        var url = viewsDirectory()
        for component in relativePath { url = url.appending(path: component) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Comment lines dropped, so an absence check reads the declarations rather than the paragraph
    /// explaining what the file no longer carries. Naming a removed group in the prose above the
    /// code is not the same as reintroducing it — the same helper the drawer's contracts use.
    private static func strippingCommentLines(_ source: some StringProtocol) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Only a source contract can guard absent chrome: no behavior test can observe a page header
    /// that is never built, or a group that is no longer there.
    @Test func theProfileKeysPageCarriesNoSubtitleAccountRowOrRemovalGroup() throws {
        let page = Self.strippingCommentLines(try Self.source("Settings", "ProfileKeysSettingsView.swift"))

        #expect(page.contains("SettingsScaffold(title: L10n.string(\"Profile Keys\"))"))
        // A subtitle is passed as an argument, so its absence is the absence of the argument.
        #expect(!page.contains("subtitle:"))
        #expect(!page.contains("Identity & Keys"))
        // The Account group's two ingredients: the page draws no avatar and reports no signing
        // mode. Which identity the page acts on is the drawer's profile card and the account rail.
        #expect(!page.contains("ProfileImageAvatarView("))
        #expect(!page.contains("accountSigningDescription"))
        // Removal moved to the sign-out sheet, whole.
        #expect(!page.contains("removeActiveAccount"))
        #expect(!page.contains("removeAccountConfirmation"))
        #expect(!page.contains("Account Removal"))

        // And the three groups the prototype's spec names are the three that are there.
        for header in ["Public Key", "Private Key", "Export"] {
            #expect(page.contains("L10n.string(\"\(header)\")"), "missing the \(header) group")
        }
    }

    /// The privacy contract this page inherited from the backup sheet it replaced. On macOS the
    /// eye, the copy button and the raw export all go through the core's `revealNsec`, which writes
    /// an audit line and downgrades that account's audit data mode — so the page has to say so.
    /// A test comment cannot defend dropping it; the shipped string is the promise.
    @Test func thePrivateKeyGroupDisclosesTheAuditLog() throws {
        let page = try Self.source("Settings", "ProfileKeysSettingsView.swift")

        #expect(
            page.contains(
                "White Noise notes the date and time of each reveal, copy or export in this account's audit log"
            ))
        #expect(page.contains("Your private key is never written to the log."))
        // The concealed value must never be spoken, even while it is on screen: a screen reader
        // reading an nsec aloud is the one disclosure the eye control cannot take back.
        #expect(page.contains(".privacySensitive()"))
        #expect(page.contains(".accessibilityHidden(true)"))
    }

    /// The encrypted-export sheet reads the shared `lastError`, so it has to start from a clean
    /// one. Nothing else clears it on the way in, and a failure from minutes earlier — a profile
    /// save, a relay write — would render under the password fields as though this sheet had
    /// produced it. Only a source contract can guard the absence of a stale read.
    @Test func theEncryptedExportSheetClearsTheSharedErrorBeforeShowingOne() throws {
        let sheet = try Self.source("Settings", "EncryptedPrivateKeyExportSheet.swift")

        #expect(sheet.contains("workspace.lastError = nil"))
        // It still shows one: the export flow sets its own, and the sheet is where it is read.
        #expect(sheet.contains("SettingsErrorView(error: error)"))
        // Dismiss stays gated on a written file, which is why an error has somewhere to be read.
        #expect(sheet.contains("if await workspace.exportActiveAccountPrivateKey(.encrypted, passphrase: password) {"))
    }

    /// The sheet is the whole confirmation task. A second alert on top of it would ask the same
    /// question twice and give the reader two places to look for what is about to happen.
    @Test func theSignOutSheetOwnsBothExitsAndStacksNoAlert() throws {
        let sheet = try Self.source("Settings", "SignOutSheet.swift")

        #expect(sheet.contains("workspace.signOutAccount(account)"))
        #expect(sheet.contains("workspace.removeAccount(account)"))
        #expect(!sheet.contains(".confirmationDialog"))
        #expect(!sheet.contains(".alert("))
        // Off by default: the promise Sign Out has always made on this app is that the account's
        // local data stays. Arming the wipe on open would quietly invert it.
        #expect(sheet.contains("@State private var wipesLocalData = false"))
        // Drawn as `WNToggle`, not a bare `Toggle`. A sheet is its own presentation and inherits
        // none of `ContentView`'s tint, so an untinted switch here falls back to the blue system
        // accent — the exact defect that component exists to remove, and the reason the app has
        // no bare switch left.
        #expect(sheet.contains("WNToggle(isOn: $wipesLocalData)"))
        // One button, one label, in one place, armed or not.
        #expect(sheet.contains(".buttonStyle(.wnDestructive)"))
        #expect(sheet.contains("AccountWipeConfirmation.matches"))
        // A failed teardown has to stay on screen. Both `signOutAccount` and `removeAccount` clear
        // `lastError` on entry and set it from their `catch`, so dismissing unconditionally would
        // take the sheet's own `SettingsErrorView` away with the error still unread and leave the
        // reader unsure whether they are signed in. Only a clean run closes the sheet.
        #expect(sheet.contains("guard workspace.lastError == nil else { return }"))
        // And the shared error is cleared on the way in, so the gate above can only ever see an
        // error this sheet produced — otherwise an earlier profile or relay failure would both
        // render here and stop a successful sign-out from dismissing.
        #expect(sheet.contains("workspace.lastError = nil"))

        // And the two confirmations it replaced are gone rather than merely unreferenced.
        let settings = Self.viewsDirectory().appending(path: "Settings")
        for removed in ["SignOutConfirmation.swift", "RemoveAccountConfirmation.swift"] {
            #expect(
                !FileManager.default.fileExists(atPath: settings.appending(path: removed).path),
                "\(removed) is back")
        }
    }

    /// The drawer's Sign Out row is the only way out of an account, and it opens the sheet rather
    /// than the dialog it used to raise.
    @Test func theDrawerSignOutRowOpensTheSheet() throws {
        let sidebar = try Self.source("SidebarViews.swift")
        let start = try #require(sidebar.range(of: "struct SettingsSignOutRow: View {")?.upperBound)
        let rest = sidebar[start...]
        let end = rest.range(of: "\nstruct ")?.lowerBound ?? sidebar.endIndex
        let row = String(sidebar[start..<end])

        #expect(row.contains("SignOutSheet(account: account)"))
        #expect(!row.contains("signOutConfirmation"))
        #expect(!row.contains("workspace.signOutAccount"), "the sheet decides which teardown runs")
    }

    /// The destructive tier is a ground, not a quiet button with red text — the thing
    /// `WNSecondaryButtonStyle`'s own documentation says a genuinely destructive action wants.
    @Test func theDestructiveTierDrawsAFillDestructiveGroundFromTheSharedShapeTable() throws {
        let style = try Self.source("WNDestructiveButtonStyle.swift")

        #expect(style.contains("WNColor.fillDestructive"))
        #expect(style.contains("WNColor.fillDestructiveHover"))
        #expect(style.contains("WNColor.fillDestructiveActive"))
        // Paired content, never a `backgroundContent*` token — see the pairing rule in `WNNSColor`.
        #expect(style.contains("WNColor.fillContentQuaternary"))
        #expect(!style.contains("backgroundContentDestructive"))
        // Disabled swaps to the neutral pair rather than fading red, so a gate that has not been
        // cleared cannot look like a live destructive button.
        #expect(style.contains("WNColor.fillDisabled"))
        #expect(style.contains("WNColor.fillContentDisabled"))
        // No radius of its own: one table, or the tiers drift apart again.
        #expect(style.contains("WNButtonMetrics.backgroundShape("))
        #expect(!style.contains("cornerRadius: "))
    }
}
