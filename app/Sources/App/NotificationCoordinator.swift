import AppKit
import MachogsCore
import UserNotifications

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()
    /// Lets banner buttons act without opening the app. Set by the watchdog.
    @MainActor weak var model: AppModel?

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // No .foreground: both buttons do their job and leave the app closed.
        let close = UNNotificationAction(identifier: "CLOSE", title: "Close", options: [])
        let notNow = UNNotificationAction(identifier: "NOT_NOW", title: "Not now", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "MACHOGS_REVIEW", actions: [close, notNow], intentIdentifiers: []),
            UNNotificationCategory(identifier: "MACHOGS_MEMORY", actions: [notNow], intentIdentifiers: []),
            UNNotificationCategory(identifier: "MACHOGS_RECAP", actions: [], intentIdentifiers: [])
        ])
    }

    /// `targets` are what Close would close. Empty means there is nothing to
    /// close, so the banner only offers "Not now".
    func post(_ event: WatchdogEvent, targets: [ProcessTarget], sound: Bool) {
        Task {
            guard await allowed() else { return }
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            if event.kind == .memory, !targets.isEmpty {
                content.body += " Close shuts \(targets.count) leftover tool\(targets.count == 1 ? "" : "s") from old chats, not the app."
            }
            content.categoryIdentifier = targets.isEmpty ? "MACHOGS_MEMORY" : "MACHOGS_REVIEW"
            content.userInfo = ["targets": targets.map { "\($0.pid):\($0.identity)" }, "group": event.groupID]
            if sound { content.sound = .default }
            do {
                // One banner per problem: a repeat replaces the old one instead of stacking.
                try await center.add(
                    UNNotificationRequest(identifier: event.groupID, content: content, trigger: nil)
                )
            } catch {
                NSLog("machogs: shoulder tap failed to post: %@", error.localizedDescription)
            }
        }
    }

    /// Today's recap replaces yesterday's. A click opens the page it points at.
    func post(_ recap: DailyRecap, sound: Bool) {
        Task {
            guard await allowed() else { return }
            let content = UNMutableNotificationContent()
            content.title = recap.title
            content.body = recap.body
            content.categoryIdentifier = "MACHOGS_RECAP"
            content.userInfo = ["page": recap.page]
            if sound { content.sound = .default }
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "daily-recap", content: content, trigger: nil))
        }
    }

    private func allowed() async -> Bool {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            NSLog("machogs: notification dropped — not allowed (status %d)", settings.authorizationStatus.rawValue)
            return false
        }
        return true
    }

    /// Removes banners whose processes are all gone, and memory warnings with
    /// nothing to close after half an hour. A worse reading posts a fresh one.
    func clearResolved(live: Set<ProcessTarget>) {
        Task {
            let center = UNUserNotificationCenter.current()
            let resolved = await center.deliveredNotifications().filter { note in
                let content = note.request.content
                let targets = Self.targets(content.userInfo)
                if content.categoryIdentifier == "MACHOGS_RECAP" { return false }
                return targets.isEmpty ? note.date.timeIntervalSinceNow < -30 * 60 : live.isDisjoint(with: targets)
            }.map(\.request.identifier)
            if !resolved.isEmpty { center.removeDeliveredNotifications(withIdentifiers: resolved) }
        }
    }

    private static func targets(_ info: [AnyHashable: Any]) -> [ProcessTarget] {
        (info["targets"] as? [String] ?? []).compactMap { value in
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
            return ProcessTarget(pid: pid, identity: parts[1])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let targets = Self.targets(info)
        switch response.actionIdentifier {
        case "CLOSE":
            // The user's own click on our banner, like the island's Close.
            // The engine still rechecks every target before closing it.
            await model?.closeTargetsNow(targets)
        case "NOT_NOW":
            if let group = info["group"] as? String { await model?.snoozeGroup(group) }
        case UNNotificationDismissActionIdentifier:
            break
        default:
            var components = URLComponents()
            components.scheme = MachogsBuild.urlScheme
            components.host = info["page"] as? String ?? "now"
            components.queryItems = targets.map { URLQueryItem(name: "target", value: "\($0.pid):\($0.identity)") }
            if let url = components.url { await MainActor.run { _ = NSWorkspace.shared.open(url) } }
        }
    }
}
