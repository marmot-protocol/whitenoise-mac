//
//  AppFlavorTests.swift
//  whitenoise-macTests
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

struct AppFlavorTests {
    @Test func testHostIsTheDevelopmentFlavor() {
        // The test host is the main scheme's Debug app. As production it would share a real
        // install's preferences, Application Support directory and keychain items.
        #expect(AppFlavor.current == .development)
        #expect(Bundle.main.infoDictionary?[AppFlavor.infoPlistKey] as? String == "development")
        #expect(Bundle.main.bundleIdentifier == "dev.ipf.whitenoise.mac.dev")
    }

    @Test func missingOrUnknownFlavorReadsAsProduction() {
        #expect(AppFlavor(info: nil) == .production)
        #expect(AppFlavor(info: [:]) == .production)
        #expect(AppFlavor(info: [AppFlavor.infoPlistKey: ""]) == .production)
        #expect(AppFlavor(info: [AppFlavor.infoPlistKey: "qa"]) == .production)
        #expect(AppFlavor(info: [AppFlavor.infoPlistKey: 1]) == .production)
        #expect(AppFlavor(info: [AppFlavor.infoPlistKey: " Staging\n"]) == .staging)
    }

    @Test func productionKeepsTheNamesExistingInstallsUse() {
        // Renaming any of these strands an existing install's accounts, keys or media cache.
        let flavor = AppFlavor.production
        #expect(flavor.applicationSupportDirectoryName == "White Noise")
        #expect(flavor.marmotKeychainService == "com.marmot.whitenoise")
        #expect(flavor.mediaCacheKeychainService == "dev.ipf.whitenoise.media-cache")
        #expect(flavor.urlScheme == MarmotProfileLink.scheme)
        #expect(flavor.marmotDeployment() == marmotDeploymentWhiteNoise())
        #expect(flavor.marmotKeychainService == marmotDeploymentWhiteNoise().keychainService)
    }

    @Test func noTwoFlavorsShareAStorageRootKeychainServiceOrScheme() {
        let flavors = AppFlavor.allCases
        #expect(Set(flavors.map(\.applicationSupportDirectoryName)).count == flavors.count)
        #expect(Set(flavors.map(\.marmotKeychainService)).count == flavors.count)
        #expect(Set(flavors.map(\.mediaCacheKeychainService)).count == flavors.count)
        #expect(Set(flavors.map(\.urlScheme)).count == flavors.count)
    }

    @Test(arguments: [AppFlavor.staging, .development])
    func nonProductionDeploymentOnlyMovesTheKeychainService(flavor: AppFlavor) {
        var expected = marmotDeploymentWhiteNoise()
        expected.keychainService = flavor.marmotKeychainService
        #expect(flavor.marmotDeployment() == expected)
    }

    @Test func stagingAcceptsProfileLinksUnderItsOwnScheme() throws {
        let npub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
        let staging = try #require(URL(string: "marmot-staging://profile/\(npub)?from=qr"))
        let production = try #require(URL(string: "marmot://profile/\(npub)"))

        #expect(MarmotProfileLink.profileReference(from: staging, flavor: .staging) == npub)
        #expect(MarmotProfileLink.profileReference(from: production, flavor: .staging) == npub)
        #expect(MarmotProfileLink.profileReference(from: production, flavor: .production) == npub)
        #expect(MarmotProfileLink.profileReference(from: staging, flavor: .production) == nil)
    }
}
