import AppKit
import Combine
import MachogsCore
import SwiftUI

enum MachogsBuild {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Machogs"
    }

    static var urlScheme: String {
        Bundle.main.bundleIdentifier == "com.bnishit.machogs.dev" ? "machogs-dev" : "machogs"
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
        let model = AppModel(service: service)
        let settings = AppSettings()
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
                Task { await settings.refreshNotificationStatus() }
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
        if url.host == "close" {
            // "Close it 💥" straight from the notification. The engine
            // re-verifies every target before anything closes.
            if !targets.isEmpty { Task { await model.closeTargetsNow(targets) } }
            return
        }
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
    private var cancellable: AnyCancellable?

    init(model: AppModel, settings: AppSettings) {
        _ = NotificationCoordinator.shared
        cancellable = model.$watchdogEvent
            .compactMap { $0 }
            .sink { [weak settings, weak model] event in
                guard let settings, settings.onboardingComplete, settings.shoulderTaps else { return }
                NotificationCoordinator.shared.post(event, sound: settings.soundOn)
                guard let model else { return }
                IslandController.shared.show(
                    event: event,
                    closeIt: { Task { await model.closeTargetsNow(event.targets) } },
                    leaveIt: { model.snoozeGroup(event.groupID, minutes: 60) }
                )
            }
    }
}
