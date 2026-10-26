import AppKit
import Combine
import MachogsCore
import SwiftUI

enum MachogsBuild {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Machogs"
    }

    static var urlScheme: String {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "machogs"
    }
}

@main
struct MachogsApp: App {
    @StateObject private var model: AppModel
    @StateObject private var settings: AppSettings
    @StateObject private var router = AppRouter()
    private let successSound: SuccessSoundCoordinator
    private let watchdogNotifier: WatchdogNotifier

    init() {
        let service: any MachogsServing = MachogsClient()
        let settings = AppSettings()
        let model = AppModel(service: service, analytics: settings.analytics)
        // A design launch opens the real overview without onboarding prompts.
        // These are in-memory choices in the isolated design app only.
        if Bundle.main.bundleIdentifier == "com.bnishit.machogs.design",
           ProcessInfo.processInfo.arguments.contains("--design-preview") {
            settings.onboardingComplete = true
            settings.shoulderTaps = false
            settings.soundOn = false
            if ProcessInfo.processInfo.arguments.contains("--design-light") {
                NSApplication.shared.appearance = NSAppearance(named: .aqua)
            } else if ProcessInfo.processInfo.arguments.contains("--design-dark") {
                NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            }
        }
        _model = StateObject(wrappedValue: model)
        _settings = StateObject(wrappedValue: settings)
        successSound = SuccessSoundCoordinator(model: model, settings: settings)
        watchdogNotifier = WatchdogNotifier(model: model, settings: settings)
    }

    var body: some Scene {
        Window(MachogsBuild.displayName, id: "main") {
            Group {
                if settings.onboardingComplete {
                    MainWindow(model: model, settings: settings, router: router)
                } else {
                    OnboardingView(model: model, settings: settings)
                }
            }
            // Menu-bar app by default, but a real app (Dock icon, Cmd-Tab,
            // app menu) while its window is open.
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                if settings.onboardingComplete { model.startPolling() }
                Task {
                    await settings.refreshNotificationStatus()
                    await settings.recordForegroundUse()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await settings.recordForegroundUse() }
            }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
            .onChange(of: settings.onboardingComplete) { complete in
                if complete { model.startPolling() }
            }
            .onOpenURL(perform: handleURL)
        }
        .handlesExternalEvents(matching: ["now", "ports", "storage", "receipts", "settings", "close"])
        Window("Caught in 4K", id: "bust") {
            BustHost(model: model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["bust"])
        MenuBarExtra {
            MenuBarView(model: model, settings: settings, router: router)
                .onAppear { Task { await settings.recordForegroundUse() } }
        } label: {
            MenuBarIcon(model: model)
                // The label lives as long as the app: the one safe place to
                // boot the engine and the pending permission prompt.
                .onAppear {
                    if settings.onboardingComplete { model.startPolling() }
                    Task { await settings.requestNotificationsIfNeeded() }
                }
        }
        .menuBarExtraStyle(.window)
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == MachogsBuild.urlScheme else { return }
        let targets = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "target" }
            .compactMap { item -> ProcessTarget? in
                guard let value = item.value else { return nil }
                let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
                return ProcessTarget(pid: pid, identity: parts[1])
            } ?? []
        // External links may request a review, never authorize a close.
        router.page = AppPage(rawValue: url.host ?? "") ?? .now
        NSApp.activate(ignoringOtherApps: true)
        if !targets.isEmpty { Task { await model.requestProcessTargets(targets) } }
    }
}

private struct BustHost: View {
    @ObservedObject var model: AppModel

    var body: some View {
        BustView(model: model, event: model.watchdogEvent)
            .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

@MainActor
private final class SuccessSoundCoordinator {
    private var receiptCancellable: AnyCancellable?

    init(model: AppModel, settings: AppSettings) {
        receiptCancellable = model.$receipt
            .dropFirst()
            .compactMap { $0 }
            .filter { $0.isSuccess }
            .sink { [weak settings] receipt in
                guard settings?.soundOn == true else { return }
                receipt.kind == .disk ? MachogsSound.win() : MachogsSound.pop()
            }
    }
}

/// Lives at app level, not on a window: shoulder taps must fire while the
/// window is closed — that is the whole point of a watchdog.
@MainActor
private final class WatchdogNotifier {
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel, settings: AppSettings) {
        NotificationCoordinator.shared.model = model
        model.$watchdogEvent
            .compactMap { $0 }
            .sink { [weak settings, weak model] event in
                guard let settings, settings.onboardingComplete, settings.shoulderTaps, let model else { return }
                let targets = event.kind == .memory ? model.leftovers(for: event).flatMap(\.targets) : event.targets
                NotificationCoordinator.shared.post(event, targets: targets, sound: settings.soundOn)
                IslandController.shared.show(
                    event: event,
                    closeIt: { Task { await model.closeTargetsNow(event.targets) } },
                    leaveIt: { model.snoozeGroup(event.groupID, minutes: 60) }
                )
            }
            .store(in: &cancellables)
        // Every scan: banners about things already closed (by hand, by
        // automatic cleanup, or by the app that owned them) go away.
        // The first scan after 6 pm also sends the day's recap.
        model.$report
            .compactMap { $0 }
            .sink { [weak settings, weak model] report in
                NotificationCoordinator.shared.clearResolved(
                    live: Set(report.actionableFindings.map { ProcessTarget(pid: $0.pid, identity: $0.identity) }))
                if let settings, let model { Self.sendRecapIfDue(model: model, settings: settings) }
            }
            .store(in: &cancellables)
    }

    private static func sendRecapIfDue(model: AppModel, settings: AppSettings, now: Date = Date()) {
        let today = now.formatted(.iso8601.year().month().day())
        guard settings.onboardingComplete, settings.shoulderTaps, settings.eveningRecap,
              Calendar.current.component(.hour, from: now) >= 18, settings.lastRecapDay != today else { return }
        settings.lastRecapDay = today
        Task {
            await model.loadDisk()
            await model.loadWorktrees()
            let path = NSString(string: "~/Library/Logs/machogs.log").expandingTildeInPath
            let log = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let free = model.diskReport.map { max(0, $0.disk.totalGB - $0.disk.usedGB) }
            guard let recap = DailyRecap.make(log: log, now: now, freeGB: free,
                                              removableCopiesMB: model.worktreesReport?.safeMB ?? 0) else { return }
            NotificationCoordinator.shared.post(recap, sound: false)
        }
    }
}
