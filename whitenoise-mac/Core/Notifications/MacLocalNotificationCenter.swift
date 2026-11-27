import Foundation
import UserNotifications

@MainActor
final class MacLocalNotificationCenter: NSObject, LocalNotificationCenter, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private var responseHandler: (@MainActor ([String: String]) -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> LocalNotificationAuthorizationStatus {
        await currentSettings().authorizationStatus.localNotificationStatus
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorizationStatus {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
        return await authorizationStatus()
    }

    func post(_ notification: LocalNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.threadIdentifier
        content.userInfo = notification.userInfo

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func removeDeliveredNotifications(
        forAccountIdHex accountIdHex: String,
        includingIdentifiers: [String]
    ) async {
        let delivered = await center.deliveredNotifications()
        let identifiers = Self.deliveredNotificationIdentifiers(
            matchingAccountIdHex: accountIdHex,
            in: delivered.map { ($0.request.identifier, $0.request.content.userInfo) },
            includingIdentifiers: includingIdentifiers
        )
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    nonisolated static func deliveredNotificationIdentifiers(
        matchingAccountIdHex accountIdHex: String,
        in delivered: [(identifier: String, userInfo: [AnyHashable: Any])],
        includingIdentifiers: [String] = []
    ) -> [String] {
        let target = accountIdHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var matched: [String] = []
        if !target.isEmpty {
            matched = delivered.compactMap { entry in
                guard let deliveredAccountId = entry.userInfo["accountIdHex"] as? String,
                    deliveredAccountId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
                else { return nil }
                return entry.identifier
            }
        }
        var seen = Set(matched)
        for identifier in includingIdentifiers where !identifier.isEmpty && seen.insert(identifier).inserted {
            matched.append(identifier)
        }
        return matched
    }

    func setResponseHandler(_ handler: @escaping @MainActor ([String: String]) -> Void) {
        responseHandler = handler
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo.reduce(into: [String: String]()) {
            result, element in
            guard let key = element.key as? String else { return }
            if let value = element.value as? String {
                result[key] = value
            }
        }

        Task { @MainActor [weak self] in
            self?.responseHandler?(userInfo)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    private func currentSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }
}
