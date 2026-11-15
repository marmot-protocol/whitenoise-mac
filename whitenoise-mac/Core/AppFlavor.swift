//
//  AppFlavor.swift
//  whitenoise-mac
//
//  Production, staging and development (the main scheme's Debug build) install side by side. The
//  bundle id alone separates their sandbox containers, but an unsigned build (`just run`) runs
//  unsandboxed and the macOS login keychain is shared by service name, so every on-disk root and
//  keychain service the app owns is named per flavor here. Production's names are the ones existing
//  installs already use and must never change.
//

import Foundation
import MarmotKit

nonisolated enum AppFlavor: String, Sendable, CaseIterable {
    case production
    case staging
    /// The main scheme's Debug build, which is also the unit-test host. It never reads or writes a
    /// real install's data, so running Debug on a Mac that has White Noise installed is safe.
    case development

    /// Written by `WN_FLAVOR` in `Config/AppBuild.xcconfig`, `Config/Staging.xcconfig` and
    /// `Config/Development.xcconfig`.
    static let infoPlistKey = "WhiteNoiseBuildFlavor"

    static let current = AppFlavor(info: Bundle.main.infoDictionary)

    /// A missing or unknown value reads as production: that is every build made before flavors
    /// existed.
    init(info: [String: Any]?) {
        let raw = (info?[Self.infoPlistKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = raw.flatMap(AppFlavor.init(rawValue:)) ?? .production
    }

    /// The directory under Application Support that holds the Marmot root and the host's own stores.
    var applicationSupportDirectoryName: String {
        switch self {
        case .production: "White Noise"
        case .staging: "White Noise Staging"
        case .development: "White Noise Dev"
        }
    }

    /// The URL scheme this build registers (`WN_URL_SCHEME`). Staging and development take their own
    /// so a `marmot://` link always opens production; links the app emits stay `marmot://`.
    var urlScheme: String {
        switch self {
        case .production: "marmot"
        case .staging: "marmot-staging"
        case .development: "marmot-dev"
        }
    }

    /// Keychain service MDK keeps account secrets under, and the one "delete all data" purges.
    var marmotKeychainService: String {
        switch self {
        case .production: "com.marmot.whitenoise"
        case .staging: "com.marmot.whitenoise.staging"
        case .development: "com.marmot.whitenoise.dev"
        }
    }

    /// Keychain service of the host media cache's symmetric key.
    var mediaCacheKeychainService: String {
        switch self {
        case .production: "dev.ipf.whitenoise.media-cache"
        case .staging: "dev.ipf.whitenoise.media-cache.staging"
        case .development: "dev.ipf.whitenoise.media-cache.dev"
        }
    }

    /// White Noise's deployment. Production passes it through untouched; staging and development
    /// keep every service and only move the account secrets to their own keychain service, so their
    /// "delete all data" can never reach a production key.
    func marmotDeployment() -> MarmotDeploymentFfi {
        var deployment = marmotDeploymentWhiteNoise()
        guard self != .production else { return deployment }
        deployment.keychainService = marmotKeychainService
        return deployment
    }
}
