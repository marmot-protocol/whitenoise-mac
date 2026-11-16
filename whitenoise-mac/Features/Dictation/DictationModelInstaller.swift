// coverage:ignore-file
// Asks macOS's AssetInventory about and for the speech model, which a unit test cannot reach.
// The status rule it relies on, `DictationModelStatus.afterInstallAttempt`, is tested.

import Foundation
import OSLog
import Observation
import Speech

/// Downloads the speech model for a language. macOS owns the download and shares the model
/// between apps; it comes from Apple, not from White Noise.
@available(macOS 26.0, *)
@MainActor
@Observable
final class DictationModelInstaller {
    static let shared = DictationModelInstaller()

    private(set) var status: DictationModelStatus = .unknown
    @ObservationIgnored private var currentInstall: Task<DictationModelStatus, Never>?

    /// How often a download macOS is already running is re-read.
    private static let downloadPollInterval: Duration = .seconds(2)
    /// How many times an install of ours re-reads a download macOS is still finishing. The install
    /// runs in a task nobody cancels, so it must stop by itself; Settings' own `.task` keeps
    /// polling for as long as it is on screen.
    private static let postInstallPollLimit = 90

    /// Reports whether the model for the best-matching language is installed. While macOS is
    /// downloading it, re-reads up to `maxPolls` times, stopping early when the download ends or
    /// the calling task is cancelled.
    func refresh(localeIdentifiers: [String], maxPolls: Int = .max) async {
        guard currentInstall == nil else { return }
        status = .checking
        guard let recognizer = await DictationRecognizer.resolve(localeIdentifiers) else {
            status = .unsupportedLanguage
            return
        }
        await readStatus(of: recognizer)
        // An install of ours reports its own outcome, so the loop stops once one starts.
        var polls = 0
        while status == .downloading, currentInstall == nil, polls < maxPolls {
            polls += 1
            do {
                try await Task.sleep(for: Self.downloadPollInterval)
            } catch {
                return
            }
            await readStatus(of: recognizer)
        }
    }

    private func readStatus(of recognizer: DictationRecognizer) async {
        guard currentInstall == nil else { return }
        let assetStatus = await AssetInventory.status(forModules: [recognizer.module])
        guard currentInstall == nil else { return }
        status = Self.status(for: assetStatus)
    }

    /// Asks macOS for the model, joining a request already made from here, and resolves to the
    /// status it settles on.
    @discardableResult
    func install(localeIdentifiers: [String]) -> Task<DictationModelStatus, Never> {
        if let currentInstall { return currentInstall }
        status = .downloading
        let task = Task { @MainActor [weak self] () -> DictationModelStatus in
            await Self.download(localeIdentifiers: localeIdentifiers)
            guard let self else { return .unknown }
            self.currentInstall = nil
            await self.refresh(localeIdentifiers: localeIdentifiers, maxPolls: Self.postInstallPollLimit)
            self.status = DictationModelStatus.afterInstallAttempt(self.status)
            return self.status
        }
        currentInstall = task
        return task
    }

    private static func download(localeIdentifiers: [String]) async {
        guard let recognizer = await DictationRecognizer.resolve(localeIdentifiers) else { return }
        do {
            if let locale = recognizer.locale,
                !(await AssetInventory.reservedLocales).contains(locale)
            {
                // Keeps the model on device; failing only means macOS may reclaim it later.
                _ = try? await AssetInventory.reserve(locale: locale)
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [recognizer.module]) {
                try await request.downloadAndInstall()
            }
        } catch {
            DictationDiagnostics.log.error(
                "Speech model download failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private static func status(for assetStatus: AssetInventory.Status) -> DictationModelStatus {
        switch assetStatus {
        case .installed: .ready
        case .downloading: .downloading
        case .supported: .notInstalled
        case .unsupported: .unsupportedLanguage
        @unknown default: .unsupportedLanguage
        }
    }
}
