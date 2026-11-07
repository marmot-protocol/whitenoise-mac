import Foundation
import Observation
import SwiftUI

/// The Profile Keys page's private-key row: what is on screen, what is being asked for, and the
/// consent step in front of every read of the raw key.
///
/// Ported from the iOS client's `IdentityViewModel` (whitenoise-ios #1264). Both actions that put
/// the raw `nsec` somewhere — on screen, or on the pasteboard — wait for an explicit confirmation,
/// because on this platform each one goes through the core's audited `revealNsec`, and a stray
/// click on an eye should not cost the reader an audit entry or a key on the clipboard.
///
/// Account-scoped through `SettingsViewModel`, so switching identities destroys it. Within one
/// account the revealed key is per-visit: the page calls `reset()` on its way out.
@MainActor
@Observable
final class ProfileKeysViewModel {
    /// The two in-place reads of the raw key. The file export has its own confirmation beside its
    /// save panel, so it is not one of these.
    enum PrivateKeyAction: Equatable {
        case reveal
        case copy

        var confirmationTitleKey: String {
            switch self {
            case .reveal: "Show Private Key?"
            case .copy: "Copy Private Key?"
            }
        }

        var confirmButtonKey: String {
            switch self {
            case .reveal: "Show Key"
            case .copy: "Copy Key"
            }
        }

        static let confirmationMessageKey =
            "Keep this key safe and don't share it with anyone. Anyone with it can use your profile."
    }

    /// The action waiting on the reader's answer. Nothing has been read from the core yet.
    private(set) var pendingConfirmation: PrivateKeyAction?
    /// The raw key while the reader has it revealed; `nil` the rest of the time.
    private(set) var revealedNsec: String?
    /// The confirmed action whose `revealNsec` call has not come back yet.
    private(set) var actionInFlight: PrivateKeyAction?
    /// Why the last confirmed action failed.
    private(set) var error: String?
    let copyConfirmation: CopyConfirmation

    /// The confirmed action's work. Kept so `reset()` can cancel it — a key read for one visit of
    /// the page must not land on screen, or on the pasteboard, after the reader has left it.
    @ObservationIgnored private(set) var actionTask: Task<Void, Never>?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private let copyConcealed: @MainActor (String) -> Void

    init(
        accountRef: String,
        runtime: (any MarmotRuntime)?,
        copyConfirmation: CopyConfirmation? = nil,
        copyConcealed: @escaping @MainActor (String) -> Void = { text in
            WorkspaceState.copyToGeneralPasteboard(text, concealed: true)
        }
    ) {
        self.accountRef = accountRef
        self.runtime = runtime
        self.copyConfirmation = copyConfirmation ?? CopyConfirmation()
        self.copyConcealed = copyConcealed
    }

    var isRevealed: Bool { revealedNsec != nil }

    /// Asks for consent before an action, without touching the key. Hiding a revealed key needs
    /// no consent: it only takes the secret off screen.
    func request(_ action: PrivateKeyAction) {
        guard actionInFlight == nil else { return }
        if action == .reveal, isRevealed {
            hidePrivateKey()
            return
        }
        error = nil
        pendingConfirmation = action
    }

    /// The reader declined, or the alert closed without an answer.
    func cancelRequest() {
        pendingConfirmation = nil
    }

    /// Runs the action the reader just agreed to. Takes the action explicitly rather than reading
    /// `pendingConfirmation`, because an alert may clear its binding before running its button.
    func confirm(_ action: PrivateKeyAction) {
        pendingConfirmation = nil
        guard actionInFlight == nil, let runtime else { return }
        actionInFlight = action
        error = nil
        actionTask = Task { [accountRef] in
            await self.perform(action, runtime: runtime, accountRef: accountRef)
        }
    }

    func hidePrivateKey() {
        revealedNsec = nil
    }

    /// Back to the concealed page: called when the page goes away. Cancels a read still in
    /// flight so its result is dropped rather than shown to whoever opens Settings next.
    func reset() {
        actionTask?.cancel()
        actionTask = nil
        pendingConfirmation = nil
        revealedNsec = nil
        actionInFlight = nil
        error = nil
    }

    private func perform(
        _ action: PrivateKeyAction,
        runtime: any MarmotRuntime,
        accountRef: String
    ) async {
        let nsec: String
        do {
            nsec = try await FFIExecutor.run { try runtime.revealNsec(accountRef: accountRef) }
        } catch {
            guard !Task.isCancelled else { return }
            actionInFlight = nil
            self.error = error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }
        actionInFlight = nil
        switch action {
        case .reveal:
            revealedNsec = nsec
        case .copy:
            copyConcealed(nsec)
            copyConfirmation.confirm()
            // The checkmark is invisible to VoiceOver, so announce the result it conveys.
            AccessibilityNotification.Announcement(L10n.string("Copied")).post()
        }
    }

    static func preview(revealedNsec: String? = nil) -> ProfileKeysViewModel {
        let model = ProfileKeysViewModel(accountRef: "preview", runtime: nil)
        model.revealedNsec = revealedNsec
        return model
    }
}
