//
//  AppFlavorTests.swift
//  whitenoise-macTests
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

struct AppFlavorTests {
    @Test func testHostIsTheProductionFlavor() {
        // The PR test plan runs against the production Debug app; a staging host would move
        // every storage root and keychain service the other tests rely on.
        #expect(AppFlavor.current == .production)
        #expect(Bundle.main.infoDictionary?[AppFlavor.infoPlistKey] as? String == "production")
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

    @Test func stagingSharesNoStorageRootOrKeychainServiceWithProduction() {
        let production = AppFlavor.production
        let staging = AppFlavor.staging
        #expect(staging.applicationSupportDirectoryName != production.applicationSupportDirectoryName)
        #expect(staging.marmotKeychainService != production.marmotKeychainService)
        #expect(staging.mediaCacheKeychainService != production.mediaCacheKeychainService)
        #expect(staging.urlScheme != production.urlScheme)
    }

    @Test func stagingDeploymentOnlyMovesTheKeychainService() {
        var expected = marmotDeploymentWhiteNoise()
        expected.keychainService = "com.marmot.whitenoise.staging"
        #expect(AppFlavor.staging.marmotDeployment() == expected)
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
