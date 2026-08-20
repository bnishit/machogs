import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppSettings: ObservableObject {
    @Published var onboardingComplete: Bool
    @Published var shoulderTaps: Bool
    @Published var soundOn: Bool
    @Published var startAtLogin: Bool
    @Published var setupError: String?
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined

    var notificationsDenied: Bool { shoulderTaps && notificationStatus == .denied }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        shoulderTaps = defaults.object(forKey: "watchdogOn") as? Bool ?? true
        soundOn = defaults.object(forKey: "soundOn") as? Bool ?? true
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    func completeOnboarding(shoulderTaps: Bool, startAtLogin: Bool) async -> Bool {
        self.shoulderTaps = shoulderTaps
        defaults.set(shoulderTaps, forKey: "watchdogOn")
        if shoulderTaps { await requestNotifications() }
        let loginConfigured = setStartAtLogin(startAtLogin)
        defaults.set(true, forKey: "onboardingComplete")
        onboardingComplete = true
        return loginConfigured
    }

    func setShoulderTaps(_ enabled: Bool) async {
        shoulderTaps = enabled
        defaults.set(enabled, forKey: "watchdogOn")
        if enabled { await requestNotifications() }
    }

    @discardableResult
    func setStartAtLogin(_ enabled: Bool) -> Bool {
        setupError = nil
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            startAtLogin = SMAppService.mainApp.status == .enabled
            return startAtLogin == enabled
        } catch {
            startAtLogin = SMAppService.mainApp.status == .enabled
            setupError = "Machogs could not change Start at Login. The app still works whenever you open it."
            return false
        }
    }

    func setSound(_ enabled: Bool) {
        soundOn = enabled
        defaults.set(enabled, forKey: "soundOn")
    }

    private func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        await refreshNotificationStatus()
    }

    /// Called at launch. Covers users whose defaults predate onboarding —
    /// they enabled shoulder taps but macOS was never actually asked.
    func requestNotificationsIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        if shoulderTaps, await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshNotificationStatus()
    }

    func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.bnishit.machogs"
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(id)")!
        NSWorkspace.shared.open(url)
    }
}

struct BuildIdentity {
    let label: String

    static func current() -> BuildIdentity {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            return BuildIdentity(label: "Development build — not ready to share")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", Bundle.main.bundlePath]
        let pipe = Pipe(); process.standardError = pipe; process.standardOutput = Pipe()
        guard (try? process.run()) != nil else {
            return BuildIdentity(label: "Unsigned development build — not ready to share")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.contains("Authority=Developer ID Application") {
            return BuildIdentity(label: "Developer ID signed")
        }
        return BuildIdentity(label: "Development build — not ready to share")
    }
}
