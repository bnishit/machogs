import AppKit
import Combine
import Foundation
import MachogsCore
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

    @Published private(set) var shareBasicUsage: Bool
    @Published private(set) var analyticsChoiceMade: Bool
    let analyticsAvailable: Bool
    private let analytics: UsageAnalytics
    private let analyticsDefaults: UserDefaults

    static let analyticsExplanation = "Share app version, a random installation ID, install type, and first and weekly use. Never scan results, app or process names, or file paths."
    static let privacyURL = URL(string: "https://bnishit.github.io/machogs/privacy.html")!
    var needsAnalyticsChoice: Bool { onboardingComplete && analyticsAvailable && !analyticsChoiceMade }

    var notificationsDenied: Bool { shoulderTaps && notificationStatus == .denied }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let testingAnalytics = ProcessInfo.processInfo.arguments.contains("--analytics-test")
        let analyticsDefaults = testingAnalytics
            ? UserDefaults(suiteName: "com.bnishit.machogs.analytics-test")! : defaults
        self.analyticsDefaults = analyticsDefaults
        let existingInstall = defaults.bool(forKey: "onboardingComplete")
        if analyticsDefaults.string(forKey: "analyticsInstallKind") == nil {
            analyticsDefaults.set(existingInstall ? "existing_install" : "new_install", forKey: "analyticsInstallKind")
        }
        let kind: UsageAnalytics.InstallationKind = analyticsDefaults.string(forKey: "analyticsInstallKind") == "new_install" ? .newInstall : .existingInstall
        let analytics = UsageAnalytics(configuration: Self.analyticsConfiguration(kind: kind, testing: testingAnalytics), defaults: analyticsDefaults)
        self.analytics = analytics
        analyticsAvailable = analytics.isAvailable
        shareBasicUsage = analytics.isEnabled
        analyticsChoiceMade = analyticsDefaults.bool(forKey: "analyticsChoiceMade")
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        shoulderTaps = defaults.object(forKey: "watchdogOn") as? Bool ?? true
        soundOn = defaults.object(forKey: "soundOn") as? Bool ?? true
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    private static func analyticsConfiguration(kind: UsageAnalytics.InstallationKind, testing: Bool) -> UsageAnalytics.Configuration? {
        let bundle = Bundle.main
        guard let token = bundle.object(forInfoDictionaryKey: "MachogsAnalyticsToken") as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let host = bundle.object(forInfoDictionaryKey: "MachogsAnalyticsHost") as? String,
              let url = URL(string: host), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        #if DEBUG
        let production = false
        #else
        let production = bundle.bundleIdentifier == "com.bnishit.machogs" && bundle.bundlePath.hasSuffix(".app")
        #endif
        return UsageAnalytics.Configuration(
            captureURL: url.appendingPathComponent("i/v0/e/"), projectToken: token,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            environment: testing ? .test : .production, installationKind: kind, allowsCollection: production
        )
    }

    func setAnalyticsEnabled(_ enabled: Bool) {
        analyticsChoiceMade = true
        analyticsDefaults.set(true, forKey: "analyticsChoiceMade")
        analytics.setEnabled(enabled)
        shareBasicUsage = analytics.isEnabled
        if shareBasicUsage { Task { await recordForegroundUse() } }
    }

    func recordForegroundUse() async {
        await analytics.recordActivity()
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
