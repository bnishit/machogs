import AppKit
import MachogsCore
import SwiftUI

struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(model.watchdogEvent != nil ? "📸" : "🐷")
                .font(.system(size: 13)).frame(width: 18, height: 18)
            if model.scanError != nil || model.hasHotFinding {
                Circle()
                    .fill(model.hasHotFinding ? Color.red : Color.orange)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                    .offset(x: 2, y: -1)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(label)
    }

    private var label: String {
        if model.scanError != nil { return "Machogs needs attention" }
        if model.watchdogEvent != nil { return "Machogs caught something" }
        if model.hasHotFinding { return "Machogs found hot background work" }
        if !model.groups.isEmpty { return "Machogs found unused background work" }
        return "Machogs"
    }
}

private enum MenuWorkspace: String, CaseIterable, Identifiable {
    case hogs, storage, ports
    var id: Self { self }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var router: AppRouter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var workspace: MenuWorkspace = .hogs
    @State private var portQuery = ""
    @State private var appeared = false
    @State private var confettiTrigger = 0
    @State private var closingID: String?

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                .joyReveal(appeared, delay: 0)

            Picker("MacHogs view", selection: $workspace) {
                Label(hogsTabTitle, systemImage: "sparkles").tag(MenuWorkspace.hogs)
                Label(storageTabTitle, systemImage: "internaldrive").tag(MenuWorkspace.storage)
                Label(portsTabTitle, systemImage: "cable.connector").tag(MenuWorkspace.ports)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!settings.onboardingComplete)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .joyReveal(appeared, delay: 0.05)

