import Foundation

/// The app's seam onto local notifications. `MacLocalNotificationCenter` is the production
/// implementation; the tests substitute their own so no suite has to touch the real
/// `UNUserNotificationCenter` (which would prompt for permission).
@MainActor
protocol LocalNotificationCenter: AnyObject {
    func authorizationStatus() async -> LocalNotificationAuthorizationStatus
    func requestAuthorization() async throws -> LocalNotificationAuthorizationStatus
    func post(_ notification: LocalNotificationRequest) async throws
    func setResponseHandler(_ handler: @escaping @MainActor ([String: String]) -> Void)
}
