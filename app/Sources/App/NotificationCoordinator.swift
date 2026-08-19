import AppKit
import MachogsCore
import UserNotifications

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let review = UNNotificationAction(identifier: "REVIEW", title: "Show me", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "MACHOGS_REVIEW", actions: [review], intentIdentifiers: [])
        ])
    }

    func post(_ event: WatchdogEvent, sound: Bool) {
        guard !event.targets.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.categoryIdentifier = "MACHOGS_REVIEW"
        content.userInfo["targets"] = event.targets.map { "\($0.pid):\($0.identity)" }
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
        )
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let values = response.notification.request.content.userInfo["targets"] as? [String] ?? []
        var components = URLComponents()
        components.scheme = "machogs"; components.host = "now"
        components.queryItems = values.map { URLQueryItem(name: "target", value: $0) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