            Divider()
            ScrollView {
                Group {
                    if !settings.onboardingComplete {
                        setupView
                    } else {
                        switch workspace {
                        case .hogs: hogsView
                        case .storage: storageView
                        case .ports: portsView
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(height: 315)
            .joyReveal(appeared, delay: 0.1)

            Divider()
            footer.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 380)
        .overlay(ConfettiBurst(trigger: confettiTrigger))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: workspace)
        .onAppear {
            appeared = true
            MachogsSound.pop(enabled: settings.soundOn)
            if settings.onboardingComplete { model.startPolling() }
            loadWorkspaceIfNeeded(workspace)
            Task { await settings.refreshNotificationStatus() }
        }
        .onChange(of: workspace) { loadWorkspaceIfNeeded($0) }
        .onChange(of: model.receipt) { receipt in
            if let receipt, receipt.closedCount > 0 { confettiTrigger += 1 }
        }
        .onChange(of: model.isActing) { acting in
            if !acting { closingID = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            PigMascot(mood: mascotMood, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacHogs").font(.headline)
                Text(headerDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { refreshWorkspace() } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(PigPressStyle())
            .disabled(isRefreshing || !settings.onboardingComplete)
            .help("Check again")
            .accessibilityLabel("Check again")
        }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Meet the pig first", systemImage: "sparkles").font(.title3.bold())
            Text("The first check only looks. Nothing can close until you review it and agree.")
                .foregroundStyle(.secondary)
            Button { openMain(.now) } label: {
                Label("Finish setup", systemImage: "sparkles")
            }
            .buttonStyle(PigActionStyle(tint: .pink))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 28)
    }

    @ViewBuilder private var hogsView: some View {
        if let error = model.scanError, model.report == nil {
            MenuState(symbol: "exclamationmark.triangle", title: "The pig lost the scent", detail: error) {
                Task { await model.scan() }
            }
        } else if model.report == nil || model.isScanning && model.groups.isEmpty {
            MenuLoading(title: "Checking who forgot to clock out…", detail: "Looking only. Nothing will close.")
        } else if model.groups.isEmpty {
            MenuState(symbol: "checkmark.circle", title: "All quiet 🐷",
                      detail: "Your Mac is working only for you.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if model.isStale { staleMessage("Couldn’t refresh. Closing is paused until a fresh check succeeds.") }
                if settings.notificationsDenied { notificationsDeniedRow }
                if model.hasSwapPressure { swapCard }
                ForEach(Array(rankedGroups.prefix(4).enumerated()), id: \.element.id) { index, group in
                    CulpritCard(
                        group: group,
                        crowned: index == 0 && group.isHot,
                        isClosing: closingID == group.id && model.isActing,
                        disabled: model.isStale || model.isActing,
                        close: {
                            closingID = group.id
                            Task { await model.closeGroupNow(group) }
                        },
                        leaveIt: { model.snoozeGroup(group.id) }
                    )
                    .hoverLift()
                }
                if rankedGroups.count > 4 {
                    Button("View \(rankedGroups.count - 4) more groups in MacHogs") { openMain(.now) }
                        .buttonStyle(.link)
                }
                if rankedGroups.count >= 2 {
                    Button {
                        closingID = "ALL"
                        Task { await model.closeEverythingNow() }
                    } label: {
                        if closingID == "ALL" && model.isActing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Closing…")
                            }.frame(maxWidth: .infinity)
                        } else {
                            Text("Close everything 🧹").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(PigActionStyle(tint: .pink))
                    .disabled(model.isStale || model.isActing)
                    .accessibilityLabel("Close everything MacHogs found")
                }
            }
        }
    }

    private var notificationsDeniedRow: some View {
        HStack(spacing: 6) {
            Label("Shoulder taps are blocked in System Settings.", systemImage: "bell.slash")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            Button("Fix") { settings.openNotificationSettings() }
                .buttonStyle(.link).font(.caption)
                .accessibilityLabel("Open notification settings for MacHogs")
        }
    }

    // The one problem closing programs cannot fix.
    private var swapCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("🌡️").font(.system(size: 16)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Out of fast memory.")
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                    Text("Only a restart truly fixes this.")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                ArmedPill(idle: "Restart now ⏻", armedTitle: "Sure? Everything closes ⏻",
                          tint: .indigo) { model.restartMac() }
            }
            Text("Memory is so full macOS is using the disk as scratch paper — that's the slowness you feel. Closing leftovers barely helps once it starts.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(red: 0.72, green: 0.48, blue: 0.10),
                                              Color(red: 0.55, green: 0.38, blue: 0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    @ViewBuilder private var storageView: some View {
        if model.diskReport == nil && model.isLoadingDisk {
            MenuLoading(title: "Measuring storage…", detail: "This takes about 15 seconds. You can keep using MacHogs.")
        } else if let report = model.diskReport {
            let safeItems = report.items.filter { $0.verdict == "safe" }.sorted { $0.sizeMB > $1.sizeMB }
            VStack(alignment: .leading, spacing: 12) {
                if model.diskError != nil { staleMessage("Couldn’t refresh. Showing the last storage check.") }
                VStack(alignment: .leading, spacing: 3) {
                    Text(safeItems.isEmpty ? "No safe cache worth clearing" : "\(storageAmount(safeItems)) safe to clear")
                        .font(.title3.bold())
                    Text("Personal files are never offered as safe cleanup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(safeItems.prefix(4)) { item in
                    Divider()
                    HStack(alignment: .top, spacing: 10) {
                        Text(item.icon).font(.title3).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.label).font(.callout.weight(.semibold))
                                Spacer()
                                Text(item.sizeText).foregroundStyle(.secondary)
                            }
                            Button {
                                openMain(.storage)
                                model.requestDiskReview(item)
                            } label: {
                                Label("Review clearing in MacHogs…", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.link)
                            .accessibilityLabel("Review clearing \(item.label) in MacHogs")
                        }
                    }
                }
                if safeItems.isEmpty {
                    Text("MacHogs measured the usual cache locations and found no useful win.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } else if let error = model.diskError {
            MenuState(symbol: "externaldrive.badge.exclamationmark", title: "Storage check failed", detail: error) {
                Task { await model.loadDisk() }
            }
        } else {
            MenuLoading(title: "Opening storage…", detail: "MacHogs only measures after you ask.")
        }
    }

    @ViewBuilder private var portsView: some View {
        if model.portsReport == nil && model.isLoadingPorts {
            MenuLoading(title: "Checking local ports…", detail: "Looking only. No app will stop.")
        } else if let report = model.portsReport {
            let items = filteredPorts(report.ports)
            VStack(alignment: .leading, spacing: 10) {
                if model.portsError != nil { staleMessage("Couldn’t refresh. Showing the last ports check.") }
                TextField("Find port: 3000", text: $portQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Find a port number")
                if items.isEmpty {
                    Text(portQuery.isEmpty ? "No ports are available to review." : "No port matches \(portQuery).")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                } else {
                    ForEach(items.prefix(6)) { item in
                        Divider()
                        MenuPortRow(item: item, disabled: model.isReviewing || model.pendingReview != nil) {
                            openMain(.ports)
                            Task { await model.requestPortReview(item) }
                        }
                    }
                }
                Button("View all ports in MacHogs") { openMain(.ports) }.buttonStyle(.link)
            }
        } else if let error = model.portsError {
            MenuState(symbol: "network.slash", title: "Ports check failed", detail: error) {
                Task { await model.loadPorts() }
            }
        } else {
            MenuLoading(title: "Opening ports…", detail: "MacHogs checks only when you open this tab.")
        }
    }

    private var footer: some View {
        HStack {
            Button { openMain(pageForWorkspace) } label: {
                Label("Open full app", systemImage: "macwindow")
            }
            Spacer()
            Text(checkedText).font(.caption).foregroundStyle(.secondary)
            Menu {
                Button("Settings") { openMain(.settings) }
                Divider()
                Button("Quit MacHogs") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("More")
        }
    }

    private func staleMessage(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            .font(.caption).foregroundStyle(.orange)
    }

    private func openMain(_ page: AppPage) {
        router.page = page
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadWorkspaceIfNeeded(_ workspace: MenuWorkspace) {
        guard settings.onboardingComplete else { return }
        switch workspace {
        case .hogs: break
        case .storage: if model.diskReport == nil { Task { await model.loadDisk() } }
        case .ports: if model.portsReport == nil { Task { await model.loadPorts() } }
        }
    }

    private func refreshWorkspace() {
        Task {
            switch workspace {
            case .hogs: await model.scan()
            case .storage: await model.loadDisk()
            case .ports: await model.loadPorts()
            }
        }
    }

    private func filteredPorts(_ ports: [PortItem]) -> [PortItem] {
        let sorted = ports.sorted {
            if $0.isClosable != $1.isClosable { return $0.isClosable }
            return $0.port < $1.port
        }
        let query = portQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { String($0.port).contains(query) }
    }

    private func storageAmount(_ items: [DiskItem]) -> String {
        let megabytes = items.reduce(0) { $0 + $1.sizeMB }
        if megabytes >= 1024 { return String(format: "%.1f GB", Double(megabytes) / 1024) }
        return "\(megabytes) MB"
    }

    private var rankedGroups: [FindingGroup] {
        model.groups.sorted {
            if $0.totalCPU != $1.totalCPU { return $0.totalCPU > $1.totalCPU }
            return $0.count > $1.count
        }
    }

    private var hogsTabTitle: String {
        let count = model.groups.reduce(0) { $0 + $1.count }
        return count == 0 ? "Hogs" : "Hogs · \(count)"
    }
    private var storageTabTitle: String {
        guard let report = model.diskReport else { return model.isLoadingDisk ? "Storage …" : "Storage" }
        let safe = report.items.filter { $0.verdict == "safe" }
        return safe.isEmpty ? "Storage" : "Storage · \(storageAmount(safe))"
    }
    private var portsTabTitle: String {
        guard let report = model.portsReport else { return model.isLoadingPorts ? "Ports …" : "Ports" }
        let count = report.ports.filter(\.isClosable).count
        return count == 0 ? "Ports" : "Ports · \(count)"
    }
    private var headerDetail: String {
        switch workspace {
        case .hogs:
            if model.hasSwapPressure { return "A restart is the honest next step" }
            if let top = rankedGroups.first {
                if top.isHot { return "\(top.owner) is making your Mac work hard" }
                let count = model.groups.reduce(0) { $0 + $1.count }
                return "\(top.owner) and friends left \(count) thing\(count == 1 ? "" : "s") running"
            }
            return model.report == nil ? "Checking what apps left behind…" : "All quiet. Working only for you."
        case .storage: return "Safe cache, measured on demand"
        case .ports: return "Who is using your local ports"
        }
    }
    private var checkedText: String {
        let date: Date?
        switch workspace {
        case .hogs: date = model.lastSuccessfulScan
        case .storage: date = model.lastSuccessfulDiskScan
        case .ports: date = model.lastSuccessfulPortsScan
        }
        guard let date else { return "Not checked yet" }
        return "Checked \(date.formatted(date: .omitted, time: .shortened))"
    }
    private var isRefreshing: Bool {
        switch workspace {
        case .hogs: return model.isScanning
        case .storage: return model.isLoadingDisk
        case .ports: return model.isLoadingPorts
        }
    }
    private var pageForWorkspace: AppPage {
        switch workspace {
        case .hogs: return .now
        case .storage: return .storage
        case .ports: return .ports
        }
    }
    private var mascotMood: PigMood {
        if model.scanError != nil || model.hasHotFinding { return .concerned }
        if isRefreshing { return .sniffing }
        return model.groups.isEmpty ? .pleased : .curious
    }
}

private struct CulpritCard: View {
    let group: FindingGroup
    let crowned: Bool
    let isClosing: Bool
    let disabled: Bool
    let close: () -> Void
    let leaveIt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if crowned { Text("👑").accessibilityLabel("Worst offender") }
                Text(group.owner).font(.callout.bold()).lineLimit(1)
                if group.count > 1 {
                    Text("×\(group.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .accessibilityLabel("\(group.count) copies")
                }
                Spacer()
                heatChip
            }
            Text(group.story).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack(spacing: 10) {
                Button(action: close) {
                    if isClosing {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Closing…")
                        }
                    } else {
                        Text("Close it 💥")
                    }
                }
                .buttonStyle(PigActionStyle(tint: .pink))
                .disabled(disabled)
                .accessibilityLabel("Close \(group.count) items left by \(group.owner)")
                Button("Leave it", action: leaveIt)
                    .buttonStyle(.link).font(.caption)
                    .accessibilityLabel("Leave \(group.owner) alone for an hour")
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }

    private var heatChip: some View {
        let cores = group.totalCPU / 100
        let text: String
        let tint: Color
        if cores >= 0.95 {
            text = String(format: "🔥 %.1f cores", cores)
            tint = .red
        } else if group.isHot {
            text = "warm"
            tint = .orange
        } else {
            text = "idle"
            tint = .secondary
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .accessibilityLabel("Using \(String(format: "%.1f", cores)) of a CPU core")
    }
}

private struct ArmedPill: View {
    let idle: String
    let armedTitle: String
    let tint: Color
    let fire: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed {
                armed = false
                fire()
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { armed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { armed = false }
                }
            }
        } label: {
            Text(armed ? armedTitle : idle)
        }
        .buttonStyle(PigActionStyle(tint: armed ? .red : tint))
        .accessibilityLabel(armed ? "Tap again to restart your Mac" : "Restart your Mac")
    }
}

private struct MenuPortRow: View {
    let item: PortItem
    let disabled: Bool
    let review: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(item.port)").font(.callout.bold().monospacedDigit()).frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.owner.isEmpty ? item.process : "\(item.owner) · \(item.process)")
                    .font(.callout.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !item.isClosable {
                    Label(item.protected ? "Live work — protected" : "Managed by macOS", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.isClosable {
                Button(action: review) {
                    Label("Free…", systemImage: "bolt.fill")
                }
                    .buttonStyle(PigActionStyle(tint: .pink))
                    .disabled(disabled)
                    .help("Open a fresh safety review in MacHogs")
                    .accessibilityLabel("Review freeing port \(item.port) from \(item.process) in MacHogs")
            }
        }
    }

    private var detail: String {
        if !item.note.isEmpty { return item.note }
        let project = item.cwd.isEmpty ? "" : (item.cwd as NSString).lastPathComponent
        return [project, item.age].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct MenuLoading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 52)
    }
}

private struct MenuState: View {
    let symbol: String
    let title: String
    let detail: String
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry { Button("Try again", action: retry) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
    }
}
