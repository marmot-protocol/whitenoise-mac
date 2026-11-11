//
//  AppFlavor.swift
//  whitenoise-mac
//
//  Production and staging builds install side by side. The bundle id alone separates their sandbox
//  containers, but an unsigned build (`just run`) runs unsandboxed and the macOS login keychain is
//  shared by service name, so every on-disk root and keychain service the app owns is named per
//  flavor here. Production's names are the ones existing installs already use and must never change.
//

import Foundation
import MarmotKit

nonisolated enum AppFlavor: String, Sendable, CaseIterable {
    case production
    case staging

    /// Written by `WN_FLAVOR` in `Config/AppBuild.xcconfig` / `Config/Staging.xcconfig`.
    static let infoPlistKey = "WhiteNoiseBuildFlavor"

    static let current = AppFlavor(info: Bundle.main.infoDictionary)

    /// A missing or unknown value reads as production: that is every build made before flavors
    /// existed, and the test host.
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
        }
    }

    /// The URL scheme this build registers (`WN_URL_SCHEME`). Staging takes its own so a
    /// `marmot://` link always opens production; links the app emits stay `marmot://`.
    var urlScheme: String {
        switch self {
        case .production: "marmot"
        case .staging: "marmot-staging"
        }
    }

    /// Keychain service MDK keeps account secrets under, and the one "delete all data" purges.
    var marmotKeychainService: String {
        switch self {
        case .production: "com.marmot.whitenoise"
        case .staging: "com.marmot.whitenoise.staging"
        }
    }

    /// Keychain service of the host media cache's symmetric key.
    var mediaCacheKeychainService: String {
        switch self {
        case .production: "dev.ipf.whitenoise.media-cache"
        case .staging: "dev.ipf.whitenoise.media-cache.staging"
        }
    }

    /// White Noise's deployment. Production passes it through untouched; staging keeps every
    /// service and only moves the account secrets to its own keychain service, so a staging
    /// "delete all data" can never reach a production key.
    func marmotDeployment() -> MarmotDeploymentFfi {
        var deployment = marmotDeploymentWhiteNoise()
        guard self != .production else { return deployment }
        deployment.keychainService = marmotKeychainService
        return deployment
    }
}
