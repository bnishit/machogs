import MachogsCore
import SwiftUI

@main
struct MachogsApp: App {
    @StateObject private var model: AppModel
    @StateObject private var settings = AppSettings()
    @StateObject private var router = AppRouter()

    init() {
        let service: any MachogsServing = MachogsClient()
        _model = StateObject(wrappedValue: AppModel(service: service))
    }

    var body: some Scene {
        WindowGroup("Machogs", id: "main") {
            Group {
                if settings.onboardingComplete {
                    MainWindow(model: model, settings: settings, router: router)
                } else {
                    OnboardingView(settings: settings)
                }
            }
            .onAppear { if settings.onboardingComplete { model.startPolling() } }
            .onChange(of: settings.onboardingComplete) { complete in
                if complete { model.startPolling() }
            }
            .onOpenURL(perform: handleURL)
            .onChange(of: model.watchdogEvent) { event in
                guard settings.onboardingComplete, settings.shoulderTaps, let event else { return }
                NotificationCoordinator.shared.post(event, sound: settings.soundOn)
            }
        }
        MenuBarExtra {
            MenuBarView(model: model, settings: settings, router: router)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.window)
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "machogs" else { return }
        router.page = AppPage(rawValue: url.host ?? "") ?? .now
        NSApp.activate(ignoringOtherApps: true)
        let targets = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "target" }
            .compactMap { item -> ProcessTarget? in
                guard let value = item.value else { return nil }
                let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
                return ProcessTarget(pid: pid, identity: parts[1])
            } ?? []
        if !targets.isEmpty { Task { await model.requestProcessTargets(targets) } }
    }
}
