import Foundation

/// Where a click on one of the app's banners lands, whatever the shell is showing when it arrives.
///
/// `WorkspaceState.handleNotificationResponse(_:)` opens the banner's chat on the account it was
/// posted for, but it only knows the messenger: it switches identity and selects the chat, and
/// leaves `phase` alone. That is right once the chats are on screen and wrong everywhere else:
///
/// - **Launch.** A click on a banner from a quit app launches it, and the response arrives while
///   `bootstrap()` is still loading accounts. With none loaded the click matched nothing and was
///   dropped with "no longer available", and the app opened on whichever chat it restored.
/// - **Onboarding.** With Add Profile open, or a new identity's sign-up or setup on screen, the
///   click switched account and selected the chat *behind* the onboarding pane, so the user stayed
///   on Sign Up instead of seeing the invite they clicked. That is the usual way an invite is
///   clicked: a freshly signed-up identity is the one people invite first.
///
/// So a click that cannot be answered yet is held here and replayed once `phase` reaches `.ready`
/// (`phaseDidChange()`), and a click during onboarding leaves it the way the user would: Cancel on
/// the Welcome panes, Open Chats on a finished setup. A setup still running is never skipped — the
/// click waits for it, and lands when the user opens the chats. Abandoning the setup (Cancel or ✕)
/// changes `phase` at once, so the click is replayed or dropped then; the only click that can
/// outlive `setupHoldLifetime` is one whose setup is still on screen after it, and that is
/// dropped so a chat list opened long after the click does not jump to it.
///
/// Lives in the session layer, not on `WorkspaceState` (which is frozen): it needs the active
/// account's onboarding checkpoint, which only the account scope holds.
@MainActor
final class NotificationResponseRouter {
    private let workspace: WorkspaceState
    /// The active account's onboarding checkpoint, read at the moment a click arrives. A closure
    /// because the shell replaces the account scope on every switch.
    private let onboarding: @MainActor () -> OnboardingCoordinator?
    /// The latest click that could not be answered yet. One, not a queue: a later click supersedes
    /// an earlier one, as it would on screen.
    private(set) var pendingResponse: [String: String]?
    /// When a click held for a setup stops being worth replaying. Nil for a click held through
    /// launch, which the user is still waiting on however long bootstrap takes.
    private var pendingResponseExpiry: Date?
    private let now: @MainActor () -> Date

    /// How long a click waits for an unfinished setup before it is dropped. Well past a relay or
    /// KeyPackage check on a bad network, so a setup the user is still waiting on keeps its click.
    static let setupHoldLifetime: TimeInterval = 10 * 60

    init(
        workspace: WorkspaceState,
        now: @escaping @MainActor () -> Date = { Date() },
        onboarding: @escaping @MainActor () -> OnboardingCoordinator?
    ) {
        self.workspace = workspace
        self.now = now
        self.onboarding = onboarding
    }

    func route(_ userInfo: [String: String]) {
        route(userInfo, heldUntil: nil)
    }

    /// `heldUntil` is the expiry a replayed click already had, so holding it again for a setup
    /// keeps its original deadline instead of restarting the clock on every phase change.
    private func route(_ userInfo: [String: String], heldUntil expiry: Date?) {
        guard userInfo["groupIdHex"] != nil else { return }
        switch workspace.phase {
        case .ready:
            dropPendingResponse()
            workspace.handleNotificationResponse(userInfo)
        case .bootstrapping:
            pendingResponse = userInfo
            pendingResponseExpiry = nil
        case .onboarding:
            routeDuringOnboarding(userInfo, heldUntil: expiry)
        case .failed:
            // Nothing behind the failure pane can show a chat.
            dropPendingResponse()
        }
    }

    /// Replays a held click once the chats are on screen. The shell calls this on every `phase`
    /// change; a bootstrap that ends in onboarding (nothing signed in) routes the click again,
    /// which drops it there.
    func phaseDidChange() {
        guard workspace.phase != .bootstrapping, let pendingResponse else { return }
        let expiry = pendingResponseExpiry
        dropPendingResponse()
        if let expiry, now() >= expiry { return }
        route(pendingResponse, heldUntil: expiry)
    }

    private func dropPendingResponse() {
        pendingResponse = nil
        pendingResponseExpiry = nil
    }

    private func routeDuringOnboarding(_ userInfo: [String: String], heldUntil expiry: Date?) {
        // Only a signed-in identity has chats to show. A banner for one that is gone, or a click
        // with nothing signed in, leaves the user where they are.
        guard let account = workspace.notificationAccount(from: userInfo), !account.signedOut else {
            dropPendingResponse()
            return
        }
        // A sign-in or sign-up in flight is about to pick the active identity itself; switching
        // under it would land on one account and then be moved to the other.
        guard !workspace.isAuthenticating else {
            dropPendingResponse()
            return
        }

        if let setup = onboarding(), setup.isWalkingThroughSetup {
            // The active identity's setup is on screen. It is not cancelled or skipped for a
            // banner: a finished one opens its chats the way Open Chats does, and the shell's
            // entry check takes the phase to `.ready`; an unfinished one keeps the click until it
            // is. Either way the chat opens from `phaseDidChange()`.
            pendingResponse = userInfo
            pendingResponseExpiry = expiry ?? now().addingTimeInterval(Self.setupHoldLifetime)
            if setup.isDurablyReady {
                setup.openChats()
            }
            return
        }

        // Welcome, Sign In or Sign Up over identities already signed in — Add Profile, which is the
        // only way into those panes with one. Clicking the banner is choosing to leave it, which
        // is what Cancel does.
        guard workspace.canLeaveAccountOnboarding else {
            dropPendingResponse()
            return
        }
        dropPendingResponse()
        workspace.leaveAccountOnboarding(returningToSettings: false)
        guard workspace.phase == .ready else { return }
        workspace.handleNotificationResponse(userInfo)
    }
}
