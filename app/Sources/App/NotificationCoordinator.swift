import AppKit
import MachogsCore
import UserNotifications

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let close = UNNotificationAction(identifier: "CLOSE", title: "Close it 💥", options: [])
        let review = UNNotificationAction(identifier: "REVIEW", title: "Show me", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "MACHOGS_REVIEW", actions: [close, review], intentIdentifiers: [])
        ])
    }

    func post(_ event: WatchdogEvent, sound: Bool) {
        guard !event.targets.isEmpty else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
                NSLog("machogs: shoulder tap dropped — notifications not allowed (status %d)",
                      settings.authorizationStatus.rawValue)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.categoryIdentifier = "MACHOGS_REVIEW"
            content.userInfo["targets"] = event.targets.map { "\($0.pid):\($0.identity)" }
            if sound { content.sound = .default }
            do {
                try await center.add(
                    UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
                )
            } catch {
                NSLog("machogs: shoulder tap failed to post: %@", error.localizedDescription)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let values = response.notification.request.content.userInfo["targets"] as? [String] ?? []
        var components = URLComponents()
        components.scheme = "machogs"
        components.host = response.actionIdentifier == "CLOSE" ? "close" : "now"
        components.queryItems = values.map { URLQueryItem(name: "target", value: $0) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
