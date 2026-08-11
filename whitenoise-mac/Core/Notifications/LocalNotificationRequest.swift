import Foundation

/// A local alert the app asks the system to post. Deliberately a plain value type with no
/// `UserNotifications` types in it, so callers (and the test fake) never touch `UNNotificationRequest`.
struct LocalNotificationRequest: Equatable {
    let identifier: String
    let title: String
    let body: String
    let threadIdentifier: String
    let userInfo: [String: String]
}
