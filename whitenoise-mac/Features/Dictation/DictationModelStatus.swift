import Foundation

/// Where the speech model for the person's language stands.
nonisolated enum DictationModelStatus: Equatable {
    case unknown
    case checking
    case ready
    case notInstalled
    case downloading
    case unsupportedLanguage
    case failed

    /// After a download attempt the inventory is the truth: only a model that is still missing
    /// failed. One macOS is still fetching, or that just became ready, did not.
    static func afterInstallAttempt(_ refreshed: DictationModelStatus) -> DictationModelStatus {
        refreshed == .notInstalled ? .failed : refreshed
    }

    var label: String {
        switch self {
        case .unknown, .checking: L10n.string("Checking…")
        case .ready: L10n.string("Ready")
        case .notInstalled: L10n.string("Not Downloaded")
        case .downloading: L10n.string("Downloading…")
        case .unsupportedLanguage: L10n.string("Not available for your language")
        case .failed: L10n.string("Couldn't download")
        }
    }

    /// Whether Settings offers the download button.
    var offersDownload: Bool {
        self == .notInstalled || self == .failed
    }
}
