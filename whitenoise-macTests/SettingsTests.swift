//
//  SettingsTests.swift
//  whitenoise-macTests
//
//  The Settings pages: profile, keys, relays, notifications, privacy and security,
//  telemetry, launch at login, and the preferences the rest of the app reads.
//
//  Split out of `whitenoise_macTests.swift` verbatim: every test body below is the
//  one that lived in that file, moved rather than rewritten.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MarmotKit
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications

@testable import whitenoise_mac

struct SettingsTests: WorkspaceTestSupport {
    /// A source slice with its comment-only lines dropped.
    ///
    /// A contract that forbids a token cannot read the comments: these files explain at length
    /// precisely which branch they no longer carry, and naming it in the explanation is not the
    /// same as reintroducing it. Dropping the prose is what lets the assertion stay a literal
    /// token search rather than a pattern that has to out-guess English.
    private static func strippingCommentLines(_ source: some StringProtocol) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func accountSwitcherSource() throws -> String {
        try String(
            contentsOf:
                URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "whitenoise-mac")
                .appending(path: "Views")
                .appending(path: "Settings")
                .appending(path: "SettingsAccountSwitcherViews.swift"),
            encoding: .utf8
        )
    }

    /// Settings' profile card carries exactly one action: add a profile. Only a source contract
    /// can guard an absent control — no behavior test can observe a popover that is never built —
    /// and the thing being guarded is that the row does not go back to adapting. It used to read
    /// `Add Account` with one identity signed in on this Mac and `Switch Account` with more, the
    /// second form opening a switcher popover, so the same row meant two different things
    /// depending on state the user had not thought about. Switching identities is the account
    /// rail's job.
    ///
    /// This replaces the popover's own contracts — that it offered no way to create or reactivate
    /// an identity, that its list was fed `signedInAccounts`, that its row kept no signed-out
    /// branch. A deleted view needs none of them; what needs guarding is that it stays deleted.
    @MainActor
    @Test func settingsProfileCardOffersAddProfileUnconditionallyAndNoSwitcher() throws {
        let code = Self.strippingCommentLines(try Self.accountSwitcherSource())

        #expect(code.contains("L10n.string(\"Add Profile\", locale: locale)"))
        #expect(code.contains("person.crop.circle.badge.plus"))
        // The glyph that described switching, on a row that no longer switches.
        #expect(!code.contains("arrow.up.arrow.down"))

        // No switcher, and none of the account management that hung off it.
        #expect(!code.contains("AccountSwitcherPopover"))
        #expect(!code.contains("AccountSwitcherRow"))
        #expect(!code.contains(".popover("))
        #expect(!code.contains("selectAccountFromSettings"))
        #expect(!code.contains("removeAccount"))
        #expect(!code.contains("signOutAccount"))
        #expect(!code.contains("signInAccount"))

        // And the add row is unconditional: no branch on how many identities this Mac holds.
        #expect(!code.contains("accounts.count > 1"))
        #expect(!code.contains("hasOtherSignedInAccount"))
        #expect(!code.contains("Add Account"), "the row states its one job in every state")
        #expect(!code.contains("Switch Account"))
    }

    /// The active profile's avatar is the largest thing in the card, not the smallest thing on
    /// screen. It was 34pt — under both the rail's and the chat row's — which made the one row
    /// about *you* the least prominent identity in the window. `wn-ios-prototype`'s hub gives the
    /// same row its largest avatar.
    @MainActor
    @Test func settingsProfileAvatarMatchesTheAppsOtherIdentityRows() throws {
        #expect(MessagesLayout.settingsProfileAvatarSize == MessagesLayout.accountRailAvatarSize)
        #expect(MessagesLayout.settingsProfileAvatarSize == MessagesLayout.chatRowAvatarSize)
        #expect(MessagesLayout.settingsProfileAvatarSize > 34)

        // The card clips (`SettingsSidebarGroupCard`'s `clipShape`), so the row's own padding has
        // to cover what the avatar's chrome draws outside its frame — otherwise the bigger avatar
        // comes out with a flat edge against the card.
        let source = try Self.accountSwitcherSource()
        #expect(source.contains("size: MessagesLayout.settingsProfileAvatarSize"))
        // The row passes `isSelected: false`, so `selectedScale` never applies and the only chrome
        // reaching past the frame is the shadow's blur.
        #expect(source.contains("isSelected: false"))
        #expect(SettingsSidebarRowMetrics.verticalPadding >= AvatarChromeModifier.shadowRadius)
        #expect(SettingsSidebarRowMetrics.horizontalPadding >= AvatarChromeModifier.shadowRadius)
    }

    @MainActor
    @Test func privateKeyExportAsksForADestinationBeforeItRevealsAnything() async throws {
        // The order is the contract. `revealNsec` is an audited call that downgrades the core's
        // audit data mode for the account, so a save panel the reader cancels must not have cost
        // them that. Cancelling is modelled as a nil from the picker; the assertion is that the
        // runtime was never asked for the key.
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let state = WorkspaceState(
            privateKeyExportDestinationPicker: { _, _ in nil },
            clientFactory: { runtime }
        )
        await state.bootstrap()

        let didExport = await state.exportActiveAccountPrivateKey(.raw)

        #expect(!didExport)
        #expect(runtime.revealNsecCallCount == 0)
        #expect(state.lastError == nil)
        #expect(!state.isExportingPrivateKey)
    }

    @MainActor
    @Test func privateKeyExportWritesTheChosenKindToTheChosenFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-key-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        var requestedFilenames: [String] = []
        var requestedTypes: [UTType] = []
        var nextDestination = root.appendingPathComponent("encrypted.txt")
        let state = WorkspaceState(
            privateKeyExportDestinationPicker: { filename, contentType in
                requestedFilenames.append(filename)
                requestedTypes.append(contentType)
                return nextDestination
            },
            clientFactory: { runtime }
        )
        await state.bootstrap()

        #expect(await state.exportActiveAccountPrivateKey(.encrypted, passphrase: "a long passphrase"))
        #expect(runtime.exportEncryptedSecretKeyCallCount == 1)
        #expect(runtime.revealNsecCallCount == 0)
        #expect(try String(contentsOf: nextDestination, encoding: .utf8) == "ncryptsec1fake\n")

        nextDestination = root.appendingPathComponent("raw.txt")
        #expect(await state.exportActiveAccountPrivateKey(.raw))
        #expect(runtime.revealNsecCallCount == 1)
        #expect(try String(contentsOf: nextDestination, encoding: .utf8) == "nsec1fake\n")

        // The panel is offered the localized name for the kind being written, not one name for
        // both — a raw key and an encrypted one landing in the same folder must not collide.
        #expect(
            requestedFilenames == [
                L10n.string("White Noise Encrypted Private Key"), L10n.string("White Noise Private Key"),
            ])
        #expect(requestedTypes == [.plainText, .plainText])
        #expect(!state.isExportingPrivateKey)
    }

    @MainActor
    @Test func privateKeyExportRefusesAnAccountWithNoLocalKey() async throws {
        // A watch-only or external-signer account has nothing here to write, and the Profile Keys
        // page hides the Export group for it. This is the same rule one level down, so a future
        // call site cannot reach the save panel for a key that does not exist.
        let watchOnly = AccountSummaryFfi(
            label: "Watch Only",
            accountIdHex: String(repeating: "c", count: 64),
            localSigning: false,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [watchOnly])
        var didAskForDestination = false
        let state = WorkspaceState(
            privateKeyExportDestinationPicker: { _, _ in
                didAskForDestination = true
                return nil
            },
            clientFactory: { runtime }
        )
        await state.bootstrap()

        #expect(!(await state.exportActiveAccountPrivateKey(.raw)))
        #expect(!didAskForDestination)
        #expect(runtime.revealNsecCallCount == 0)
    }

    @MainActor
    @Test func privateKeyExportRefusesToWriteWhenTheActiveAccountMovedUnderThePanel() async throws {
        // The injected picker stands exactly where `NSSavePanel.runModal()` would, and a modal
        // panel spins a nested run loop that drains the main queue — so main-actor work queued
        // before it opened can resume while it is up and reselect the active identity. Switching
        // the account from inside the picker reproduces that window precisely.
        //
        // What must not happen is the export continuing against whoever is active *now*: the key
        // material is fetched from `activeAccount`, so a moved identity would write the wrong
        // account's private key into a file the reader asked for while looking at another. The
        // guard sits before the fetch, so nothing is revealed and no audited call is made either.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-key-export-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("key.txt")

        let other = AccountSummaryFfi(
            label: "Second Account",
            accountIdHex: String(repeating: "d", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount(), other])
        var state: WorkspaceState!
        var switchedTo: String?
        state = WorkspaceState(
            privateKeyExportDestinationPicker: { _, _ in
                // Answer the panel *and* move the identity, in that order.
                if let next = state.accounts.first(where: { $0.id != state.activeAccountId })?.id {
                    state.activeAccountId = next
                    switchedTo = next
                }
                return destination
            },
            clientFactory: { runtime }
        )
        await state.bootstrap()

        let didExport = await state.exportActiveAccountPrivateKey(.raw)

        #expect(switchedTo != nil, "the picker must actually have moved the active account")
        #expect(!didExport)
        // Nothing fetched: the guard is ahead of both key helpers, so `revealNsec` — the audited
        // call that downgrades the account's audit data mode — never ran.
        #expect(runtime.revealNsecCallCount == 0)
        #expect(runtime.exportEncryptedSecretKeyCallCount == 0)
        // And nothing written, which is the part that would have been a key on disk under the
        // wrong identity.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!state.isExportingPrivateKey)
    }

    @Test func settingsPageSidebarLabelsFollowRequestedLocale() {
        // Regression: the settings sidebar rows kept the previous language after a switch on
        // the Appearance page because their labels resolved the preference through a cache
        // SwiftUI cannot observe. The labels are locale-parameterized so the rows re-render
        // from the `\.locale` environment value instead of needing a navigation round trip.
        let spanish = Locale(identifier: AppLanguage.spanish.rawValue)
        let german = Locale(identifier: AppLanguage.german.rawValue)

        #expect(SettingsPage.preferences.title(in: german) == "Voreinstellungen")
        #expect(SettingsPage.appearance.title(in: spanish) == "Apariencia")
        #expect(SettingsPage.overview.title(in: spanish) == "Configuración")
    }

    /// A drawer row's glyph is the same colour as its title, in both states.
    ///
    /// `wn-ios-prototype`'s hub draws each row as one `Label(...).foregroundStyle(.primary)`. This
    /// app had the glyph a step down at `backgroundContentSecondary` and lifted it to primary only
    /// on the selected row — and since nine of the ten destinations are unselected at any moment,
    /// the drawer read as a list of disabled options. Selection is carried by
    /// `SettingsSidebarRowBackground`'s fill, which is the only signal the prototype uses.
    ///
    /// A source contract because a `foregroundStyle` is not observable from a test, and it guards
    /// the *single* tint: two colours in `SettingsSidebarRowLabel` would be the old split
    /// reintroduced one level down, where every row inherits it.
    @Test func settingsDrawerRowGlyphTakesTheSameTintAsItsTitle() throws {
        let cardURL =
            URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "whitenoise-mac")
            .appending(path: "Views")
            .appending(path: "Settings")
            .appending(path: "SettingsSidebarGroupCard.swift")
        let cardSource = try String(contentsOf: cardURL, encoding: .utf8)

        let labelStart = try #require(cardSource.range(of: "struct SettingsSidebarRowLabel<Accessory: View>: View {"))
        let labelRest = cardSource[labelStart.upperBound...]
        let labelEnd = try #require(labelRest.range(of: "\nextension ")?.lowerBound)
        // Comments dropped before the whitespace is joined out, so the absence check below reads
        // the declaration rather than the paragraph explaining it.
        let label = Self.strippingCommentLines(String(cardSource[labelStart.lowerBound..<labelEnd]))
            .components(separatedBy: .whitespacesAndNewlines).joined()

        // One tint, applied to both the glyph and the title.
        #expect(label.contains("SettingsSidebarRowGlyph(systemImage:systemImage,tint:tint)"))
        #expect(label.contains("Text(title)"))
        #expect(label.contains(".foregroundStyle(tint)"))
        #expect(!label.contains("backgroundContentSecondary"))

        // The default is the primary content colour, which is what "darker" meant.
        #expect(cardSource.contains("var tint: Color = WNColor.backgroundContentPrimary"))

        // And the rows go through the atom rather than keeping their own copies of the HStack.
        let sidebarURL =
            URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "whitenoise-mac")
            .appending(path: "Views")
            .appending(path: "SidebarViews.swift")
        let sidebarSource = try String(contentsOf: sidebarURL, encoding: .utf8)
        let rowStart = try #require(sidebarSource.range(of: "struct SettingsSidebarRow: View {"))
        let rowRest = sidebarSource[rowStart.upperBound...]
        let rowEnd = try #require(rowRest.range(of: "\nstruct ")?.lowerBound)
        let rowSource = String(sidebarSource[rowStart.lowerBound..<rowEnd])

        #expect(rowSource.contains("SettingsSidebarRowLabel(systemImage: page.systemImage"))
        #expect(!Self.strippingCommentLines(rowSource).contains("backgroundContentSecondary"))
        // The selection signal that replaced the tint split has to still be there.
        #expect(rowSource.contains("SettingsSidebarRowBackground(isSelected: isSelected)"))
    }

    @Test func settingsDrawerLocalizesThroughEnvironmentLocale() throws {
        // The re-render on a language switch comes from a SwiftUI dependency, which only a
        // source contract can guard: both the drawer and its rows must read `\.locale` and
        // localize through it. Dropping either read reintroduces the stale-label bug.
        let sidebarViewsURL =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-mac")
            .appendingPathComponent("Views")
            .appendingPathComponent("SidebarViews.swift")
        let source = try String(contentsOf: sidebarViewsURL, encoding: .utf8)

        let drawerStart = try #require(source.range(of: "struct SettingsListDrawerView: View {"))
        let rowStart = try #require(source.range(of: "struct SettingsSidebarRow: View {"))
        let drawerSource = String(source[drawerStart.lowerBound..<rowStart.lowerBound])
        let rowRest = source[rowStart.upperBound...]
        let rowEnd = try #require(rowRest.range(of: "\nstruct ")?.lowerBound)
        let rowSource = String(source[rowStart.lowerBound..<rowEnd])

        for viewSource in [drawerSource, rowSource] {
            let normalized = viewSource.components(separatedBy: .whitespacesAndNewlines).joined()
            #expect(normalized.contains("@Environment(\\.locale)privatevarlocale"))
        }
        #expect(drawerSource.contains("L10n.string(\"Settings\", locale: locale)"))
        #expect(rowSource.contains("title: page.title(in: locale)"))
    }

    @MainActor
    @Test func webProfileImageSelectionCopiesPreparedImageToPublicBlossom() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let imageSourceLoader = FakeGroupImageSourceLoader(
            response: try Self.testPNGData(width: 64, height: 64)
        )
        let result = GroupImageSearchResult(
            id: "profile-1",
            title: "Portrait",
            imageURL: "https://example.com/portrait.png",
            thumbnailURL: nil,
            creator: nil,
            license: nil,
            attribution: nil,
            sourceURL: nil,
            width: 64,
            height: 64
        )
        let state = WorkspaceState(
            groupImageSearchClient: FakeGroupImageSearchClient(results: [result]),
            groupImageSourceLoader: imageSourceLoader,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.showProfileImagePicker()
        state.profileImageSearchQuery = "portrait"
        await state.searchProfileImages()
        #expect(state.profileImageResults == [result])

        await state.setProfileImage(result)

        #expect(await imageSourceLoader.requestedURLs == [URL(string: result.imageURL)!])
        #expect(runtime.uploadedProfileImageData?.isEmpty == false)
        #expect(runtime.uploadedProfileImageMediaType == "image/jpeg")
        #expect(runtime.uploadedProfileImageBlossomServer == nil)
        #expect(state.profileDraft.picture == runtime.uploadedProfileImageURL)
        // The avatar draws `sanitizedPictureURL`, not `picture`. Asserting only the raw string
        // leaves the form free to show initials for an image that uploaded perfectly well.
        #expect(state.profileDraft.sanitizedPictureURL?.absoluteString == runtime.uploadedProfileImageURL)
        #expect(!state.isProfileImagePickerPresented)
    }

    @MainActor
    @Test func localProfileImageSelectionCopiesPreparedImageToPublicBlossom() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-image-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try Self.testPNGData(width: 80, height: 60).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        await state.bootstrap()
        state.showProfileImagePicker()
        await state.setProfileImage(fileURL: imageURL)

        #expect(runtime.uploadedProfileImageData?.isEmpty == false)
        #expect(runtime.uploadedProfileImageMediaType == "image/jpeg")
        #expect(state.profileDraft.picture == runtime.uploadedProfileImageURL)
        #expect(state.profileDraft.sanitizedPictureURL?.absoluteString == runtime.uploadedProfileImageURL)
        #expect(!state.isProfileImagePickerPresented)
    }

    /// Setting a profile picture hands the uploaded bytes to the image loader under the URL the
    /// upload returned. Without it every own-account avatar — the form's own, the account rail
    /// beside the chat list, the switcher — takes the new URL at once and draws initials until
    /// Blossom serves back the image the app had just finished sending it.
    @MainActor
    @Test func profileImageUploadPrimesTheAvatarLoaderWithTheUploadedBytes() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-image-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try Self.testPNGData(width: 80, height: 60).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        // The loader is a process-wide singleton, so leave it as this test found it.
        RemoteImageLoader.shared.clearCache()
        defer { RemoteImageLoader.shared.clearCache() }

        await state.bootstrap()
        state.showProfileImagePicker()
        await state.setProfileImage(fileURL: imageURL)

        let uploaded = try #require(runtime.uploadedProfileImageData)
        let published = try #require(RemoteImageURLPolicy.sanitizedURL(from: state.profileDraft.picture))
        #expect(published.absoluteString == runtime.uploadedProfileImageURL)
        #expect(RemoteImageLoader.shared.primedSourceByteCount(for: published) == uploaded.count)
    }

    /// Same for the sign-up path, where the bytes have been drawing the pane's avatar all along:
    /// the rail must not lose the picture at the moment the account appears in it.
    @MainActor
    @Test func signUpProfileImageUploadPrimesTheAvatarLoaderWithTheUploadedBytes() async throws {
        let created = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [], createdAccount: created)
        let state = WorkspaceState(clientFactory: { runtime })
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("signup-image-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try Self.testPNGData(width: 80, height: 60).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        RemoteImageLoader.shared.clearCache()
        defer { RemoteImageLoader.shared.clearCache() }

        await state.bootstrap()
        state.authenticationMode = .signUp
        state.prepareProfileImageDestination(.signUpDraft)
        await state.setProfileImage(fileURL: imageURL)
        let staged = try #require(state.signUpDraft.image)
        state.signUpDraft.displayName = "Pepi"

        await state.completeSignUp()

        #expect(state.lastError == nil)
        let published = try #require(RemoteImageURLPolicy.sanitizedURL(from: runtime.uploadedProfileImageURL))
        #expect(RemoteImageLoader.shared.primedSourceByteCount(for: published) == staged.data.count)
    }

    @MainActor
    @Test func settingsSelectionUsesDetailPaneWithoutChangingAccount() async throws {
        let state = WorkspaceState.preview()
        let accountId = state.activeAccountId

        state.showSettings()

        #expect(state.selection == .settings(.profile))
        #expect(state.activeAccountId == accountId)
    }

    @MainActor
    @Test func settingsSelectionCanTargetAllSettingsPages() async throws {
        let state = WorkspaceState.preview()

        state.showSettings(.preferences)
        #expect(state.selection == .settings(.preferences))

        state.showSettings(.profile)
        #expect(state.selection == .settings(.profile))

        state.showSettings(.identityKeys)
        #expect(state.selection == .settings(.identityKeys))

        state.showSettings(.relays)
        #expect(state.selection == .settings(.relays))

        state.showSettings(.keyPackages)
        #expect(state.selection == .settings(.keyPackages))

        state.showSettings(.appearance)
        #expect(state.selection == .settings(.appearance))

        state.showSettings(.privacySecurity)
        #expect(state.selection == .settings(.privacySecurity))

        state.showSettings(.notifications)
        #expect(state.selection == .settings(.notifications))

        state.showSettings(.storage)
        #expect(state.selection == .settings(.storage))

        state.showSettings(.developerMode)
        #expect(state.selection == .settings(.developerMode))
    }

    /// Profile leads, not the startup toggles: settings used to open on "General", which put a
    /// page nobody comes to settings for in the position that reads as the most important one.
    @MainActor
    @Test func settingsSidebarPagesStartWithProfileAndExcludeOverview() async throws {
        #expect(SettingsPage.sidebarPages.first == .profile)
        #expect(!SettingsPage.sidebarPages.contains(.overview))
        #expect(SettingsPage.sidebarPages.contains(.privacySecurity))
        #expect(SettingsPage.sidebarPages.contains(.storage))
        #expect(SettingsPage.sidebarPages.last == .developerMode)
    }

    @MainActor
    @Test func settingsSidebarHasNoAccountsPage() async throws {
        #expect(
            SettingsPage.sidebarPages == [
                .profile,
                .identityKeys,
                .notifications,
                .appearance,
                .privacySecurity,
                .storage,
                .relays,
                .preferences,
                .donate,
                .developerMode,
            ]
        )
    }

    /// Key Packages is not a hub row at all: `wn-ios-prototype` reaches it from an isolated
    /// navigation row inside Developer Tools rather than as a peer of Profile and Relays, so
    /// the drawer keeps Developer mode lit while its destination is the open page. Every other
    /// page is its own row.
    @MainActor
    @Test func keyPackagesIsADeveloperModeDestinationRatherThanADrawerRow() async throws {
        #expect(!SettingsPage.sidebarPages.contains(.keyPackages))
        #expect(SettingsPage.keyPackages.drawerPage == .developerMode)

        for page in SettingsPage.sidebarPages {
            #expect(page.drawerPage == page)
        }
    }

    /// The row that reaches Key Packages disappears with the master toggle — the prototype's
    /// technical sections are hidden, not disabled, while Developer Tools is off. Turning it
    /// off from a second window would otherwise leave a reader on a page nothing routes to.
    @MainActor
    @Test func turningDeveloperModeOffLeavesTheKeyPackagesPage() async throws {
        let defaults = UserDefaults.standard
        let previousDeveloperMode = defaults.object(forKey: "whitenoise.mac.developerMode")
        defer { restoreDefault(previousDeveloperMode, forKey: "whitenoise.mac.developerMode") }

        let state = WorkspaceState.preview()
        state.developerMode = true
        state.showSettings(.keyPackages)

        state.developerMode = false
        #expect(state.selection == .settings(.developerMode))

        // Every other page is unaffected: the toggle only owns its own destination.
        state.showSettings(.relays)
        state.developerMode = true
        state.developerMode = false
        #expect(state.selection == .settings(.relays))
    }

    /// Account mutations that hand the app a different active identity stay on the settings page
    /// the switcher was opened from, and fall back to the profile overview the switcher card sits
    /// above when they were started from the account rail instead.
    @MainActor
    @Test func accountMutationLandingKeepsTheOpenSettingsPageOtherwiseTheOverview() async throws {
        let state = WorkspaceState.preview()

        state.showSettings(.keyPackages)
        #expect(state.settingsSelectionAfterAccountMutation == .settings(.keyPackages))

        state.selection = nil
        #expect(state.settingsSelectionAfterAccountMutation == .settings(.overview))

        let chat = try #require(state.activeChats.first)
        state.selectChat(chat)
        #expect(state.settingsSelectionAfterAccountMutation == .settings(.overview))
    }

    /// The rail's sign-out lands in Settings on the overview, because the identity that owned the
    /// open chat is gone and the switcher card there is what names the one that took over.
    @MainActor
    @Test func signingOutTheActiveAccountFromAChatLandsOnTheSettingsOverview() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let primary = desktopAccount()
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        runtime.installGroup(messageGroup())
        UserDefaults.standard.set(primary.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let chat = try #require(state.activeChats.first { $0.id == "group" })
        state.selectChat(chat)
        let active = try #require(state.accounts.first { $0.id == primary.label })

        await state.signOutAccount(active)

        #expect(state.activeAccountId == secondary.label)
        #expect(state.selection == .settings(.overview))
    }

    @MainActor
    @Test func launchAtLoginControllerRegistersAndUnregistersTheMainApp() async throws {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        #expect(!controller.isEnabled)

        controller.setEnabled(true)

        #expect(controller.isEnabled)
        #expect(service.registerCallCount == 1)

        controller.setEnabled(false)

        #expect(!controller.isEnabled)
        #expect(service.unregisterCallCount == 1)
    }

    @MainActor
    @Test func launchAtLoginControllerReflectsExternalServiceStatusChanges() async throws {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        #expect(controller.status == .enabled)

        service.status = .requiresApproval
        controller.refresh()

        #expect(controller.status == .requiresApproval)
        #expect(!controller.isEnabled)

        controller.setEnabled(true)
        #expect(service.registerCallCount == 0)
        #expect(service.openSystemSettingsCallCount == 1)
    }

    @MainActor
    @Test func launchAtLoginControllerSurfacesRegistrationFailure() async throws {
        struct RegistrationError: LocalizedError {
            var errorDescription: String? { "Registration denied" }
        }

        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = RegistrationError()
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        #expect(controller.status == .notRegistered)
        #expect(controller.errorMessage == "Registration denied")
    }

    @MainActor
    @Test func streamingDebugRequiresDeveloperMode() async throws {
        let defaults = UserDefaults.standard
        let previousDeveloperMode = defaults.object(forKey: "whitenoise.mac.developerMode")
        let previousStreamingDebugMode = defaults.object(forKey: "whitenoise.mac.streamingDebugMode")
        defer {
            restoreDefault(previousDeveloperMode, forKey: "whitenoise.mac.developerMode")
            restoreDefault(previousStreamingDebugMode, forKey: "whitenoise.mac.streamingDebugMode")
        }

        let state = WorkspaceState.preview()
        state.developerMode = false
        state.streamingDebugMode = true
        #expect(!state.streamingDebugEnabled)

        state.developerMode = true
        #expect(state.streamingDebugEnabled)
    }

    @Test func remoteImagePolicyAllowsOnlyHttpsWithHost() async throws {
        // Allowed: https with a real host.
        #expect(RemoteImageURLPolicy.isAllowed(URL(string: "https://example.com/avatar.png")!))
        #expect(RemoteImageURLPolicy.isAllowed(URL(string: "HTTPS://Example.com/a.jpg")!))

        // Rejected: cleartext http (network observers can see the request).
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "http://example.com/avatar.png")!))
        // Rejected: non-web schemes that could exfiltrate or hit local resources.
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "file:///etc/passwd")!))
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "data:image/png;base64,AAAA")!))
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "ftp://example.com/a.png")!))
        // Rejected: https without a host.
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "https:///nohost")!))
    }

    @Test func remoteImagePolicyRejectsPrivateAndLoopbackHosts() async throws {
        // SSRF guard: once a user opts into remote images, an attacker-controlled `picture`
        // URL must not be able to reach the viewer's internal network. Every URL below is a
        // valid `https://` URL with a non-empty host, so only the address check rejects them.

        // IPv4 loopback / private / link-local / "this host".
        let blockedV4 = [
            "https://127.0.0.1/x.png",
            "https://127.0.0.1./x.png",
            "https://127.1.2.3/x.png",
            "https://10.0.0.5/x.png",
            "https://10.255.255.255/x.png",
            "https://172.16.0.1/x.png",
            "https://172.31.255.255/x.png",
            "https://192.168.1.1/x.png",
            "https://169.254.169.254/x.png",  // cloud metadata endpoint
            "https://0.0.0.0/x.png",
        ]
        for s in blockedV4 {
            #expect(!RemoteImageURLPolicy.isAllowed(URL(string: s)!), "expected SSRF rejection for \(s)")
        }

        // Obfuscated IPv4 forms that still resolve to loopback/private must also be rejected.
        // (Parser-level coverage of every BSD form lives in `ipAddressParserHandlesLiteralForms`;
        // here we assert the end-to-end URL path for the forms `URL(string:)` parses as a host.)
        let blockedV4Obfuscated = [
            "https://2130706433/x.png",  // decimal 127.0.0.1
            "https://127.1/x.png",  // shorthand 127.0.0.1
            "https://10.0.0.16/x.png",  // plain private, sanity
        ]
        for s in blockedV4Obfuscated {
            #expect(!RemoteImageURLPolicy.isAllowed(URL(string: s)!), "expected SSRF rejection for \(s)")
        }

        // whitenoise-mac#243: broadcast / multicast / reserved / CGNAT literals are not routable
        // public destinations and must be rejected too, including an obfuscated (decimal) form so
        // the parser path is exercised, not just the dotted-quad string.
        let blockedV4NonPublic = [
            "https://255.255.255.255/x.png",  // limited broadcast
            "https://224.0.0.1/x.png",  // multicast 224.0.0.0/4 (low edge)
            "https://239.255.255.255/x.png",  // multicast 224.0.0.0/4 (high edge)
            "https://240.0.0.1/x.png",  // reserved 240.0.0.0/4 (low edge)
            "https://100.64.0.1/x.png",  // CGNAT 100.64.0.0/10 (low edge)
            "https://100.127.255.255/x.png",  // CGNAT 100.64.0.0/10 (high edge)
            "https://4294967295/x.png",  // decimal 255.255.255.255 (obfuscated broadcast)
        ]
        for s in blockedV4NonPublic {
            #expect(!RemoteImageURLPolicy.isAllowed(URL(string: s)!), "expected SSRF rejection for \(s)")
        }

        // IPv6 loopback / unspecified / ULA / link-local / IPv4-mapped private.
        let blockedV6 = [
            "https://[::1]/x.png",
            "https://[::]/x.png",
            "https://[fc00::1]/x.png",
            "https://[fd12:3456::1]/x.png",
            "https://[fe80::1]/x.png",
            "https://[::ffff:192.168.0.1]/x.png",
            "https://[::ffff:127.0.0.1]/x.png",
        ]
        for s in blockedV6 {
            #expect(!RemoteImageURLPolicy.isAllowed(URL(string: s)!), "expected SSRF rejection for \(s)")
        }

        // Local hostnames.
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "https://localhost/x.png")!))
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "https://localhost./x.png")!))
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "https://LOCALHOST/x.png")!))
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "https://printer.local/x.png")!))
        #expect(!RemoteImageURLPolicy.isAllowed(URL(string: "https://printer.local./x.png")!))

        // Allowed: genuine public hosts and public IP literals are not affected.
        let allowed = [
            "https://example.com/avatar.png",
            "https://cdn.example.org/p.jpg",
            "https://8.8.8.8/x.png",
            "https://1.1.1.1/x.png",
            "https://172.32.0.1/x.png",  // just outside 172.16/12
            "https://192.169.0.1/x.png",  // just outside 192.168/16
            "https://100.63.255.255/x.png",  // just below CGNAT 100.64.0.0/10
            "https://100.128.0.1/x.png",  // just above CGNAT 100.64.0.0/10
            "https://223.255.255.255/x.png",  // just below multicast 224.0.0.0/4
            "https://[2606:4700:4700::1111]/x.png",  // public IPv6 (Cloudflare)
            "https://[::ffff:8.8.8.8]/x.png",  // IPv4-mapped public address
        ]
        for s in allowed {
            #expect(RemoteImageURLPolicy.isAllowed(URL(string: s)!), "expected allow for \(s)")
        }
    }

    @Test func ipAddressParserHandlesLiteralForms() async throws {
        // IPv4: dotted-quad, decimal, hex, octal, and shorthand all normalize to the same octets.
        #expect(IPAddress.parseIPv4("127.0.0.1").map { [$0.0, $0.1, $0.2, $0.3] } == [127, 0, 0, 1])
        #expect(IPAddress.parseIPv4("8.8.8.8").map { [$0.0, $0.1, $0.2, $0.3] } == [8, 8, 8, 8])
        #expect(IPAddress.parseIPv4("203.0.113.5").map { [$0.0, $0.1, $0.2, $0.3] } == [203, 0, 113, 5])
        #expect(IPAddress.parseIPv4("2130706433").map { [$0.0, $0.1, $0.2, $0.3] } == [127, 0, 0, 1])
        #expect(IPAddress.parseIPv4("0x7f000001").map { [$0.0, $0.1, $0.2, $0.3] } == [127, 0, 0, 1])
        #expect(IPAddress.parseIPv4("0177.0.0.1").map { [$0.0, $0.1, $0.2, $0.3] } == [127, 0, 0, 1])
        #expect(IPAddress.parseIPv4("127.1").map { [$0.0, $0.1, $0.2, $0.3] } == [127, 0, 0, 1])
        #expect(IPAddress.parseIPv4("10.0.0.16").map { [$0.0, $0.1, $0.2, $0.3] } == [10, 0, 0, 16])
        // Not IPv4 literals.
        #expect(IPAddress.parseIPv4("example.com") == nil)
        #expect(IPAddress.parseIPv4("256.0.0.1") == nil)  // octet overflow
        #expect(IPAddress.parseIPv4("1.2.3.4.5") == nil)  // too many parts

        // IPv6: `::` compression, full form, and IPv4-mapped tail.
        #expect(IPAddress.parseIPv6("::1") == [0, 0, 0, 0, 0, 0, 0, 1])
        #expect(IPAddress.parseIPv6("fe80::1")?.first == 0xFE80)
        #expect(IPAddress.parseIPv6("::ffff:192.168.0.1") == [0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0001])
        #expect(IPAddress.parseIPv6("fe80:::1") == nil)  // malformed: empty group
        #expect(IPAddress.parseIPv6("example.com") == nil)
    }

    @MainActor
    @Test func loadRemoteImagesDefaultsOffAndPersists() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "whitenoise.mac.loadRemoteImages")
        defer { restoreDefault(previous, forKey: "whitenoise.mac.loadRemoteImages") }

        // Privacy-preserving default: off when no preference has been stored.
        defaults.removeObject(forKey: "whitenoise.mac.loadRemoteImages")
        let state = WorkspaceState.preview()
        #expect(!state.loadRemoteImages)

        // Opting in persists to UserDefaults so a fresh instance honours it.
        state.loadRemoteImages = true
        #expect(defaults.bool(forKey: "whitenoise.mac.loadRemoteImages"))
        let reloaded = WorkspaceState.preview()
        #expect(reloaded.loadRemoteImages)
    }

    @MainActor
    @Test func defaultRelaysUseWhiteNoiseEuAndUsOnly() async throws {
        let defaults = [
            "wss://relay.eu.whitenoise.chat",
            "wss://relay.us.whitenoise.chat",
        ]

        #expect(MarmotClient.seedRelays == defaults)
        #expect(RelaySettingsSnapshot.defaults.nip65 == defaults)
        #expect(RelaySettingsSnapshot.defaults.inbox == defaults)
        #expect(RelaySettingsSnapshot.defaults.defaultRelays == defaults)
        #expect(RelaySettingsSnapshot.defaults.bootstrapRelays == defaults)
        #expect(RelayRole.allCases == [.profile, .inbox])
    }

    @MainActor
    @Test func settingsAccountSwitchStaysOnTheSettingsPageItWasStartedFrom() async throws {
        let state = WorkspaceState.preview()
        state.showSettings(.relays)
        state.searchText = "relay"
        state.draftText = "half-written"

        state.selectAccountFromSettings(AccountItem.samples[1])

        #expect(state.activeAccountId == AccountItem.samples[1].id)
        #expect(state.selection == .settings(.relays))
        #expect(state.searchText.isEmpty)
        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func appearancePreferenceMapsToPreferredColorScheme() async throws {
        let state = WorkspaceState.preview()

        state.appearancePreference = .dark
        #expect(state.preferredColorScheme == .dark)

        state.appearancePreference = .light
        #expect(state.preferredColorScheme == .light)

        state.appearancePreference = .system
        #expect(state.preferredColorScheme == nil)
    }

    @MainActor
    @Test func settingsLoadUpdatesActiveAccountProfilePicture() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()

        #expect(state.activeAccount?.displayName == "Desktop Account")
        #expect(state.activeAccount?.pictureURL == "https://example.com/avatar.png")
        #expect(state.profileDraft.picture == "https://example.com/avatar.png")
    }

    @MainActor
    @Test func keyPackageLoadShowsPublishedKeyPackages() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        await state.loadKeyPackages()

        #expect(state.keyPackages.map(\.eventIdHex) == ["event-local", "event-fetched"])
        #expect(state.keyPackages.first?.sourceLabel == "Local")
        #expect(runtime.lastPackageFetchBootstrapRelays == MarmotClient.seedRelays)
    }

    @MainActor
    @Test func keyPackageLabelsUseSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }
        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()

        let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let package = KeyPackageItem(
            accountRef: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            keyPackageId: "key-package",
            keyPackageRefHex: "key-package-ref",
            eventIdHex: "event-fetched",
            publishedAt: publishedAt,
            keyPackageBytes: 128,
            sourceRelays: ["wss://relay.example"],
            isLocal: false,
            isRelayDiscovered: true
        )
        let expectedPublished = publishedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(Locale(identifier: AppLanguage.spanish.rawValue))
        )

        #expect(package.sourceLabel == "Sincronizado")
        #expect(package.statusLabels == ["Sincronizado"])
        #expect(package.publishedLabel == expectedPublished)

        let localAndSyncedPackage = KeyPackageItem(
            accountRef: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            keyPackageId: "local-synced-package",
            keyPackageRefHex: "local-synced-key-package-ref",
            eventIdHex: "event-local-synced",
            publishedAt: publishedAt,
            keyPackageBytes: 128,
            sourceRelays: ["wss://relay.example"],
            isLocal: true,
            isRelayDiscovered: true
        )

        #expect(localAndSyncedPackage.statusLabels == ["Local", "Sincronizado"])
        #expect(localAndSyncedPackage.sourceLabel == "Local + Sincronizado")

        let unknownPackage = KeyPackageItem(
            accountRef: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            keyPackageId: "unknown-package",
            keyPackageRefHex: "unknown-key-package-ref",
            eventIdHex: "event-unknown",
            publishedAt: nil,
            keyPackageBytes: 0,
            sourceRelays: [],
            isLocal: false,
            isRelayDiscovered: false
        )

        #expect(unknownPackage.sourceLabel == "Desconocido")
        #expect(unknownPackage.publishedLabel == "Desconocido")
    }

    @MainActor
    @Test func keyPackageLoadUsesAccountRelayBootstrapRelays() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let bootstrapRelays = ["wss://bootstrap.example"]
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: bootstrapRelays,
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox.example"]
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        await state.loadKeyPackages()

        #expect(runtime.lastPackageFetchBootstrapRelays == bootstrapRelays)
    }

    @MainActor
    @Test func settingsLoadDoesNotFetchKeyPackages() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()

        #expect(runtime.accountKeyPackagesCallCount == 0)
        #expect(state.keyPackages.isEmpty)
    }

    @MainActor
    @Test func staleKeyPackageLoadDoesNotClobberSwitchedAccountList() async throws {
        // Issue #207: `loadKeyPackages` is driven by `.task(id: activeAccountId)` and awaits the
        // completion-ordered `accountKeyPackages` FFI. On an A→B account switch, account A's
        // slower-resolving load must not overwrite account B's key-package list.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installKeyPackages(
            accountRef: "Desktop Account",
            packages: [keyPackageFixture(accountRef: "Desktop Account", eventIdHex: "event-account-a")]
        )
        runtime.installKeyPackages(
            accountRef: "Backup Account",
            packages: [keyPackageFixture(accountRef: "Backup Account", eventIdHex: "event-account-b")]
        )
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")

        // Arm the gate so account A's load suspends in-flight after capturing A's packages.
        runtime.accountKeyPackagesGateEnabled = true
        async let staleLoad: Void = state.loadKeyPackages()
        while !runtime.didReachAccountKeyPackagesGate {
            await Task.yield()
        }

        // Switch to account B and run a fresh load to completion. The gate only holds the first
        // call, so B's load is not gated.
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")
        await state.loadKeyPackages()
        #expect(state.keyPackages.map(\.eventIdHex) == ["event-account-b"])

        // Release account A's stale load. Its completion is now superseded, so it must neither
        // overwrite B's list nor report an error.
        runtime.releaseAccountKeyPackagesGate()
        _ = await staleLoad

        #expect(state.keyPackages.map(\.eventIdHex) == ["event-account-b"])
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func concurrentSettingsLoadsForSameAccountCoalesce() async throws {
        // Issue #4: settings loading is driven from more than one entry point (the settings
        // view's `.task(id: activeAccountId)` and explicit reloads), so two overlapping
        // `loadSettingsData()` calls for the same account must coalesce onto a single in-flight
        // load rather than duplicating the per-account profile / relay fetches.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let baselineProfileCalls = runtime.userProfileCallCount
        let baselineRelayCalls = runtime.accountRelayListsCallCount

        // Two concurrent loads for the same active account. The first to run installs the
        // in-flight task before suspending; the second observes it and awaits the same task.
        async let first: Void = state.loadSettingsData()
        async let second: Void = state.loadSettingsData()
        _ = await (first, second)

        // Exactly one additional profile + relay fetch despite two concurrent callers.
        #expect(runtime.userProfileCallCount == baselineProfileCalls + 1)
        #expect(runtime.accountRelayListsCallCount == baselineRelayCalls + 1)
        #expect(state.isLoadingSettings == false)
    }

    @MainActor
    @Test func sequentialSettingsLoadsForSameAccountStillReload() async throws {
        // Coalescing must not turn a later, intentionally-sequential reload into a no-op: once a
        // load has finished, a fresh `loadSettingsData()` performs a new fetch.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        let afterFirst = runtime.userProfileCallCount
        await state.loadSettingsData()

        #expect(runtime.userProfileCallCount == afterFirst + 1)
    }

    @MainActor
    @Test func cancellingInFlightSettingsLoadWithNoActiveAccountClearsSpinner() async throws {
        // Issue #4 (adversarial-review blocking finding): a settings load that is cancelled
        // *without* a replacement load starting must not leave `isLoadingSettings` stuck `true`.
        // Repro: hold a load suspended mid-flight (at `refreshNotificationAuthorizationStatus()`),
        // clear the active account (as account removal of the last account does), then let the
        // stale load resume. The resumed task must NOT own the spinner (a newer generation has
        // superseded it); the no-active-account reset path owns clearing it.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let gate = GatedLocalNotificationCenter()
        let state = WorkspaceState(
            localNotificationCenter: gate,
            clientFactory: { runtime }
        )

        await state.bootstrap()

        // Arm the gate so the next settings load suspends inside refreshNotificationAuthorizationStatus().
        gate.gateEnabled = true
        async let inflight: Void = state.loadSettingsData()

        // Spin the main actor until the suspended load has set the spinner and reached the gate.
        while !(state.isLoadingSettings && gate.didReachGate) {
            await Task.yield()
        }
        #expect(state.isLoadingSettings)

        // Clear the active account with no replacement load — the no-active-account branch of
        // loadSettingsData() runs synchronously, cancels the in-flight task, and resets to defaults.
        state.activeAccountId = nil
        await state.loadSettingsData()

        // The spinner must already be cleared by the reset path, even before the stale load resumes.
        #expect(state.isLoadingSettings == false)

        // Release the gate so the stale load resumes; its defer must see the bumped generation and
        // leave the (already-false) spinner untouched rather than resurrecting it.
        gate.releaseGate()
        _ = await inflight

        #expect(state.isLoadingSettings == false)
    }

    @MainActor
    @Test func settingsLoadShowsNotificationPreference() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter()
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadSettingsData()

        #expect(state.notificationSettings.localNotificationsEnabled)
        #expect(state.notificationAuthorizationStatus == .authorized)
    }

    @MainActor
    @Test func staleNotificationSettingsLoadDoesNotClobberSwitchedAccountSettings() async throws {
        // Issue #228: `loadNotificationSettings()` reads over the non-cancellation-aware FFI
        // boundary. If account A's read completes after switching to account B, its result must not
        // overwrite B's published notification preference.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: true)
        )
        runtime.installNotificationSettings(
            accountRef: "Backup Account",
            settings: notificationSettings(for: accountB, localEnabled: false)
        )
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(
            localNotificationCenter: FakeLocalNotificationCenter(status: .authorized),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled)

        runtime.notificationSettingsGateEnabled = true
        async let staleLoad: Void = state.loadNotificationSettings()
        while !runtime.didReachNotificationSettingsGate {
            await Task.yield()
        }

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")
        await state.loadNotificationSettings()
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.releaseNotificationSettingsGate()
        _ = await staleLoad

        #expect(state.notificationSettings.localNotificationsEnabled == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func staleNotificationSettingsLoadDoesNotClobberReenteredAccountSettings() async throws {
        // A monotonic notification-settings generation closes the A→B→A hole that an id-only stale
        // guard leaves open: the older A read must not overwrite a newer A snapshot after re-entry.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: true)
        )
        runtime.installNotificationSettings(
            accountRef: "Backup Account",
            settings: notificationSettings(for: accountB, localEnabled: false)
        )
        UserDefaults.standard.set("Desktop Account", forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(
            localNotificationCenter: FakeLocalNotificationCenter(status: .authorized),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled)

        runtime.notificationSettingsGateEnabled = true
        async let staleLoad: Void = state.loadNotificationSettings()
        while !runtime.didReachNotificationSettingsGate {
            await Task.yield()
        }

        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: false)
        )
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })
        state.selectAccountFromSettings(desktopAccount)
        await state.loadNotificationSettings()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.releaseNotificationSettingsGate()
        _ = await staleLoad

        #expect(state.notificationSettings.localNotificationsEnabled == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func staleLocalNotificationToggleDoesNotClobberSwitchedAccountSettings() async throws {
        // Issue #228: `setLocalNotificationsEnabled(_:)` also awaits an FFI write before publishing
        // the returned snapshot. A stale account A toggle must not overwrite account B's snapshot.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: false)
        )
        runtime.installNotificationSettings(
            accountRef: "Backup Account",
            settings: notificationSettings(for: accountB, localEnabled: false)
        )
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(
            localNotificationCenter: FakeLocalNotificationCenter(status: .authorized),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.setLocalNotificationsGateEnabled = true
        async let staleToggle: Void = state.setLocalNotificationsEnabled(true)
        while !runtime.didReachSetLocalNotificationsGate {
            await Task.yield()
        }

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")
        await state.loadNotificationSettings()
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.releaseSetLocalNotificationsGate()
        _ = await staleToggle

        #expect(runtime.localNotificationsEnabledSet == true)
        #expect(state.notificationSettings.localNotificationsEnabled == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func staleLocalNotificationToggleDoesNotClobberReenteredAccountSettings() async throws {
        // The stale toggle returns an older A snapshot after the user has switched A→B→A and loaded
        // a newer A snapshot. The generation guard must keep the newer A value.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: false)
        )
        runtime.installNotificationSettings(
            accountRef: "Backup Account",
            settings: notificationSettings(for: accountB, localEnabled: false)
        )
        UserDefaults.standard.set("Desktop Account", forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(
            localNotificationCenter: FakeLocalNotificationCenter(status: .authorized),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.setLocalNotificationsGateEnabled = true
        async let staleToggle: Void = state.setLocalNotificationsEnabled(true)
        while !runtime.didReachSetLocalNotificationsGate {
            await Task.yield()
        }

        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: false)
        )
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        let desktopAccount = try #require(state.accounts.first { $0.id == "Desktop Account" })
        state.selectAccountFromSettings(desktopAccount)
        await state.loadNotificationSettings()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationSettings.localNotificationsEnabled == false)

        runtime.releaseSetLocalNotificationsGate()
        _ = await staleToggle

        #expect(runtime.localNotificationsEnabledSet == true)
        #expect(state.notificationSettings.localNotificationsEnabled == false)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func staleLocalNotificationPermissionRequestDoesNotPublishAuthorizationAfterSwitch() async throws {
        // If account A is waiting on the macOS permission sheet and the user switches accounts, the
        // eventual permission result must not update the now-current account's UI snapshot.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: "Desktop Account",
            settings: notificationSettings(for: accountA, localEnabled: false)
        )
        runtime.installNotificationSettings(
            accountRef: "Backup Account",
            settings: notificationSettings(for: accountB, localEnabled: false)
        )
        UserDefaults.standard.set("Desktop Account", forKey: WorkspaceState.activeAccountKey)
        let notificationCenter = FakeLocalNotificationCenter(
            status: .notDetermined,
            requestedStatus: .authorized
        )
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(state.notificationAuthorizationStatus == .notDetermined)

        notificationCenter.requestAuthorizationGateEnabled = true
        async let staleToggle: Void = state.setLocalNotificationsEnabled(true)
        while !notificationCenter.didReachRequestAuthorizationGate {
            await Task.yield()
        }

        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")

        notificationCenter.releaseRequestAuthorizationGate()
        _ = await staleToggle

        #expect(notificationCenter.didRequestAuthorization)
        #expect(runtime.localNotificationsEnabledSet == nil)
        #expect(state.notificationSettings.localNotificationsEnabled == false)
        #expect(state.notificationAuthorizationStatus == .notDetermined)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func telemetryBuildConfigUsesSeparateMacBuildSettings() async throws {
        let config = TelemetryBuildConfig.current(
            infoDictionary: [
                "WhiteNoiseTelemetryOTLPEndpoint": "https://collector.example/v1/metrics",
                "WhiteNoiseTelemetryBearerToken": "otlp-token",
                "WhiteNoiseAuditLogBearerToken": "audit-token",
                "WhiteNoiseTelemetryEnvironment": "production",
                "CFBundleShortVersionString": "2026.6",
                "CFBundleVersion": "12",
            ],
            environment: [:],
            osVersion: "Version 26.0",
            deviceModelIdentifier: "Mac15,3"
        )

        #expect(config.otlpEndpoint == "https://collector.example/v1/metrics")
        #expect(config.bearerToken == "otlp-token")
        #expect(config.auditLogBearerToken == "audit-token")
        #expect(config.deploymentEnvironment == "production")
        #expect(config.serviceVersion == "2026.6+12")
        #expect(config.osVersion == "Version 26.0")
        #expect(config.deviceModelIdentifier == "Mac15,3")

        let runtimeConfig = config.runtimeConfig(installId: "install-id")
        #expect(runtimeConfig.authorizationBearerToken == "otlp-token")
        #expect(runtimeConfig.resource?.serviceVersion == "2026.6+12")
        #expect(runtimeConfig.resource?.serviceInstanceId == "install-id")
        #expect(runtimeConfig.resource?.deploymentEnvironment == "production")
        #expect(runtimeConfig.resource?.tenant == "whitenoise-mac")
        #expect(runtimeConfig.resource?.osType == "darwin")
        #expect(runtimeConfig.resource?.osVersion == "Version 26.0")
        #expect(runtimeConfig.resource?.deviceModelIdentifier == nil)

        let auditConfig = config.auditTrackerConfig()
        #expect(auditConfig.authorizationBearerToken == "audit-token")
        #expect(auditConfig.source.deviceLabel == "Mac15,3")
        #expect(auditConfig.source.platform == "macOS")
        #expect(auditConfig.source.appVersion == "2026.6+12")
    }

    @MainActor
    @Test func telemetryBuildConfigDefaultsToMarketingOnlyOSVersion() async throws {
        // The default osVersion must be the marketing "major.minor.patch"
        // string, never the build-bearing operatingSystemVersionString (for
        // example "Version 15.5 (Build 24F74)") which is a higher-entropy
        // fingerprint exported to the remote OTLP endpoint.
        let config = TelemetryBuildConfig.current(
            infoDictionary: [
                "CFBundleShortVersionString": "2026.6",
                "CFBundleVersion": "12",
            ],
            environment: [:]
        )

        let version = ProcessInfo.processInfo.operatingSystemVersion
        let expected = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #expect(config.osVersion == expected)
        #expect(config.osVersion != ProcessInfo.processInfo.operatingSystemVersionString)
        #expect(!config.osVersion.contains("Build"))
        #expect(!config.osVersion.contains("Version"))
        #expect(config.osVersion.allSatisfy { $0.isNumber || $0 == "." })

        let runtimeResource = config.runtimeConfig(installId: "install-id").resource
        #expect(runtimeResource?.osVersion == expected)
        #expect(runtimeResource?.osVersion != ProcessInfo.processInfo.operatingSystemVersionString)
    }

    @MainActor
    @Test func telemetryBuildConfigFormatsMarketingOSVersionAsMajorMinorPatch() async throws {
        let formatted = TelemetryBuildConfig.marketingOSVersion(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0)
        )
        #expect(formatted == "15.5.0")
    }

    @MainActor
    @Test func telemetryBuildConfigIgnoresUnresolvedBuildSettingsAndUsesEnvironmentFallbacks() async throws {
        let config = TelemetryBuildConfig.current(
            infoDictionary: [
                "WhiteNoiseTelemetryOTLPEndpoint": "$(WN_OTLP_ENDPOINT)",
                "WhiteNoiseTelemetryBearerToken": "$(WN_OTLP_BEARER_TOKEN)",
                "WhiteNoiseAuditLogBearerToken": "$(WN_AUDIT_LOG_BEARER_TOKEN)",
                "WhiteNoiseTelemetryEnvironment": "$(WN_TELEMETRY_ENVIRONMENT)",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            ],
            environment: [
                "WN_OTLP_ENDPOINT": "https://env.example/v1/metrics",
                "OTLP_TOKEN_WN_MAC": "env-otlp-token",
                "AUDIT_LOG_TOKEN_WN_MAC": "env-audit-token",
                "WN_TELEMETRY_ENVIRONMENT": "staging",
            ],
            osVersion: "Version 26.0",
            deviceModelIdentifier: nil
        )

        #expect(config.otlpEndpoint == "https://env.example/v1/metrics")
        #expect(config.bearerToken == "env-otlp-token")
        #expect(config.auditLogBearerToken == "env-audit-token")
        #expect(config.deploymentEnvironment == "staging")
        #expect(config.serviceVersion == "1.2.3")
    }

    @MainActor
    @Test func telemetryBuildConfigDefaultsUnsetDeploymentEnvironmentToDevelopment() async throws {
        let config = TelemetryBuildConfig.current(
            infoDictionary: [
                "CFBundleShortVersionString": "2026.6",
                "CFBundleVersion": "12",
            ],
            environment: [:]
        )

        #expect(config.deploymentEnvironment == "development")

        let runtimeResource = config.runtimeConfig(installId: "install-id").resource
        #expect(runtimeResource?.deploymentEnvironment == "development")
    }

    @MainActor
    @Test func telemetryBuildConfigMapsUnrecognizedDeploymentEnvironmentToUnknown() async throws {
        let config = TelemetryBuildConfig.current(
            infoDictionary: [
                "WhiteNoiseTelemetryBearerToken": "release-otlp-token",
                "WhiteNoiseTelemetryEnvironment": "prod",
                "CFBundleShortVersionString": "2026.6",
                "CFBundleVersion": "12",
            ],
            environment: [:]
        )

        #expect(config.bearerToken == "release-otlp-token")
        #expect(config.deploymentEnvironment == "unknown")

        let runtimeResource = config.runtimeConfig(installId: "install-id").resource
        #expect(runtimeResource?.deploymentEnvironment == "unknown")
    }

    @MainActor
    @Test func privacySecuritySettingsLoadAndPersistTelemetryAndAuditToggles() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.storedRelayTelemetrySettings = RelayTelemetrySettingsFfi(
            exportEnabled: true,
            exportIntervalSeconds: 120
        )
        runtime.storedAuditLogSettings = AuditLogSettingsFfi(enabled: false, dataMode: .obfuscatedSensitiveData)
        runtime.storedAuditLogFiles = [
            AuditLogFileFfi(
                accountRef: account.label,
                path: "/tmp/audit-1.jsonl",
                fileName: "audit-1.jsonl",
                sizeBytes: 512,
                modifiedAtMs: 1_800_000_000_000
            )
        ]
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(
                    telemetryToken: "otlp-token",
                    auditToken: "audit-token",
                    environment: "production"
                )
            },
            clientFactory: { runtime }
        )

        await state.bootstrap()

        #expect(state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(state.privacySecuritySettings.relayTelemetryIntervalSeconds == 120)
        #expect(!state.privacySecuritySettings.auditLoggingEnabled)
        #expect(state.privacySecuritySettings.telemetryCredentialsAvailable)
        #expect(state.privacySecuritySettings.auditLogCredentialsAvailable)
        #expect(state.auditLogFiles.count == 1)
        #expect(runtime.relayTelemetryRuntimeConfig?.authorizationBearerToken == "otlp-token")
        let telemetryResource = runtime.relayTelemetryRuntimeConfig?.resource
        #expect(telemetryResource?.serviceVersion == expectedTelemetryServiceVersion())
        #expect(telemetryResource?.serviceInstanceId == "test-install-id")
        #expect(telemetryResource?.deploymentEnvironment == "production")
        #expect(telemetryResource?.tenant == "whitenoise-mac")
        #expect(telemetryResource?.osType == "darwin")
        #expect(telemetryResource?.osVersion == TelemetryBuildConfig.marketingOSVersion())
        #expect(telemetryResource?.deviceModelIdentifier == nil)
        #expect(runtime.auditLogTrackerConfig?.authorizationBearerToken == "audit-token")
        #expect(runtime.auditLogTrackerConfig?.source.deviceLabel == expectedDeviceModelIdentifier())

        await state.setRelayTelemetryEnabled(false)
        await state.setAuditLoggingEnabled(true)

        #expect(!runtime.storedRelayTelemetrySettings.exportEnabled)
        #expect(runtime.storedRelayTelemetrySettings.exportIntervalSeconds == 120)
        #expect(runtime.storedAuditLogSettings.enabled)
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(state.privacySecuritySettings.auditLoggingEnabled)
        // macOS never requests sensitive capture: the persisted posture stays obfuscated.
        #expect(runtime.storedAuditLogSettings.dataMode == .obfuscatedSensitiveData)
    }

    @MainActor
    @Test func enablingAuditLoggingDowngradesAFullDataPostureToObfuscated() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        // A core that already carries the sensitive posture -- set by another client,
        // or left behind by an older build of this app.
        runtime.storedAuditLogSettings = AuditLogSettingsFfi(enabled: false, dataMode: .fullData)
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(telemetryToken: "otlp-token", auditToken: "audit-token")
            },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.setAuditLoggingEnabled(true)

        #expect(runtime.storedAuditLogSettings.enabled)
        #expect(runtime.storedAuditLogSettings.dataMode == .obfuscatedSensitiveData)
        #expect(state.privacySecuritySettings.auditLoggingEnabled)

        await state.setAuditLoggingEnabled(false)

        #expect(!runtime.storedAuditLogSettings.enabled)
        #expect(runtime.storedAuditLogSettings.dataMode == .obfuscatedSensitiveData)
        #expect(!state.privacySecuritySettings.auditLoggingEnabled)
    }

    /// The telemetry switch renders from `privacySecuritySettings`, so that value has to move when
    /// the user flips it, not a relay round trip later — otherwise the switch springs back under the
    /// pointer and then flips on its own. The gate here holds the FFI read open so "before the write
    /// lands" is a state we can actually stand in, rather than something inferred from timing.
    @MainActor
    @Test func relayTelemetryToggleMovesBeforeTheWriteLands() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(telemetryToken: "otlp-token", auditToken: "audit-token")
            },
            clientFactory: { runtime }
        )
        await state.bootstrap()
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)

        runtime.relayTelemetrySettingsGateEnabled = true
        async let enabling: Void = state.setRelayTelemetryEnabled(true)
        while !runtime.didReachRelayTelemetrySettingsGate {
            await Task.yield()
        }

        // Parked inside the FFI read, so nothing has been written anywhere yet.
        #expect(state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(!runtime.storedRelayTelemetrySettings.exportEnabled)

        runtime.releaseRelayTelemetrySettingsGate()
        await enabling

        #expect(state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(runtime.storedRelayTelemetrySettings.exportEnabled)
    }

    /// The other half of moving early: a write that never lands has to put the switch back, or the
    /// user is left looking at a setting the core does not have. Both toggles roll back, and the
    /// failure still surfaces through `lastError`.
    @MainActor
    @Test func privacySecurityTogglesRollBackWhenTheWriteFails() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.setRelayTelemetrySettingsError = FakeMarmotRuntimeError.unused
        runtime.setAuditLogSettingsError = FakeMarmotRuntimeError.unused
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(telemetryToken: "otlp-token", auditToken: "audit-token")
            },
            clientFactory: { runtime }
        )
        await state.bootstrap()

        await state.setRelayTelemetryEnabled(true)
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(state.lastError != nil)

        state.lastError = nil
        await state.setAuditLoggingEnabled(true)
        #expect(!state.privacySecuritySettings.auditLoggingEnabled)
        #expect(state.lastError != nil)
    }

    /// Moving the toggle early buys a second obligation: the write that lands late must check it is
    /// still wanted. `privacySecuritySettings` is per-account UI state — `resetActiveAccountUIState`
    /// puts it back to `.defaults` — so a save suspended across a switch that then writes anything,
    /// success or rollback, hands the incoming account a value it never loaded and an error from an
    /// identity it never used. Same protocol as `saveRelaySettings` and `saveProfile`.
    @MainActor
    @Test func privacySecurityToggleWritesNothingAfterAnAccountSwitch() async throws {
        // `selectAccount` persists the incoming id through `WorkspaceState.activeAccountKey`, so
        // this test would otherwise leave a fake account id in the host's defaults for whatever
        // runs next. Same guard every other switch test in this suite takes.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let first = desktopAccount()
        let second = AccountSummaryFfi(
            label: "Secondary Account",
            accountIdHex: String(repeating: "7", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [first, second])
        // The outgoing account has telemetry on, so a rollback that escapes writes `true` — which
        // the incoming account's `.defaults` snapshot does not carry. That difference is the witness.
        runtime.storedRelayTelemetrySettings = RelayTelemetrySettingsFfi(
            exportEnabled: true,
            exportIntervalSeconds: 120
        )
        runtime.setRelayTelemetrySettingsError = FakeMarmotRuntimeError.unused
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        await state.loadPrivacySecuritySettings()
        #expect(state.privacySecuritySettings.relayTelemetryEnabled)

        // Turning telemetry *off* needs no credentials, so the guard at the top of the save is not
        // in the way. The gate parks the save inside its first FFI read, which is where a real
        // switch would catch it.
        runtime.relayTelemetrySettingsGateEnabled = true
        async let disabling: Void = state.setRelayTelemetryEnabled(false)
        while !runtime.didReachRelayTelemetrySettingsGate {
            await Task.yield()
        }

        let incoming = try #require(state.accounts.first { $0.id != state.activeAccountId })
        state.selectAccount(incoming)
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)
        state.lastError = nil

        runtime.releaseRelayTelemetrySettingsGate()
        await disabling

        // The failed save belongs to the identity that started it, and that identity is gone.
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(state.lastError == nil)
    }

    /// Refusing a stale completion is only half of it: nobody must be left holding the save flag.
    /// A switch does not clear `isSavingPrivacySecurity` — `prepareForActiveAccountSwitch` never
    /// touches it — so if the outgoing account's completion is refused *and* nothing invalidates the
    /// flag, it stays true for the rest of the session and `guard !isSavingPrivacySecurity` silently
    /// kills both toggles for every account. The incoming account has to be able to save while the
    /// outgoing account's write is still in the air.
    @MainActor
    @Test func privacySecuritySaveFlagDoesNotOutliveTheAccountThatOwnsIt() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let first = desktopAccount()
        let second = AccountSummaryFfi(
            label: "Secondary Account",
            accountIdHex: String(repeating: "7", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [first, second])
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(telemetryToken: "otlp-token", auditToken: "audit-token")
            },
            clientFactory: { runtime }
        )
        await state.bootstrap()

        // Park the outgoing account's save inside its first FFI read and switch out from under it.
        runtime.relayTelemetrySettingsGateEnabled = true
        async let outgoing: Void = state.setRelayTelemetryEnabled(true)
        while !runtime.didReachRelayTelemetrySettingsGate {
            await Task.yield()
        }
        let incoming = try #require(state.accounts.first { $0.id != state.activeAccountId })
        state.selectAccount(incoming)

        // The incoming account owns the pane now, so its toggle has to work — the gate is already
        // spent, so this save runs to completion while the outgoing one is still suspended.
        #expect(!state.isSavingPrivacySecurity)
        await state.setRelayTelemetryEnabled(true)
        #expect(state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(runtime.storedRelayTelemetrySettings.exportEnabled)

        runtime.releaseRelayTelemetrySettingsGate()
        await outgoing

        // And the refused completion did not take the incoming account's flag down with it.
        #expect(!state.isSavingPrivacySecurity)
        #expect(state.privacySecuritySettings.relayTelemetryEnabled)
    }

    @MainActor
    @Test func privacySecuritySettingsLoadSurvivesObservabilityConfigurationFailure() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        var buildConfig = telemetryBuildConfig(environment: "production")
        let state = WorkspaceState(
            telemetryBuildConfigProvider: { buildConfig },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(!state.privacySecuritySettings.auditLoggingEnabled)
        #expect(state.auditLogFiles.isEmpty)

        runtime.storedRelayTelemetrySettings = RelayTelemetrySettingsFfi(
            exportEnabled: true,
            exportIntervalSeconds: 120
        )
        runtime.storedAuditLogSettings = AuditLogSettingsFfi(enabled: true, dataMode: .fullData)
        runtime.storedAuditLogFiles = [
            AuditLogFileFfi(
                accountRef: account.label,
                path: "/tmp/audit-1.jsonl",
                fileName: "audit-1.jsonl",
                sizeBytes: 512,
                modifiedAtMs: 1_800_000_000_000
            )
        ]
        buildConfig = telemetryBuildConfig(environment: "staging")
        runtime.telemetryInstallIdError = FakeMarmotRuntimeError.observabilityConfigurationFailed

        await state.loadPrivacySecuritySettings()

        #expect(state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(state.privacySecuritySettings.relayTelemetryIntervalSeconds == 120)
        #expect(state.privacySecuritySettings.auditLoggingEnabled)
        #expect(state.auditLogFiles.map(\.path) == ["/tmp/audit-1.jsonl"])
        #expect(state.lastError == "Observability configuration failed.")
    }

    @MainActor
    @Test func concurrentPrivacySecurityLoadsCoalesce() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        runtime.clearSyncCallThreadRecords()
        runtime.relayTelemetrySettingsGateEnabled = true
        async let first: Void = state.loadPrivacySecuritySettings()
        while !runtime.didReachRelayTelemetrySettingsGate {
            await Task.yield()
        }
        async let second: Void = state.loadPrivacySecuritySettings()
        await Task.yield()

        #expect(runtime.syncCallThreadRecord("relayTelemetrySettings").count == 1)
        runtime.releaseRelayTelemetrySettingsGate()
        _ = await (first, second)
        #expect(runtime.syncCallThreadRecord("relayTelemetrySettings").count == 1)
    }

    @MainActor
    @Test func privacySecuritySettingsLoadDoesNotOverwriteNewerTelemetrySave() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.storedRelayTelemetrySettings = RelayTelemetrySettingsFfi(
            exportEnabled: false,
            exportIntervalSeconds: 120
        )
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(
                    telemetryToken: "otlp-token",
                    auditToken: "audit-token",
                    environment: "production"
                )
            },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)

        runtime.relayTelemetrySettingsGateEnabled = true
        async let staleLoad: Void = state.loadPrivacySecuritySettings()
        while !runtime.didReachRelayTelemetrySettingsGate {
            await Task.yield()
        }

        await state.setRelayTelemetryEnabled(true)
        #expect(runtime.storedRelayTelemetrySettings.exportEnabled)
        #expect(state.privacySecuritySettings.relayTelemetryEnabled)

        runtime.releaseRelayTelemetrySettingsGate()
        _ = await staleLoad

        #expect(runtime.storedRelayTelemetrySettings.exportEnabled)
        #expect(state.privacySecuritySettings.relayTelemetryEnabled)
    }

    /// A telemetry save that is still mid-flight when the user switches identity must not follow
    /// them there. `isSavingPrivacySecurity` gates the whole page — the loader and both setters
    /// refuse to run while it is raised — so a save left owning it locked the incoming account out
    /// of a page it had never touched, and the outgoing account's answer then published into it.
    @MainActor
    @Test func privacySecuritySaveInFlightDoesNotFollowTheUserToTheNextAccount() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }

        let primary = AccountSummaryFfi(
            label: "Primary Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, backup])
        runtime.storedRelayTelemetrySettings = RelayTelemetrySettingsFfi(
            exportEnabled: false,
            exportIntervalSeconds: 120
        )
        // Pinned so a value another test left behind cannot decide which account boots active.
        UserDefaults.standard.set(primary.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(
                    telemetryToken: "otlp-token",
                    auditToken: "audit-token",
                    environment: "production"
                )
            },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == primary.label)
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)

        runtime.relayTelemetrySettingsGateEnabled = true
        async let save: Void = state.setRelayTelemetryEnabled(true)
        while !runtime.didReachRelayTelemetrySettingsGate {
            await Task.yield()
        }
        #expect(state.isSavingPrivacySecurity)

        let backupAccount = try #require(state.accounts.first { $0.id == backup.label })
        state.selectAccount(backupAccount)

        // The page is the new identity's from the moment it is active, not once the old save
        // happens to finish.
        #expect(state.activeAccountId == backup.label)
        #expect(!state.isSavingPrivacySecurity)

        runtime.releaseRelayTelemetrySettingsGate()
        await save

        // The write still lands where the user asked for it — what it must not do is publish into
        // the account now on screen, re-raise its saving flag, or report its errors there.
        #expect(runtime.storedRelayTelemetrySettings.exportEnabled)
        #expect(!state.privacySecuritySettings.relayTelemetryEnabled)
        #expect(!state.isSavingPrivacySecurity)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func observabilityRuntimeConfigurationSkipsUnchangedRequests() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.removeObject(forKey: "whitenoise.mac.activeAccountId")

        let primary = AccountSummaryFfi(
            label: "primary-account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "secondary-account",
            accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        runtime.installProfile(
            accountIdHex: primary.accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "primary",
                displayName: "Primary Account",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installProfile(
            accountIdHex: secondary.accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "secondary",
                displayName: "Secondary Account",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(
                    telemetryToken: "otlp-token",
                    auditToken: "audit-token",
                    environment: "production"
                )
            },
            clientFactory: { runtime }
        )

        await state.bootstrap()

        #expect(runtime.telemetryInstallIdCallCount == 1)
        #expect(runtime.relayTelemetryRuntimeConfigSetCallCount == 1)
        #expect(runtime.auditLogTrackerConfigSetCallCount == 1)

        // Account identity now lives in the core's JSONL source_context (Goggles
        // contract), so the host-supplied audit tracker config is account-
        // independent. Switching accounts therefore produces an unchanged request
        // that is skipped — the set-call count stays at 1.
        let secondaryItem = try #require(state.accounts.first { $0.accountRef == secondary.label })
        state.selectAccount(secondaryItem)
        let didSwitch = await waitFor {
            state.activeAccountId == secondaryItem.id
        }

        #expect(didSwitch)
        #expect(runtime.telemetryInstallIdCallCount == 1)
        #expect(runtime.relayTelemetryRuntimeConfigSetCallCount == 1)
        #expect(runtime.auditLogTrackerConfigSetCallCount == 1)
    }

    @MainActor
    @Test func staleObservabilityConfigurationCannotRelabelSwitchedAccount() async throws {
        let primary = AccountSummaryFfi(
            label: "Primary Account",
            accountIdHex: String(repeating: "1", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let secondary = AccountSummaryFfi(
            label: "Secondary Account",
            accountIdHex: String(repeating: "2", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [primary, secondary])
        runtime.installProfile(
            accountIdHex: primary.accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "primary",
                displayName: "Primary Display Name",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installProfile(
            accountIdHex: secondary.accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "secondary",
                displayName: "Secondary Display Name",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        var buildConfig = telemetryBuildConfig(environment: "production")
        let state = WorkspaceState(
            telemetryBuildConfigProvider: { buildConfig },
            clientFactory: { runtime }
        )
        await state.bootstrap()

        buildConfig = telemetryBuildConfig(environment: "staging")
        runtime.telemetryInstallIdGateEnabled = true
        async let stalePrimaryConfiguration: Void = state.configureObservabilityRuntime()
        while !runtime.didReachTelemetryInstallIdGate {
            await Task.yield()
        }

        let secondaryItem = try #require(state.accounts.first { $0.id == secondary.label })
        state.prepareForActiveAccountSwitch(to: secondaryItem, preservingMessageCacheFor: nil)
        try await state.configureObservabilityRuntime()
        runtime.releaseTelemetryInstallIdGate()
        try await stalePrimaryConfiguration

        #expect(state.activeAccountId == secondary.label)
        #expect(state.observabilityRuntimeConfiguration?.accountLabel == secondaryItem.displayName)
    }

    @MainActor
    @Test func enablingPrivacySecurityTogglesRequireConfiguredTokens() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(telemetryToken: nil, auditToken: nil)
            },
            clientFactory: { runtime }
        )

        await state.bootstrap()

        await state.setRelayTelemetryEnabled(true)
        #expect(!runtime.storedRelayTelemetrySettings.exportEnabled)
        #expect(state.lastError == "Telemetry credentials are not configured for this build.")

        await state.setAuditLoggingEnabled(true)

        #expect(!runtime.storedAuditLogSettings.enabled)
        #expect(state.lastError == "Audit log credentials are not configured for this build.")
    }

    @MainActor
    @Test func auditLogFileActionsRefreshDeleteAndUploadThroughRuntime() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.storedAuditLogSettings = AuditLogSettingsFfi(enabled: true, dataMode: .obfuscatedSensitiveData)
        runtime.storedAuditLogFiles = [
            AuditLogFileFfi(
                accountRef: account.label,
                path: "/tmp/audit-1.jsonl",
                fileName: "audit-1.jsonl",
                sizeBytes: 123,
                modifiedAtMs: nil
            ),
            AuditLogFileFfi(
                accountRef: account.label,
                path: "/tmp/audit-2.jsonl",
                fileName: "audit-2.jsonl",
                sizeBytes: 456,
                modifiedAtMs: nil
            ),
        ]
        runtime.nextAuditLogTrackerUpdate = AuditLogTrackerUpdateResultFfi(
            enabled: true,
            uploaded: [
                AuditLogUploadResultFfi(path: "/tmp/audit-1.jsonl", status: 200, bytesSent: 123),
                AuditLogUploadResultFfi(path: "/tmp/audit-2.jsonl", status: 200, bytesSent: 456),
            ],
            skippedReason: nil
        )
        let state = WorkspaceState(
            telemetryBuildConfigProvider: {
                telemetryBuildConfig(telemetryToken: "otlp-token", auditToken: "audit-token")
            },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.auditLogFiles.count == 2)

        await state.uploadAuditLogFiles()
        #expect(runtime.didPostAuditLogTrackerUpdate)
        #expect(state.auditLogUploadStatus == "Uploaded 2 audit log files (579 bytes).")

        await state.deleteAllAuditLogFiles()
        #expect(runtime.deletedAuditLogFilePaths == ["/tmp/audit-1.jsonl", "/tmp/audit-2.jsonl"])
        #expect(state.auditLogFiles.isEmpty)
    }

    @MainActor
    @Test func deleteAllAuditLogFilesRefreshesListAfterMidLoopFailure() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let firstFile = AuditLogFileFfi(
            accountRef: account.label,
            path: "/tmp/audit-1.jsonl",
            fileName: "audit-1.jsonl",
            sizeBytes: 123,
            modifiedAtMs: nil
        )
        let secondFile = AuditLogFileFfi(
            accountRef: account.label,
            path: "/tmp/audit-2.jsonl",
            fileName: "audit-2.jsonl",
            sizeBytes: 456,
            modifiedAtMs: nil
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.storedAuditLogFiles = [firstFile, secondFile]
        runtime.auditLogDeleteFailurePaths = [secondFile.path]
        let expectedDeleteError = FakeMarmotRuntimeError.auditLogDeleteFailed.localizedDescription
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.auditLogFiles.map(\.path) == [firstFile.path, secondFile.path])

        await state.deleteAllAuditLogFiles()

        #expect(runtime.deletedAuditLogFilePaths == [firstFile.path])
        #expect(state.auditLogFiles.map(\.path) == [secondFile.path])
        #expect(state.lastError == expectedDeleteError)
    }

    @MainActor
    @Test func enablingLocalNotificationsRequestsPermissionAndUpdatesRuntime() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: false)
        let notificationCenter = FakeLocalNotificationCenter(
            status: .notDetermined,
            requestedStatus: .authorized
        )
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.setLocalNotificationsEnabled(true)

        #expect(notificationCenter.didRequestAuthorization)
        #expect(runtime.localNotificationsEnabledSet == true)
        #expect(state.notificationSettings.localNotificationsEnabled)
        #expect(state.notificationAuthorizationStatus == .authorized)
    }

    @MainActor
    @Test func enablingNativePushWritesThroughAndPublishesTheCoreSnapshot() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.setNativePushEnabled(true)

        #expect(runtime.nativePushEnabledSet == true)
        #expect(state.notificationSettings.nativePushEnabled)
        // Native push carries no message content, so it asks for nothing the local alerts it
        // supplements have not already been granted.
        #expect(!notificationCenter.didRequestAuthorization)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func turningLocalNotificationsOffAlsoClearsNativePushInTheCore() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(
            for: account,
            localEnabled: true,
            nativePushEnabled: true
        )
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.notificationSettings.nativePushEnabled)

        await state.setLocalNotificationsEnabled(false)

        #expect(runtime.localNotificationsEnabledSet == false)
        // The wake-up exists to deliver a local alert, so it cannot outlive one.
        #expect(runtime.nativePushEnabledSet == false)
        #expect(!state.notificationSettings.localNotificationsEnabled)
        #expect(!state.notificationSettings.nativePushEnabled)
    }

    @MainActor
    @Test func turningLocalNotificationsOffLeavesNativePushAloneWhenItIsAlreadyOff() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.setLocalNotificationsEnabled(false)

        #expect(runtime.setNativePushEnabledCallCount == 0)
    }

    @MainActor
    @Test func aFailedNativePushCleanupKeepsTheLocalDisableThatSucceeded() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(
            for: account,
            localEnabled: true,
            nativePushEnabled: true
        )
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        runtime.setNativePushEnabledError = FakeMarmotRuntimeError.nativePushWriteFailed

        await state.setLocalNotificationsEnabled(false)

        // The two flags are separate core writes, so they can fail apart. The one that landed
        // has to reach the pane anyway — publishing only on the pair's success left local
        // alerts drawn as on after the core had already turned them off.
        #expect(runtime.localNotificationsEnabledSet == false)
        #expect(!state.notificationSettings.localNotificationsEnabled)
        // …and the flag that did not move still reads as set, because in the core it is.
        #expect(state.notificationSettings.nativePushEnabled)
        #expect(state.lastError != nil)
    }

    @MainActor
    @Test func failedNativePushWriteSurfacesTheErrorAndLeavesTheSnapshotAlone() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        runtime.setNativePushEnabledError = FakeMarmotRuntimeError.nativePushWriteFailed
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.setNativePushEnabled(true)

        #expect(!state.notificationSettings.nativePushEnabled)
        #expect(state.lastError != nil)
    }

    @MainActor
    @Test func enablingLocalNotificationsShowsSettingsGuidanceWhenMacNotificationsAreNotAllowed() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: false)
        let notificationCenter = FakeLocalNotificationCenter(
            status: .notDetermined,
            requestError: NSError(
                domain: UNErrorDomain,
                code: UNError.Code.notificationsNotAllowed.rawValue
            )
        )
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.setLocalNotificationsEnabled(true)

        #expect(notificationCenter.didRequestAuthorization)
        #expect(runtime.localNotificationsEnabledSet == nil)
        #expect(!state.notificationSettings.localNotificationsEnabled)
        #expect(state.notificationAuthorizationStatus == .denied)
        #expect(
            state.lastError
                == "Open System Settings > Notifications and allow White Noise notifications, then try again.")
    }

    @MainActor
    @Test func refreshingNotificationPermissionRetiresGuidanceAfterSystemSettingsGrant() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: false)
        let notificationCenter = FakeLocalNotificationCenter(
            status: .notDetermined,
            requestError: NSError(
                domain: UNErrorDomain,
                code: UNError.Code.notificationsNotAllowed.rawValue
            )
        )
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.setLocalNotificationsEnabled(true)
        #expect(state.lastError == WorkspaceState.notificationPermissionGuidance)

        // The user grants the permission in System Settings and returns to White Noise.
        notificationCenter.simulateSystemAuthorizationChange(.authorized)
        await state.refreshNotificationPermissionState()

        #expect(state.notificationAuthorizationStatus == .authorized)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func refreshingNotificationPermissionKeepsUnrelatedErrorAndStaleGuidance() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: false)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.lastError = "Could not reach relay."
        await state.refreshNotificationPermissionState()
        #expect(state.lastError == "Could not reach relay.")

        // Still denied: the guidance is exactly what the user needs to keep seeing.
        notificationCenter.simulateSystemAuthorizationChange(.denied)
        state.lastError = WorkspaceState.notificationPermissionGuidance
        await state.refreshNotificationPermissionState()
        #expect(state.notificationAuthorizationStatus == .denied)
        #expect(state.lastError == WorkspaceState.notificationPermissionGuidance)
    }

    @MainActor
    @Test func openingASettingsPageClearsThePreviousPanesError() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showSettingsPage(.notifications)
        state.lastError = WorkspaceState.notificationPermissionGuidance

        state.showSettingsPage(.storage)

        #expect(state.selection == .settings(.storage))
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func archivedChatSuppressesIncomingNotification() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        var archivedGroup = messageGroup()
        archivedGroup.archived = true
        runtime.installGroups([archivedGroup, directGroup()])
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.archivedChats.map(\.id) == [archivedGroup.groupIdHex])

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "archived-notice",
                groupIdHex: archivedGroup.groupIdHex,
                senderName: "Alice",
                previewText: "Still talking in here."
            ))

        #expect(notificationCenter.postedRequests.isEmpty)

        // The gate is per chat, not per account: an unarchived conversation still rings.
        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "active-notice",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "Over here though."
            ))

        #expect(notificationCenter.postedRequests.map(\.identifier) == ["active-notice"])
    }

    @MainActor
    @Test func archivedChatOnBackgroundAccountSuppressesIncomingNotification() async throws {
        // The notification listener is client-wide, but the chat list — the app's only in-memory
        // record of what is filed away — is maintained for the active account alone. A background
        // account's archive state therefore has to come from the core, or archived chats on every
        // account but the open one keep interrupting.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let accountA = desktopAccount()
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: accountA.label,
            settings: notificationSettings(for: accountA, localEnabled: true)
        )
        runtime.installNotificationSettings(
            accountRef: accountB.label,
            settings: notificationSettings(for: accountB, localEnabled: true)
        )
        UserDefaults.standard.set(accountA.label, forKey: WorkspaceState.activeAccountKey)
        var archivedGroup = messageGroup()
        archivedGroup.archived = true
        runtime.installGroups([archivedGroup, directGroup()])
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == accountA.label)

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: accountB,
                notificationKey: "background-archived-notice",
                groupIdHex: archivedGroup.groupIdHex,
                senderName: "Alice",
                previewText: "Still talking in here."
            ))

        #expect(notificationCenter.postedRequests.isEmpty)

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: accountB,
                notificationKey: "background-active-notice",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "Over here though."
            ))

        #expect(notificationCenter.postedRequests.map(\.identifier) == ["background-active-notice"])
    }

    @MainActor
    @Test func unreadableArchiveStateStillPostsNotification() async throws {
        // A chat the app has no row for (nothing loaded yet, or a conversation that arrives with
        // the notification) whose archive state cannot be read must still ring: a notification the
        // user wanted is worth more than one they had filed away.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        runtime.groupDetailsFailureGroupIds.insert("unknown-group")
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.chatItem(accountId: account.label, chatId: "unknown-group") == nil)

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "unknown-notice",
                groupIdHex: "unknown-group",
                senderName: "Alice",
                previewText: "Who is this?"
            ))

        #expect(notificationCenter.postedRequests.map(\.identifier) == ["unknown-notice"])
    }

    @MainActor
    @Test func reactionViewerSanitizesResolvedPeerNames() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let reactorId = String(repeating: "b", count: 64)
        state.peerProfileFFICache[reactorId] = WorkspaceState.CachedPeerProfile(
            resolved: WorkspaceState.ResolvedPeerFFI(
                profileDisplayName: "Trusted\u{202E} Admin\u{2066}",
                profileName: nil,
                profilePicture: nil,
                directoryDisplayName: nil
            ),
            resolvedAt: Date()
        )

        let reactor = state.reactionReactorDisplay(accountIdHex: reactorId)
        #expect(reactor.name == "Trusted Admin")
        #expect(!reactor.name.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x2066 })
    }

    @MainActor
    @Test func incomingNotificationReadsSettingsOnceForActiveAccount() async throws {
        // Issue #111: `handleNotificationUpdate(_:)` previously read the account's
        // notification settings twice over the FFI boundary for the active account
        // — once to sync the published snapshot and once to gate delivery. The two
        // responsibilities now share a single `notificationSettings(accountRef:)`
        // read.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        // Ignore any `notificationSettings` reads performed during bootstrap; only
        // the handler's own reads are under test.
        runtime.clearSyncCallThreadRecords()

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "notice-1",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "See you there."
            ))

        // Exactly one FFI read for the active-account path (was two before the fix),
        // and it still runs off the main thread.
        let reads = runtime.syncCallThreadRecord("notificationSettings")
        #expect(reads.count == 1)
        #expect(reads.allSatisfy { !$0 })
        // The single read still drives both the published snapshot and delivery.
        #expect(state.notificationSettings.localNotificationsEnabled)
        #expect(notificationCenter.postedRequests.count == 1)
    }

    @MainActor
    @Test func staleIncomingNotificationSettingsReadDoesNotClobberCommittedToggle() async throws {
        // Issue #428: a notification update reuses one settings read for both the
        // published snapshot and delivery gate. If that read was already in flight
        // when a same-account toggle committed, its stale snapshot must not
        // overwrite the newer toggle state.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: false)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")
        #expect(!state.notificationSettings.localNotificationsEnabled)

        runtime.notificationSettingsGateEnabled = true
        async let staleUpdate: Void = state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "notice-1",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "See you there."
            ))
        while !runtime.didReachNotificationSettingsGate {
            await Task.yield()
        }

        await state.setLocalNotificationsEnabled(true)
        #expect(runtime.localNotificationsEnabledSet == true)
        #expect(state.notificationSettings.localNotificationsEnabled)

        runtime.releaseNotificationSettingsGate()
        _ = await staleUpdate

        #expect(state.notificationSettings.localNotificationsEnabled)
        #expect(notificationCenter.postedRequests.isEmpty)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func activeChatNotificationIsSuppressedWhileAppIsActive() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "notice-1",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "See you there."
            ))

        #expect(state.selection == .chat("direct-group"))
        #expect(notificationCenter.postedRequests.isEmpty)
    }

    @MainActor
    @Test func activeVisibleChatDoesNotSuppressNotificationForOtherLocalAccountInSameGroup() async throws {
        // Issue #591: the client-wide notification listener serves every local account.
        // Suppression must require the update to target the active account; viewing the
        // same MLS group as account A must not drop a notification addressed to account B.
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let sharedGroup = directGroup()
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: accountA.label,
            settings: notificationSettings(for: accountA, localEnabled: true)
        )
        runtime.installNotificationSettings(
            accountRef: accountB.label,
            settings: notificationSettings(for: accountB, localEnabled: true)
        )
        UserDefaults.standard.set(accountA.label, forKey: WorkspaceState.activeAccountKey)
        runtime.installDirectGroup(
            sharedGroup,
            selfAccountIdHex: accountA.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.activeAccountId == accountA.label)
        #expect(state.selection == .chat(sharedGroup.groupIdHex))

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: accountB,
                notificationKey: "notice-for-b",
                groupIdHex: sharedGroup.groupIdHex,
                senderName: "Alice",
                previewText: "For account B only."
            ))

        #expect(notificationCenter.postedRequests.map(\.identifier) == ["notice-for-b"])
    }

    @MainActor
    @Test func accountSwitchPreservesClientWideNotificationReplayDeduplication() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installNotificationSettings(
            accountRef: accountA.label,
            settings: notificationSettings(for: accountA, localEnabled: true)
        )
        runtime.installNotificationSettings(
            accountRef: accountB.label,
            settings: notificationSettings(for: accountB, localEnabled: true)
        )
        UserDefaults.standard.set(accountA.label, forKey: WorkspaceState.activeAccountKey)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )
        let messageIdHex = String(repeating: "f", count: 64)
        let accountAKey = "message:\(accountA.accountIdHex):\(messageIdHex)"
        let accountBKey = "message:\(accountB.accountIdHex):\(messageIdHex)"
        let accountAUpdate = notificationUpdate(
            account: accountA,
            notificationKey: accountAKey,
            senderName: "Alice",
            previewText: "For account A.",
            messageIdHex: messageIdHex
        )

        await state.bootstrap()
        await state.handleNotificationUpdate(accountAUpdate)
        state.prepareForActiveAccountSwitch(
            to: AccountItem(summary: accountB),
            preservingMessageCacheFor: nil
        )
        await state.handleNotificationUpdate(accountAUpdate)
        await state.handleNotificationUpdate(
            notificationUpdate(
                account: accountB,
                notificationKey: accountBKey,
                senderName: "Alice",
                previewText: "For account B.",
                messageIdHex: messageIdHex
            ))

        // The listener is client-wide, so an account-A replay can still arrive after
        // switching to B. The vendored MDK account-namespaces keys, allowing B's
        // distinct update through while the replay remains suppressed. See #646.
        #expect(notificationCenter.postedRequests.map(\.identifier) == [accountAKey, accountBKey])
    }

    @MainActor
    @Test func activeSelectedChatNotificationPostsLocalAlertWhenConversationWindowIsHidden() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "notice-1",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "See you there."
            ))

        #expect(state.selection == .chat("direct-group"))
        #expect(notificationCenter.postedRequests.map(\.identifier) == ["notice-1"])
    }

    @MainActor
    @Test func selfNotificationsAndDuplicatesAreSuppressed() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "self-notice",
                senderName: "Desktop Account",
                previewText: "Sent by me.",
                isFromSelf: true
            ))
        let incoming = notificationUpdate(
            account: account,
            notificationKey: "duplicate-notice",
            senderName: "Alice",
            previewText: "Only once."
        )
        await state.handleNotificationUpdate(incoming)
        await state.handleNotificationUpdate(incoming)

        #expect(notificationCenter.postedRequests.map(\.identifier) == ["duplicate-notice"])
    }

    @MainActor
    @Test func notificationResponseSelectsConversation() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.showSettings()
        notificationCenter.simulateResponse([
            "accountRef": account.label,
            "accountIdHex": account.accountIdHex,
            "groupIdHex": "direct-group",
        ])

        #expect(state.activeAccountId == account.label)
        #expect(state.selection == .chat("direct-group"))
    }

    @MainActor
    @Test func publishingNewKeyPackageRefreshesPackageList() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.publishNewKeyPackage()

        #expect(runtime.didPublishNewKeyPackage)
        #expect(state.keyPackages.map(\.eventIdHex).contains("event-new"))
    }

    @MainActor
    @Test func deletingKeyPackageUsesAccountRelayBootstrapRelaysAndRefreshes() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let bootstrapRelays = ["wss://bootstrap.example"]
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: bootstrapRelays,
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox.example"]
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        await state.loadKeyPackages()
        guard let fetchedPackage = state.keyPackages.last else {
            Issue.record("Expected a fetched key package")
            return
        }
        await state.deleteKeyPackage(fetchedPackage)

        #expect(runtime.deletedPackageEventId == "event-fetched")
        #expect(runtime.lastPackageDeleteRelays == bootstrapRelays)
        #expect(!state.keyPackages.map(\.eventIdHex).contains("event-fetched"))
    }

    @MainActor
    @Test func savingProfileUsesAccountRelayLists() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let publishRelays = ["wss://published.example"]
        let bootstrapRelays = ["wss://bootstrap.example"]
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installRelayLists(
            defaultRelays: publishRelays,
            bootstrapRelays: bootstrapRelays,
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox.example"]
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        state.profileDraft.displayName = "Desktop Renamed"
        await state.saveProfile()

        #expect(runtime.lastPublishedProfileDefaultRelays == publishRelays)
        #expect(runtime.lastPublishedProfileBootstrapRelays == bootstrapRelays)
        #expect(state.profileDraft.displayName == "Desktop Renamed")
    }

    // MARK: - Settings → Profile's edit mode

    /// The page opens read-only, and Cancel undoes *everything* Edit was pressed on.
    ///
    /// The picture is the field this exists for. Choosing one uploads immediately and writes
    /// `profileDraft.picture` long before anything is published, so a Cancel that only restored
    /// the text would leave the page showing a new face nobody agreed to publish — and would then
    /// publish it on the next Save.
    ///
    /// It also covers the picture as an *edit*: the actions have to appear for a face somebody
    /// changed without touching a field, which is why `hasUnsavedProfileEdits` compares whole
    /// drafts rather than auditing the text.
    @MainActor
    @Test func discardingProfileEditsRestoresEveryFieldIncludingThePicture() async throws {
        let accountIdHex = String(repeating: "ab", count: 32)
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installProfile(
            accountIdHex: accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "marmota",
                displayName: "Marmota",
                about: "A marmot.",
                picture: "https://example.com/before.png",
                nip05: "marmota@example.com",
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()

        // The load is what sets the baseline now — there is no Edit to press.
        #expect(state.publishedProfile != nil)
        #expect(state.hasUnsavedProfileEdits == false)

        state.profileDraft.displayName = "Pebble"
        state.profileDraft.about = "Somebody else."
        state.profileDraft.nip05 = "pebble@example.com"
        state.profileDraft.picture = "https://example.com/after.png"
        #expect(state.hasUnsavedProfileEdits)

        state.discardProfileEdits()

        #expect(state.hasUnsavedProfileEdits == false)
        #expect(state.publishedProfile != nil, "the baseline is the published profile, not a session")
        #expect(state.profileDraft.displayName == "Marmota")
        #expect(state.profileDraft.about == "A marmot.")
        #expect(state.profileDraft.nip05 == "marmota@example.com")
        #expect(state.profileDraft.picture == "https://example.com/before.png")
        // Nothing left the machine.
        #expect(runtime.publishUserProfileCallCount == 0)
    }

    /// A check in flight verifies the **published** address, whatever the field says by the time it
    /// runs.
    ///
    /// `beginProfileNostrAddressCheck()` schedules the work rather than performing it, so every
    /// keystroke between the scheduling and the task's first line lands before the address is read.
    /// Reading `profileDraft` there put a verdict about an unsaved address into
    /// `publishedNostrAddressVerification`, which is a statement about what the profile publishes —
    /// and `discardProfileEdits()` then restores the published address without disturbing it, so the
    /// published address wore a seal earned by an address that was thrown away. Staged in the
    /// dangerous direction: the draft is the one that verifies.
    ///
    /// Deterministic without a gate. The task is main-actor isolated, so its body cannot begin
    /// until this test suspends; the assignment below is synchronous and therefore always wins the
    /// race that used to be one.
    @MainActor
    @Test func theAddressCheckVerifiesThePublishedValueNotAPendingDraft() async throws {
        let accountIdHex = String(repeating: "6f", count: 32)
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installProfile(
            accountIdHex: accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "marmota",
                displayName: "Marmota",
                about: nil,
                picture: nil,
                // Published, and unverifiable: the resolver below does not know it.
                nip05: "marmota@offline.example",
                lud16: nil
            )
        )
        // The *draft* address is the one that would earn a seal.
        let resolver = RecordingNIP05Resolver(accountReferences: ["stranger@example.com": accountIdHex])
        let state = WorkspaceState(nip05Resolver: resolver, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        await state.profileNostrAddressCheckTask?.value

        #expect(state.publishedNostrAddressVerification == .unverified)
        #expect(resolver.requestedIdentifiers == ["marmota@offline.example"])

        // A check is in flight, and the field moves under it before it reads anything.
        state.beginProfileNostrAddressCheck()
        state.profileDraft.nip05 = "stranger@example.com"
        await state.profileNostrAddressCheckTask?.value

        #expect(
            resolver.requestedIdentifiers == ["marmota@offline.example", "marmota@offline.example"],
            "the pending check went out for the draft: \(resolver.requestedIdentifiers)")

        state.discardProfileEdits()

        #expect(state.profileDraft.nip05 == "marmota@offline.example")
        #expect(
            state.publishedNostrAddressVerification == .unverified,
            "a discarded draft left its verdict on the published address")
        #expect(
            state.profileNostrAddressSeal == .unverified,
            "the published address wore a seal earned by an address nobody published")
    }

    /// The fields are closed while the settings load is in flight, because there is nowhere for
    /// what is typed into them to go: `performSettingsLoad` *replaces* `profileDraft` with what it
    /// reads, so a name typed before it lands is discarded without a word.
    ///
    /// Unreachable while the page opened read-only behind an Edit button that was itself disabled
    /// on `isLoadingSettings`. With the fields live from the moment the page appears, that window
    /// is exactly when somebody arrives and starts typing.
    @MainActor
    @Test func theProfileFormIsClosedWhileTheSettingsLoadIsInFlight() async throws {
        let accountIdHex = String(repeating: "8d", count: 32)
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installProfile(
            accountIdHex: accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "marmota",
                displayName: "Marmota",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        // Suspend the load inside the profile read, which is the await the draft is replaced after.
        runtime.userProfileGateEnabled = true
        async let load: Void = state.loadSettingsData()
        while !runtime.didReachUserProfileGate {
            await Task.yield()
        }

        #expect(state.isLoadingSettings)
        #expect(state.isProfileFormEnabled == false)

        runtime.releaseUserProfileGate()
        _ = await load

        #expect(state.isLoadingSettings == false)
        #expect(state.isProfileFormEnabled)
        #expect(state.profileDraft.displayName == "Marmota")
    }

    /// An account with nothing published opens the same way one with a full profile does: no
    /// actions.
    ///
    /// This is the case the gate is easiest to get wrong, because the form and the baseline are
    /// both empty and "empty" is what an unedited draft looks like before a load has happened at
    /// all. If `publishedProfile` were left `nil` here the page would be correct by accident; if
    /// the load skipped setting it, the first keystroke would still be the first *edit*, but a
    /// Cancel pressed afterwards would have nothing to restore.
    @MainActor
    @Test func aProfileWithNothingPublishedOpensWithoutActions() async throws {
        let accountIdHex = String(repeating: "5e", count: 32)
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.accountIdsMissingProfiles.insert(accountIdHex)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()

        #expect(state.publishedProfile != nil, "the load left no baseline for Cancel to restore")
        #expect(state.hasUnsavedProfileEdits == false, "an untouched empty form asked to be saved")

        state.profileDraft.about = "A marmot."
        #expect(state.hasUnsavedProfileEdits)

        state.discardProfileEdits()
        #expect(state.hasUnsavedProfileEdits == false)
        #expect(state.profileDraft.about.isEmpty)
    }

    /// Save publishes the canonical spelling of the address and moves the baseline onto it, which
    /// is what puts the actions away. A failed publish does neither — the fields stay as typed and
    /// the row stays up, so the same Save can be pressed again.
    @MainActor
    @Test func savingTheProfileNormalizesTheAddressAndMovesTheBaseline() async throws {
        let accountIdHex = String(repeating: "cd", count: 32)
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()

        state.profileDraft.displayName = "Marmota"
        state.profileDraft.nip05 = "  MARMOTA@Example.COM  "
        #expect(state.hasUnsavedProfileEdits)

        runtime.publishUserProfileError = FakeMarmotRuntimeError.profilePublishFailed
        await state.saveProfile()
        #expect(state.hasUnsavedProfileEdits, "a failed publish put the actions away")

        runtime.publishUserProfileError = nil
        await state.saveProfile()

        #expect(state.hasUnsavedProfileEdits == false)
        #expect(state.profileDraft.nip05 == "marmota@example.com")
        #expect(state.publishedProfile?.nip05 == "marmota@example.com")
    }

    /// The seal is a network answer, not a fixture: it appears only when the address's own domain
    /// names *this* account, and a domain that names somebody else earns nothing.
    @MainActor
    @Test func theSealIsEarnedFromTheAddressOwnDomain() async throws {
        let accountIdHex = String(repeating: "ef", count: 32)
        let strangerIdHex = String(repeating: "12", count: 32)

        for (reference, expected) in [
            (accountIdHex, NostrAddressVerification.verified),
            (strangerIdHex, NostrAddressVerification.unverified),
        ] {
            let account = AccountSummaryFfi(
                label: "Desktop Account",
                accountIdHex: accountIdHex,
                localSigning: true,
                externalSigning: false,
                signedOut: false,
                running: true
            )
            let runtime = FakeMarmotRuntime(accounts: [account])
            runtime.installProfile(
                accountIdHex: accountIdHex,
                profile: UserProfileMetadataFfi(
                    name: "marmota",
                    displayName: "Marmota",
                    about: nil,
                    picture: nil,
                    nip05: "marmota@example.com",
                    lud16: nil
                )
            )
            let state = WorkspaceState(
                nip05Resolver: StubNIP05Resolver(accountReferences: ["marmota@example.com": reference]),
                clientFactory: { runtime }
            )

            await state.bootstrap()
            await state.loadSettingsData()
            // Awaited rather than polled: the check is a stored handle precisely so a test does
            // not have to guess how many yields a resolver takes.
            await state.profileNostrAddressCheckTask?.value

            #expect(state.publishedNostrAddressVerification == expected)
            #expect(state.profileNostrAddressSeal == expected)
        }
    }

    /// A domain that cannot be reached has verified nothing, and says so by drawing no seal rather
    /// than by reporting a network error over a field nobody asked to publish.
    @MainActor
    @Test func anUnreachableDomainLeavesTheAddressUnverifiedAndSilent() async throws {
        let accountIdHex = String(repeating: "9a", count: 32)
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installProfile(
            accountIdHex: accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "marmota",
                displayName: "Marmota",
                about: nil,
                picture: nil,
                nip05: "marmota@offline.example",
                lud16: nil
            )
        )
        let state = WorkspaceState(
            nip05Resolver: StubNIP05Resolver(accountReferences: [:]),
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadSettingsData()
        await state.profileNostrAddressCheckTask?.value

        #expect(state.publishedNostrAddressVerification == .unverified)
        #expect(state.lastError == nil)
    }

    /// `wn-ios-prototype`'s rule, verbatim: editing a verified address makes the draft unverified,
    /// and re-entering the stored value restores the seal before Save is ever pressed. No network
    /// call is made for either — a keystroke must not fire a request at a half-typed domain.
    @MainActor
    @Test func editingTheAddressDropsTheSealAndRetypingItRestoresIt() async throws {
        let accountIdHex = String(repeating: "7b", count: 32)
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installProfile(
            accountIdHex: accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "marmota",
                displayName: "Marmota",
                about: nil,
                picture: nil,
                nip05: "marmota@example.com",
                lud16: nil
            )
        )
        let resolver = StubNIP05Resolver(accountReferences: ["marmota@example.com": accountIdHex])
        let state = WorkspaceState(nip05Resolver: resolver, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        await state.profileNostrAddressCheckTask?.value
        #expect(state.profileNostrAddressSeal == .verified)

        state.profileDraft.nip05 = "marmota@elsewhere.example"
        #expect(state.profileNostrAddressSeal == .unverified)
        // The stored verdict is untouched — it is a statement about the published value.
        #expect(state.publishedNostrAddressVerification == .verified)

        state.profileDraft.nip05 = "MARMOTA@example.com"
        #expect(state.profileNostrAddressSeal == .verified, "the stored value retyped lost its seal")

        state.profileDraft.nip05 = ""
        #expect(state.profileNostrAddressSeal == .none)
    }

    /// What Save is allowed to be pressed on: a name, and an address that is either absent or
    /// address-shaped.
    @MainActor
    @Test func saveIsGatedOnANameAndAnAddressThatParses() async throws {
        let accountIdHex = String(repeating: "3c", count: 32)
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: accountIdHex,
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: [account]) })

        await state.bootstrap()
        await state.loadSettingsData()

        state.profileDraft.displayName = "Marmota"
        state.profileDraft.nip05 = ""
        #expect(state.isProfileNostrAddressDraftValid)
        #expect(state.canSaveProfileEdits)

        state.profileDraft.nip05 = "marmota"
        #expect(state.isProfileNostrAddressDraftValid == false)
        #expect(state.canSaveProfileEdits == false)

        state.profileDraft.nip05 = "marmota@example.com"
        #expect(state.canSaveProfileEdits)

        state.profileDraft.displayName = "   \n\t "
        #expect(state.canSaveProfileEdits == false)
    }

    /// The baseline is account-scoped. Carried across a switch, account A's name, about and
    /// picture would be restorable onto account B by pressing Cancel — and B's untouched form would
    /// come up showing Cancel and Save, because it differs from A's profile in every field.
    @MainActor
    @Test func switchingAccountsDropsTheProfileBaseline() async throws {
        let first = AccountSummaryFfi(
            label: "First",
            accountIdHex: String(repeating: "1a", count: 32),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let second = AccountSummaryFfi(
            label: "Second",
            accountIdHex: String(repeating: "2b", count: 32),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [first, second])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        state.profileDraft.displayName = "Half-typed"
        #expect(state.hasUnsavedProfileEdits)

        let target = try #require(state.accounts.first { $0.accountIdHex == second.accountIdHex })
        state.selectAccount(target)

        #expect(state.publishedProfile == nil)
        #expect(state.hasUnsavedProfileEdits == false, "B's untouched form came up asking to be saved")
        #expect(state.publishedNostrAddressVerification == .none)
    }

    @MainActor
    @Test func publishingRelayListsUsesExistingBootstrapRelays() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let bootstrapRelays = ["wss://bootstrap.example"]
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: bootstrapRelays,
            nip65: ["wss://old-nip65.example"],
            inbox: ["wss://old-inbox.example"]
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        await state.addRelay("wss://new-inbox.example", roles: [.inbox])
        await state.setRelayRole(.inbox, isEnabled: false, forRelay: "wss://old-inbox.example")

        #expect(runtime.lastSetInboxBootstrapRelays == bootstrapRelays)
        #expect(state.relaySettings.inbox == ["wss://new-inbox.example"])
    }

    @MainActor
    @Test func staleProfileSaveDoesNotClobberSwitchedAccount() async throws {
        // Issue #287: `saveProfile` captures `accountRef` for the publish but writes `profileDraft` /
        // the `accounts[]` entry via the live active account afterward. On an A→B switch while the
        // publish is in flight, account A's just-published name must not be misattributed to B.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: ["wss://bootstrap.example"],
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox.example"]
        )
        runtime.installProfile(
            accountIdHex: accountB.accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "backup",
                displayName: "Backup Original",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        #expect(state.activeAccountId == "Desktop Account")

        // Arm the gate so account A's publish suspends in-flight.
        runtime.publishUserProfileGateEnabled = true
        state.profileDraft.displayName = "Desktop Renamed"
        async let staleSave: Void = state.saveProfile()
        while !runtime.didReachPublishUserProfileGate {
            await Task.yield()
        }

        // Switch to account B and load its settings to completion.
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")
        await state.loadSettingsData()
        #expect(state.profileDraft.displayName == "Backup Original")

        // Release account A's stale publish; its post-await write must not touch account B's state.
        runtime.releasePublishUserProfileGate()
        _ = await staleSave

        #expect(state.profileDraft.displayName == "Backup Original")
        let backupEntry = try #require(state.accounts.first { $0.id == "Backup Account" })
        #expect(backupEntry.displayName == "Backup Original")
    }

    @MainActor
    @Test func staleRelaySaveDoesNotClobberSwitchedAccount() async throws {
        // Issue #287: the relay writer behind Add Relay writes `relaySettings` via the live active
        // account after its FFI await. On an A→B switch while the write is in flight, account A's
        // just-saved relays must not be misattributed to B.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: ["wss://bootstrap.example"],
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox-a.example"]
        )
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadSettingsData()
        #expect(state.activeAccountId == "Desktop Account")

        // Arm the gate so account A's relay save suspends in-flight.
        runtime.setAccountRelaysGateEnabled = true
        async let staleSave: Void = state.addRelay("wss://saved-by-a.example", roles: [.inbox])
        while !runtime.didReachSetAccountRelaysGate {
            await Task.yield()
        }

        // Switch to account B and load its (distinct) inbox to completion.
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: ["wss://bootstrap.example"],
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox-b.example"]
        )
        await state.loadSettingsData()
        #expect(state.relaySettings.inbox == ["wss://inbox-b.example"])

        // Release account A's stale save; its post-await write must not touch account B's state.
        runtime.releaseSetAccountRelaysGate()
        _ = await staleSave

        #expect(state.relaySettings.inbox == ["wss://inbox-b.example"])
    }

    @MainActor
    @Test func staleSettingsProfileLoadDoesNotClobberSwitchedAccount() async throws {
        // Issue #283: `performSettingsLoad` reads `userProfile` over the non-cancellation-aware FFI
        // boundary, then writes `profileDraft` and — via the live `activeAccountId` —
        // `updateActiveAccountProfile`. On an A→B switch while account A's read is in flight, A's
        // profile must not overwrite B's freshly-loaded `profileDraft` or B's `accounts[]` entry.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: ["wss://bootstrap.example"],
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox.example"]
        )
        runtime.installProfile(
            accountIdHex: accountA.accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "desktop",
                displayName: "Desktop Original",
                about: nil,
                picture: "https://example.com/desktop.png",
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installProfile(
            accountIdHex: accountB.accountIdHex,
            profile: UserProfileMetadataFfi(
                name: "backup",
                displayName: "Backup Original",
                about: nil,
                picture: "https://example.com/backup.png",
                nip05: nil,
                lud16: nil
            )
        )
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")

        // Arm the gate so account A's profile read suspends in-flight.
        runtime.userProfileGateEnabled = true
        async let staleLoad: Void = state.loadSettingsData()
        while !runtime.didReachUserProfileGate {
            await Task.yield()
        }

        // Switch to account B and load its settings to completion.
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")
        await state.loadSettingsData()
        #expect(state.profileDraft.displayName == "Backup Original")

        // Release account A's stale read; its post-await writes must not touch account B's state.
        runtime.releaseUserProfileGate()
        _ = await staleLoad

        #expect(state.profileDraft.displayName == "Backup Original")
        #expect(state.profileDraft.picture == "https://example.com/backup.png")
        let backupEntry = try #require(state.accounts.first { $0.id == "Backup Account" })
        #expect(backupEntry.displayName == "Backup Original")
        #expect(backupEntry.pictureURL == "https://example.com/backup.png")
    }

    @MainActor
    @Test func staleSettingsRelayLoadDoesNotClobberSwitchedAccount() async throws {
        // Issue #283: `performSettingsLoad` reads `accountRelayLists` over the non-cancellation-aware
        // FFI boundary, then writes `relaySettings`. On an A→B switch while account A's
        // read is in flight, A's relays must not overwrite B's freshly-loaded relay state.
        let accountA = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountB = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [accountA, accountB])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: ["wss://bootstrap.example"],
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox-a.example"]
        )
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.activeAccountId == "Desktop Account")

        // Arm the gate so account A's relay read suspends in-flight.
        runtime.accountRelayListsGateEnabled = true
        async let staleLoad: Void = state.loadSettingsData()
        while !runtime.didReachAccountRelayListsGate {
            await Task.yield()
        }

        // Switch to account B and load its (distinct) inbox to completion.
        let backupAccount = try #require(state.accounts.first { $0.id == "Backup Account" })
        state.selectAccountFromSettings(backupAccount)
        #expect(state.activeAccountId == "Backup Account")
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: ["wss://bootstrap.example"],
            nip65: ["wss://nip65.example"],
            inbox: ["wss://inbox-b.example"]
        )
        await state.loadSettingsData()
        #expect(state.relaySettings.inbox == ["wss://inbox-b.example"])

        // Release account A's stale read; its post-await writes must not touch account B's state.
        runtime.releaseAccountRelayListsGate()
        _ = await staleLoad

        #expect(state.relaySettings.inbox == ["wss://inbox-b.example"])
    }

    // MARK: - Relay editing (issues #18, #287; prototype Relays flows)

    /// The account + relay lists every relay-editing test below starts from: one relay in each
    /// list, so a role can be turned off without being the last of its kind.
    @MainActor
    private func relayEditingState() async -> (WorkspaceState, FakeMarmotRuntime) {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installRelayLists(
            defaultRelays: ["wss://published.example"],
            bootstrapRelays: ["wss://bootstrap.example"],
            nip65: ["wss://profile.example", "wss://both.example"],
            inbox: ["wss://inbox.example", "wss://both.example"]
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        await state.loadSettingsData()
        return (state, runtime)
    }

    @MainActor
    @Test func addRelayRejectsCleartextPublicWsRelay() async throws {
        let (state, runtime) = await relayEditingState()
        let before = state.relaySettings

        await state.addRelay("ws://relay.example.com", roles: [.profile])

        #expect(state.relaySettings == before)
        #expect(runtime.lastSetNip65BootstrapRelays.isEmpty)
        #expect(state.lastError != nil)
    }

    @MainActor
    @Test func addRelayAcceptsSecureAndLoopbackRelays() async throws {
        let (state, _) = await relayEditingState()

        await state.addRelay("wss://relay.example.com", roles: [.profile])
        await state.addRelay("ws://127.0.0.1:7000", roles: [.profile])

        #expect(
            state.relaySettings.nip65 == [
                "wss://profile.example", "wss://both.example", "wss://relay.example.com", "ws://127.0.0.1:7000",
            ])
        #expect(!state.isInsecureRelay("wss://relay.example.com"))
        #expect(state.isInsecureRelay("ws://127.0.0.1:7000"))
    }

    /// A trailing slash is not a different relay, so adding `wss://both.example/` must be seen as
    /// the duplicate it is rather than appended beside the entry it matches.
    @MainActor
    @Test func addRelayTreatsATrailingSlashAsTheSameRelay() async throws {
        let (state, _) = await relayEditingState()
        let before = state.relaySettings

        await state.addRelay("wss://both.example/", roles: [.profile, .inbox])

        #expect(state.relaySettings == before)
    }

    /// The prototype's Add Relay sheet activates every selected role in one action, which here is
    /// two published lists from one press.
    @MainActor
    @Test func addRelayAssignsEverySelectedRoleInOneAction() async throws {
        let (state, _) = await relayEditingState()

        await state.addRelay("wss://new.example", roles: [.profile, .inbox])

        #expect(state.relaySettings.nip65.contains("wss://new.example"))
        #expect(state.relaySettings.inbox.contains("wss://new.example"))
        let endpoint = try #require(state.relayEndpoints.first { $0.id == "wss://new.example" })
        #expect(endpoint.roles == [.profile, .inbox])
    }

    @MainActor
    @Test func setRelayRoleTurnsOneListOffWithoutTouchingTheOther() async throws {
        let (state, _) = await relayEditingState()

        await state.setRelayRole(.inbox, isEnabled: false, forRelay: "wss://both.example")

        #expect(state.relaySettings.inbox == ["wss://inbox.example"])
        #expect(state.relaySettings.nip65 == ["wss://profile.example", "wss://both.example"])
    }

    /// The core refuses to publish an empty relay list, so the last relay of a role cannot be
    /// unassigned — and the refusal has to happen here, not only in the disabled toggle.
    @MainActor
    @Test func turningOffARolesOnlyRelayIsRefused() async throws {
        let (state, _) = await relayEditingState()
        await state.setRelayRole(.inbox, isEnabled: false, forRelay: "wss://both.example")
        let before = state.relaySettings

        await state.setRelayRole(.inbox, isEnabled: false, forRelay: "wss://inbox.example")

        #expect(state.relaySettings == before)
        #expect(state.lastError != nil)
        #expect(state.relaySettings.isOnlyRelay("wss://inbox.example", for: .inbox))
        #expect(state.relaySettings.rolesDependingOnly(on: "wss://inbox.example") == [.inbox])
    }

    @MainActor
    @Test func removingARelayARoleDependsOnIsRefused() async throws {
        let (state, _) = await relayEditingState()
        let before = state.relaySettings

        await state.removeRelay("wss://profile.example")
        #expect(state.relaySettings != before)

        // `wss://both.example` is now the only profile relay, so it cannot go.
        let afterFirstRemoval = state.relaySettings
        await state.removeRelay("wss://both.example")
        #expect(state.relaySettings == afterFirstRemoval)
        #expect(state.lastError != nil)
    }

    @MainActor
    @Test func removeRelayDropsItFromEveryListItIsIn() async throws {
        let (state, _) = await relayEditingState()

        await state.removeRelay("wss://both.example")

        #expect(state.relaySettings.nip65 == ["wss://profile.example"])
        #expect(state.relaySettings.inbox == ["wss://inbox.example"])
        #expect(!state.relayEndpoints.contains { $0.id == "wss://both.example" })
    }

    @MainActor
    @Test func restoreDefaultRelaysRewritesBothLists() async throws {
        let (state, _) = await relayEditingState()
        #expect(!state.relaySettings.isDefaultRelayConfiguration)

        await state.restoreDefaultRelays()

        #expect(state.relaySettings.nip65 == MarmotClient.seedRelays)
        #expect(state.relaySettings.inbox == MarmotClient.seedRelays)
        #expect(state.relaySettings.isDefaultRelayConfiguration)
    }

    /// One union list, the prototype's overview: a relay in both lists is one row carrying both
    /// roles, not two rows.
    @MainActor
    @Test func relayEndpointsUnionBothListsWithoutDuplicating() async throws {
        let (state, _) = await relayEditingState()

        let endpoints = state.relayEndpoints

        #expect(endpoints.map(\.id) == ["wss://profile.example", "wss://both.example", "wss://inbox.example"])
        #expect(endpoints[0].roles == [.profile])
        #expect(endpoints[1].roles == [.profile, .inbox])
        #expect(endpoints[2].roles == [.inbox])
    }
}
