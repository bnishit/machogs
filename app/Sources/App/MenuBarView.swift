import AppKit
import MachogsCore
import SwiftUI

struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text("🐷")
                .font(.system(size: 14))
            if model.scanError != nil || model.hasHotFinding {
                Circle()
                    .fill(model.hasHotFinding ? Color.red : Color.orange)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                    .offset(x: 2, y: -1)
            }
        }
            .accessibilityLabel(label)
    }

    private var label: String {
        if model.scanError != nil { return "Machogs needs attention" }
        if model.hasHotFinding { return "Machogs found hot background work" }
        if !model.groups.isEmpty { return "Machogs found background leftovers" }
        return "Machogs"
    }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var router: AppRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SoftPanel {
                HStack(spacing: 12) {
                    PigMascot(mood: mascotMood, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle).font(.headline)
                        Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isScanning { ProgressView().controlSize(.small) }
                }
            }

            if !settings.onboardingComplete {
                Text("Meet the pig and choose how it should watch your Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Finish setup") { openMain(.now) }
                    .keyboardShortcut(.defaultAction)
            } else if model.groups.isEmpty {
                Text(model.scanError == nil ? "No stuck or abandoned programs need review." : "The last scan failed. Open Machogs to retry.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.groups.prefix(3)) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.story).font(.callout.weight(.medium)).lineLimit(3)
                            Button("Review close") {
                                openMain(.now)
                                Task { await model.requestProcessReview([group]) }
                            }
                            .disabled(model.isStale || model.isReviewing)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }

            if model.hasSwapPressure {
                Label("Fast memory is full. Save your work and restart when you can.", systemImage: "memorychip")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider().opacity(0.7)
            HStack {
                Button("Open Machogs") { openMain(.now) }
                Spacer()
                Button("Settings") { openMain(.settings) }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { if settings.onboardingComplete { model.startPolling() } }
    }

    private func openMain(_ page: AppPage) {
        router.page = page
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var statusTitle: String {
        if model.scanError != nil { return model.isStale ? "Last result is stale" : "Could not check" }
        if model.hasHotFinding { return "Found the hog" }
        if !model.groups.isEmpty { return "Leftovers found" }
        return model.report == nil ? "Sniffing around…" : "All clear"
    }
    private var statusDetail: String {
        if let date = model.lastSuccessfulScan { return "Last checked \(date.formatted(date: .omitted, time: .shortened))" }
        return "Looking changes nothing"
    }
    private var mascotMood: PigMood {
        if model.scanError != nil || model.hasHotFinding { return .concerned }
        if model.isScanning || model.report == nil { return .sniffing }
        return model.groups.isEmpty ? .pleased : .curious
    }
}
