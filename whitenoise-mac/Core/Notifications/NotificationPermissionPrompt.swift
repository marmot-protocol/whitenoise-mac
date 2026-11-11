import Foundation

/// Asks for notification permission once an account is signed in, because macOS draws the app-icon
/// badge (`DockBadgeController`, in the Dock and the ⌘-Tab switcher) only for an app the user has
/// allowed to badge. The request used to run only from the Notifications settings toggle, so an
/// install that never visited it was never registered with Notification Center and its badge never
/// appeared, however many messages were waiting.
///
/// macOS shows the prompt at most once. After any answer `requestAuthorization` returns that answer
/// without asking, and a refusal can only be changed in System Settings, so this asks only while the
/// status is still `.notDetermined`. Granting permission does not turn on message alerts: those stay
/// behind the account's own notifications setting.
@MainActor
enum NotificationPermissionPrompt {
    /// The status after asking, or `nil` when there was nothing to ask or the request failed.
    static func requestIfUndetermined(
        using center: any LocalNotificationCenter
    ) async -> LocalNotificationAuthorizationStatus? {
        guard await center.authorizationStatus() == .notDetermined else { return nil }
        return try? await center.requestAuthorization()
    }
}
