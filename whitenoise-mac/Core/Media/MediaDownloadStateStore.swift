import Foundation
import Observation

@MainActor
@Observable
final class MediaDownloadStateStore {
    private(set) var state: MediaDownloadState = .idle

    var shouldStartAutomaticDownload: Bool {
        if case .idle = state {
            return true
        }
        return false
    }

    func update(_ newState: MediaDownloadState) {
        guard state != newState else { return }
        state = newState
    }
}
