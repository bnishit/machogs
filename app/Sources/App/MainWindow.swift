import AppKit
import MachogsCore
import ServiceManagement
import SwiftUI
import UserNotifications

enum AppPage: String, CaseIterable, Identifiable {
    case now, memory, ports, storage, receipts, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: return "Overview"
        case .memory: return "Memory"
        case .ports: return "Ports"
        case .storage: return "Storage"
        case .receipts: return "Receipts"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .now: return "gauge.with.needle"
        case .memory: return "memorychip"
        case .ports: return "cable.connector"
        case .storage: return "internaldrive"
        case .receipts: return "doc.text"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var page: AppPage = .now
}

struct MainWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var router: AppRouter
    @State private var celebrationTrigger = 0
    @State private var appeared = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                SidebarSection(title: "MAC", pages: [.now, .memory, .storage], router: router, badge: badge)
                    .joyReveal(appeared, delay: 0)
                SidebarSection(title: "TOOLS", pages: [.ports], router: router, badge: badge)
                    .joyReveal(appeared, delay: 0.05)
                SidebarSection(title: "YOU", pages: [.receipts, .settings], router: router, badge: badge)
                    .joyReveal(appeared, delay: 0.1)
                Spacer()
                VStack(spacing: 5) {
                    PigMascot(mood: .pleased, size: 44)
                    Text("Apps leave messes. The pig finds them.")
                        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .joyReveal(appeared, delay: 0.15)
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if let receipt = model.receipt {
                    if receipt.isSuccess {
                        SuccessReceipt(
                            receipt: receipt,
                            model: model,
                            viewReceipt: { router.page = .receipts },
                            dismiss: model.dismissReceipt
                        )
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                    } else {
                        CalmResult(receipt: receipt, dismiss: model.dismissReceipt)
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                    }
                }
                page
            }
            .navigationTitle(router.page.title)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 600, idealHeight: 680)
        .overlay { ConfettiBurst(trigger: celebrationTrigger) }
        .sheet(item: reviewBinding) { review in
            ReviewSheet(review: review, model: model)
        }
        .onAppear {
            MachogsSound.pop(enabled: settings.soundOn)
            appeared = true
            DispatchQueue.main.async {
                guard let window = NSApp.keyWindow, window.contentView?.frame.width ?? 0 < 820 else { return }
                window.setContentSize(NSSize(width: 900, height: 680))
                window.center()
            }
        }
        .onChange(of: model.receipt) { receipt in
            if receipt?.isSuccess == true { celebrationTrigger += 1 }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch router.page {
        case .now: NowPage(model: model)
        case .memory: MemoryPage(model: model)
        case .ports: PortsPage(model: model)
        case .storage: StoragePage(model: model)
        case .receipts: ReceiptsPage(model: model, openNow: { router.page = .now })
        case .settings: SettingsPage(settings: settings)
        }
    }

    private var reviewBinding: Binding<ActionReview?> {
        Binding(get: { model.pendingReview }, set: { if $0 == nil { model.cancelReview() } })
    }

    private func badge(for page: AppPage) -> Int {
        switch page {
        case .now: return model.groups.reduce(0) { $0 + $1.count }
        case .memory: return model.memoryReport?.hoardingApps.count ?? 0
        case .ports: return model.portsReport?.ports.filter(\.isClosable).count ?? 0
        case .storage: return model.diskReport?.items.filter { $0.verdict == "safe" }.count ?? 0
        default: return 0
        }
    }

}

private struct SidebarSection: View {
    let title: String
    let pages: [AppPage]
    @ObservedObject var router: AppRouter
    let badge: (AppPage) -> Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.tertiary).padding(.leading, 9)
            ForEach(pages) { page in
                Button { router.page = page } label: {
                    HStack(spacing: 9) {
                        Image(systemName: page.symbol).frame(width: 17)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(page.title).font(.body.weight(router.page == page ? .semibold : .regular))
                            if page == .ports { Text("For developers").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if badge(page) > 0 { Text("\(badge(page))").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(router.page == page ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(router.page == page ? .isSelected : [])
            }
        }
    }
}

struct NowPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your Mac, right now").font(.largeTitle.bold())
                StatusHero(model: model)
                if model.hasSwapPressure { memoryWarning }
                findings
                if let report = model.report {
                    DisclosureGroup("Mac details") { vitals(report.host).padding(.top, 10) }
                        .font(.callout.weight(.semibold)).padding(.horizontal, 4)
                }
            }
            .padding(20)
        }
        .overlay { if model.isScanning && model.report == nil { ProgressView("Checking what your apps left behind…") } }
    }

    private var findings: some View {
        GroupBox {
            if model.groups.isEmpty {
                EmptyState(
                    symbol: "checkmark.seal",
                    title: model.report == nil ? "No fresh scan yet" : "Nothing is hogging your Mac",
                    detail: model.report == nil
                        ? "Machogs needs a successful read-only scan before it can give an answer."
                        : "No stuck or abandoned programs are running. If the Mac still feels slow, the cause is elsewhere."
                )
            } else {
                VStack(spacing: 0) {
                    if model.groups.count > 1 {
                        HStack {
                            Text("\(model.groups.reduce(0) { $0 + $1.count }) items can be closed")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Close \(model.groups.reduce(0) { $0 + $1.count }) unused things 💥") {
                                Task { await model.closeEverythingNow() }
                            }
                            .disabled(model.isStale || model.isActing)
                        }
                        .padding(.bottom, 10)
                    }
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider() }
                        FindingRow(group: group, disabled: model.isStale || model.isActing) {
                            Task { await model.closeGroupNow(group) }
                        }
                    }
                }
            }
        } label: {
            Label("What apps left behind", systemImage: "waveform.path.ecg")
                .font(.headline)
        }
    }

    private func vitals(_ host: HostSnapshot) -> some View {
        HStack(spacing: 12) {
            MetricCard(title: "Work level", value: String(format: "%.1f", host.load), detail: "across \(host.cores) CPU cores", symbol: "cpu")
            MetricCard(title: "Disk-backed memory", value: "\(host.swapPercent)%", detail: "of backup memory in use", symbol: "memorychip")
            MetricCard(title: "Time since restart", value: "\(host.uptimeDays)d", detail: "days", symbol: "clock")
        }
    }

    private var memoryWarning: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2).foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Restart recommended").font(.headline)
                    Text("Your Mac has been running for \(model.report?.host.uptimeDays ?? 0) days and is using slower disk space as backup memory. Save your work, then choose Apple menu › Restart. Cleaning the items below will not fix this.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StatusHero: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                PigMascot(mood: mascotMood, size: 66)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 29, weight: .bold, design: .rounded))
                    Text(detail).foregroundStyle(.secondary)
                    if let date = model.lastSuccessfulScan {
                        Text("Last checked \(date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button { Task { await model.scan() } } label: {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isScanning)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.16), Color.pink.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: color.opacity(0.09), radius: 18, y: 8)
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(color.opacity(0.18)))
    }

    private var title: String {
        if model.scanError != nil { return model.isStale ? "Last result is stale" : "Machogs could not check" }
        if model.isStale { return "These results are old" }
        if let first = model.groups.first {
            let owner = first.owner.isEmpty ? "An app" : first.owner
            return first.isHot ? "\(owner) is keeping your Mac busy" : "\(owner) left \(first.count) thing\(first.count == 1 ? "" : "s") running"
        }
        if model.report != nil { return "No hogs hiding here" }
        return "Checking what your apps left behind"
    }

    private var detail: String {
        if model.isStale { return "The last check is still shown, but actions are paused until Machogs can check again." }
        if let error = model.scanError { return "Nothing changed. Try again. \(error)" }
        if model.hasHotFinding { return "It is working hard enough to cause heat or fan noise. You can close it after one final safety check." }
        if !model.groups.isEmpty { return "It is idle. It can use memory, but it is not heating your Mac." }
        return model.report == nil ? "This check is read-only. Nothing can close." : "Nothing stuck or abandoned needs your attention."
    }

    private var color: Color {
        if model.scanError != nil { return .orange }
        if model.hasHotFinding { return .red }
        return model.groups.isEmpty ? .green : .orange
    }

    private var mascotMood: PigMood {
        if model.scanError != nil || model.hasHotFinding { return .concerned }
        if model.isScanning || model.report == nil { return .sniffing }
        return model.groups.isEmpty ? .pleased : .curious
    }
}

struct FindingRow: View {
    let group: FindingGroup
    let disabled: Bool
    let review: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: group.isHot ? "flame.fill" : "shippingbox")
                .foregroundStyle(group.isHot ? .red : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(group.story).font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(group.owner.isEmpty ? "Unknown app" : group.owner)
                    Text("•")
                    Text("\(group.count) item\(group.count == 1 ? "" : "s")")
                    if group.totalCPU >= 1 { Text("• \(group.totalCPU, specifier: "%.1f")% CPU") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Close \(group.count) 💥", action: review)
                .disabled(disabled)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

struct PortsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageIntro(title: "Find what is using a port", detail: "A port is a numbered door apps use for local connections. If an app says ‘port already in use,’ look here.")
                if let error = model.portsError { ErrorCard(message: error, retry: { Task { await model.loadPorts() } }) }
                if let report = model.portsReport {
                    let closable = report.ports.filter(\.isClosable)
                    let protected = report.ports.filter(\.protected)
                    let system = report.ports.filter { !$0.isClosable && !$0.protected }
                    PortSection(title: "Yours", detail: "Can be closed after a safety check", items: closable, model: model)
                    PortSection(title: "Protected live work", detail: "Shown, never stopped", items: protected, model: model)
                    PortSection(title: "macOS and managed services", detail: "Killing these would not help", items: system, model: model)
                    if report.ports.isEmpty { EmptyState(symbol: "network", title: "No apps are waiting for local connections", detail: "No open ports need your attention right now.") }
                } else {
                    ProgressView("Checking ports…").frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(20)
        }
        .task { if model.portsReport == nil { await model.loadPorts() } }
    }
}

struct PortSection: View {
    let title: String
    let detail: String
    let items: [PortItem]
    @ObservedObject var model: AppModel

    var body: some View {
        if !items.isEmpty {
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            Text("Port \(item.port)").font(.headline.monospacedDigit()).frame(width: 86, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.process).font(.body.weight(.medium))
                                Text(portDetail(item)).font(.caption).foregroundStyle(.secondary)
                                if !item.note.isEmpty { Text(item.note).font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            if item.isClosable {
                                Button("Free port \(item.port) 💥") { Task { await model.closePortNow(item) } }
                                    .disabled(model.isActing)
                            } else {
                                Label(item.protected ? "Active work — protected" : "Managed by macOS", systemImage: "lock.shield")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
            } label: {
                VStack(alignment: .leading) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func portDetail(_ item: PortItem) -> String {
        [item.owner, item.cwd, item.age].filter { !$0.isEmpty }.joined(separator: " • ")
    }
}

struct MemoryPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageIntro(title: "Who is holding your memory", detail: "Every app with all of its background pieces added up, the way the Force Quit dialog counts. Cold memory has been pushed out to disk because nothing touches it — an app doing real work stays warm.")
                if let error = model.memoryError { ErrorCard(message: error, retry: { Task { await model.loadMemory() } }) }
                if let report = model.memoryReport {
                    pressureCard(report.host)
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(Array(report.apps.enumerated()), id: \.element.id) { index, app in
                                if index > 0 { Divider() }
                                MemoryAppRow(app: app)
                            }
                            if report.apps.isEmpty {
                                EmptyState(symbol: "memorychip", title: "Could not read memory sizes", detail: "Nothing was measured on this run. Try again.")
                            }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Apps, heaviest first").font(.headline)
                            Text("Machogs closes nothing on this screen. To get the memory back, quit the app itself.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView("Adding up your apps…").frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(20)
        }
        .task { if model.memoryReport == nil { await model.loadMemory() } }
    }

    // A hog is a curiosity at 20% swap and an emergency at 92% — the same
    // numbers deserve different urgency, so the pressure context leads.
    private func pressureCard(_ host: HostSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(host.swapPercent)% of backup memory in use").font(.title2.bold())
                    Spacer()
                    Button { Task { await model.loadMemory() } } label: {
                        if model.isLoadingMemory { ProgressView().controlSize(.small) }
                        else { Label("Check again", systemImage: "arrow.clockwise") }
                    }
                    .disabled(model.isLoadingMemory)
                }
                DiskGauge(pct: host.swapPercent)
                Text(host.swapPercent > 80
                     ? "Your Mac is out of fast memory and is shuffling to disk. What is listed below is why it feels slow."
                     : "There is still room. This list is worth a look, not a worry.")
                    .font(.caption).foregroundStyle(host.swapPercent > 80 ? .orange : .secondary)
            }.padding(4)
        }
    }
}

struct MemoryAppRow: View {
    let app: MemoryApp
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 0) {
                ForEach(app.processes) { proc in
                    HStack(spacing: 12) {
                        Text(proc.memoryText).font(.callout.monospacedDigit().weight(.medium))
                            .frame(width: 78, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(proc.name).font(.callout)
                            Text("pid \(String(proc.pid)) • \(mbTextCold(proc)) cold • running \(proc.age)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5).padding(.leading, 8)
                }
                if app.processCount > app.processes.count {
                    Text("…and \(app.processCount - app.processes.count) smaller pieces")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5).padding(.leading, 8)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 12) {
                Text(app.memoryText).font(.headline.monospacedDigit())
                    .frame(width: 86, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(app.app).font(.body.weight(.medium))
                        if app.isHoarding {
                            Label("Hoarding", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                .accessibilityLabel("This app is hoarding memory")
                        }
                    }
                    Text(rowDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var rowDetail: String {
        var parts = ["\(app.coldPercent)% cold", "\(app.processCount) process\(app.processCount == 1 ? "" : "es")", "oldest running \(app.oldestAge)"]
        if app.isHoarding, let big = app.biggestProcess {
            parts.append("biggest piece: \(big.name) at \(big.memoryText)")
        }
        return parts.joined(separator: " • ")
    }

    private func mbTextCold(_ proc: MemoryProcess) -> String {
        proc.memoryMB > 0 ? "\(min(100, proc.compressedMB * 100 / proc.memoryMB))%" : "0%"
    }
}

struct StoragePage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageIntro(title: "Make room safely", detail: "Machogs checks common caches and large folders. It never offers to delete personal files.")
                if let error = model.diskError { ErrorCard(message: error, retry: { Task { await model.loadDisk() } }) }
                if let report = model.diskReport {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text("\(max(0, report.disk.totalGB - report.disk.usedGB)) GB free").font(.title2.bold()); Spacer(); Text("\(report.disk.usedGB) GB used") }
                            DiskGauge(pct: report.disk.percent)
                            HStack {
                                Text("\(report.disk.percent)% full").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if clearableMB(report) >= 100 {
                                    Text("\(sizeText(clearableMB(report))) safely clearable below")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.teal)
                                }
                            }
                        }.padding(4)
                    }
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(Array(report.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                HStack(alignment: .top, spacing: 12) {
                                    Text(item.icon).font(.title2).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(item.label).font(.headline); Text(item.sizeText).foregroundStyle(.secondary) }
                                        Text(verdict(item)).font(.caption.weight(.semibold)).foregroundStyle(verdictColor(item))
                                        Text(item.how).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if item.verdict == "safe" {
                                        Button("Clear \(item.sizeText)…") { model.requestDiskReview(item) }
                                    } else {
                                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path) }
                                    }
                                }
                                .padding(.vertical, 10)
                            }
                        }
                    } label: { Label("Measured locations", systemImage: "internaldrive") }
                } else {
                    ProgressView("Measuring storage…").frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(20)
        }
        .task { if model.diskReport == nil { await model.loadDisk() } }
    }

    private func verdict(_ item: DiskItem) -> String {
        switch item.verdict { case "safe": return "Safe cache"; case "check": return "Check first"; default: return "Your files, your call" }
    }
    private func verdictColor(_ item: DiskItem) -> Color {
        switch item.verdict { case "safe": return .green; case "check": return .orange; default: return .blue }
    }
    private func clearableMB(_ report: DiskReport) -> Int {
        report.items.filter { $0.verdict == "safe" }.reduce(0) { $0 + $1.sizeMB }
    }
    private func sizeText(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
}

// The disk fills up like a battery gauge, springing to its level.
struct DiskGauge: View {
    let pct: Int
    @State private var shown = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(
                        colors: pct >= 90 ? [.orange, .red] : [.teal, .green],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * CGFloat(pct) / 100) * (shown ? 1 : 0.02))
            }
        }
        .frame(height: 7)
        .accessibilityElement()
        .accessibilityLabel("Disk \(pct) percent full")
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(0.15)) { shown = true }
        }
    }
}

struct ReceiptsPage: View {
    @ObservedObject var model: AppModel
    let openNow: () -> Void
    @State private var history: [ReceiptEvent] = []
    @State private var copied = false
    @State private var error: String?
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageIntro(title: "Your receipts", detail: sinceText)
                if history.isEmpty {
                    EmptyState(symbol: "doc.text", title: "No receipts yet", detail: "After Machogs closes something you approve, the score starts here.")
                    Button("Check my Mac", action: openNow)
                } else {
                    heroRow.joyReveal(appeared, delay: 0.02)
                    hallOfShame.joyReveal(appeared, delay: 0.06)
                    bragRow.joyReveal(appeared, delay: 0.10)
                    historyList.joyReveal(appeared, delay: 0.14)
                }
            }
            .padding(20)
        }
        .onAppear {
            history = ReceiptEvent.load()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { appeared = true }
        }
        .onChange(of: model.receipt) { _ in history = ReceiptEvent.load() }
    }

    private var sinceText: String {
        guard let since = history.map(\.date).min() else {
            return "A receipt appears only after Machogs successfully closes something you approved."
        }
        return "What your Mac was doing behind your back · since \(since.formatted(.dateTime.day().month()))"
    }

    private var totalCPUSeconds: Int { history.reduce(0) { $0 + $1.cpuSeconds } }
    private var phoneCharges: Int { totalCPUSeconds / 9000 }

    private var timeWasted: (value: Double, suffix: String) {
        let s = totalCPUSeconds
        if s >= 7200 { return (Double(s / 3600), "h") }
        if s >= 120 { return (Double(s / 60), "m") }
        return (Double(s), "s")
    }

    private var byApp: [AppScore] {
        Dictionary(grouping: history, by: \.owner)
            .map { AppScore(owner: $0.key, closes: $0.value.count,
                            cpuSeconds: $0.value.reduce(0) { $0 + $1.cpuSeconds }) }
            .sorted { ($0.cpuSeconds, $0.closes) > ($1.cpuSeconds, $1.closes) }
    }

    private var heroRow: some View {
        HStack(spacing: 12) {
            StatCard(emoji: "⏱️", value: timeWasted.value, suffix: timeWasted.suffix,
                     caption: "of CPU time wasted on programs you never opened", tint: .orange)
            StatCard(emoji: "🧹", value: Double(history.count), suffix: "",
                     caption: "background programs caught and closed", tint: .pink)
            StatCard(emoji: "⚡", value: Double(phoneCharges), suffix: "",
                     caption: phoneCharges == 0
                         ? "phone charges wasted — caught them before they cost you 😌"
                         : "phone charges of wasted electricity", tint: .teal)
        }
    }

    private var hallOfShame: some View {
        let heavyBurn = (byApp.map(\.cpuSeconds).max() ?? 0) >= 60
        let ranked = heavyBurn ? byApp : byApp.sorted { $0.closes > $1.closes }
        let maxSecs = max(1, ranked.map(\.cpuSeconds).max() ?? 1)
        let maxCloses = max(1, ranked.map(\.closes).max() ?? 1)
        return GroupBox {
            VStack(spacing: 12) {
                ForEach(Array(ranked.prefix(6).enumerated()), id: \.element.id) { rank, app in
                    shameRow(rank: rank, app: app, heavyBurn: heavyBurn,
                             maxSecs: maxSecs, maxCloses: maxCloses)
                }
            }
            .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading) {
                Text("🏆 Hall of Shame").font(.headline)
                Text("Who leaves the most junk running on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func shameRow(rank: Int, app: AppScore, heavyBurn: Bool, maxSecs: Int, maxCloses: Int) -> some View {
        // Bars scale to whatever metric did the ranking, so #1 always has the longest bar.
        let frac = heavyBurn
            ? Double(app.cpuSeconds) / Double(maxSecs)
            : Double(app.closes) / Double(maxCloses)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("#\(rank + 1)")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(.tertiary)
                Text(app.owner.isEmpty || app.owner == "unknown" ? "mystery programs 👻" : app.owner)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(rank == 0 ? Color.orange : Color.primary)
                if rank == 0 { Text("👑") }
                Spacer()
                Text("\(app.closes) closed · \(timeText(app.cpuSeconds)) wasted")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(LinearGradient(colors: rank == 0 ? [.orange, .pink] : [.pink.opacity(0.7), .pink.opacity(0.4)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, geo.size.width * frac) * (appeared ? 1 : 0.02))
                }
            }
            .frame(height: 6)
            .animation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.2 + Double(rank) * 0.07), value: appeared)
        }
        .hoverLift()
        .accessibilityElement(children: .combine)
    }

    private func timeText(_ s: Int) -> String {
        if s >= 7200 { return "\(s / 3600) hrs" }
        if s >= 120 { return "\(s / 60) min" }
        return "\(s) sec"
    }

    private var bragRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Flex it.").font(.system(.callout, design: .rounded).weight(.bold))
                Text("One card with your totals, ready to paste anywhere.")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                copyCard()
            } label: {
                Text(copied ? "Copied ✓ go flex" : "Copy the evidence 📸")
            }
            .buttonStyle(PigActionStyle(tint: copied ? .green : .pink))
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color.pink.opacity(0.10), Color.orange.opacity(0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.pink.opacity(0.2), lineWidth: 1))
    }

    private var historyList: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(history.prefix(50).enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider() }
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.what).font(.body.weight(.medium))
                            Text("Left by \(event.owner) • \(event.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(event.cpuSeconds)s CPU").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(.vertical, 9)
                }
            }
        } label: { Label("Receipt history", systemImage: "clock.arrow.circlepath") }
    }

    private func copyCard() {
        Task {
            do {
                let card = try await model.makeShareCard()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card, forType: .string)
                copied = true; error = nil
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                copied = false
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct AppScore: Identifiable {
    let owner: String
    let closes: Int
    let cpuSeconds: Int
    var id: String { owner }
}

struct SettingsPage: View {
    @ObservedObject var settings: AppSettings
    @State private var shoulderTaps: Bool
    @State private var startAtLogin: Bool
    @State private var soundOn: Bool

    init(settings: AppSettings) {
        self.settings = settings
        _shoulderTaps = State(initialValue: settings.shoulderTaps)
        _startAtLogin = State(initialValue: settings.startAtLogin)
        _soundOn = State(initialValue: settings.soundOn)
    }

    var body: some View {
        Form {
            Section("Background") {
                Toggle("Notify me when a hog sticks around", isOn: $shoulderTaps)
                    .onChange(of: shoulderTaps) { value in Task { await settings.setShoulderTaps(value) } }
                Text("Alerts open Machogs. They never close anything.").font(.caption).foregroundStyle(.secondary)
                notificationRow
                Toggle("Open Machogs at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { value in
                        if !settings.setStartAtLogin(value) { startAtLogin = settings.startAtLogin }
                    }
                HStack {
                    Toggle("Play sounds", isOn: $soundOn)
                        .onChange(of: soundOn, perform: settings.setSound)
                    Spacer()
                    Button("Test pig pop") { MachogsSound.pop() }
                        .disabled(!soundOn)
                }
                if let error = settings.setupError { Text(error).foregroundStyle(.orange) }
            }
            Section("Safety") {
                PromiseRow("Checks are read-only.")
                PromiseRow("Before anything closes, you see it and the engine checks it again.")
                PromiseRow("Live coding sessions and macOS stay protected.")
                PromiseRow("Personal files never get a delete button.")
            }
            Section("About") {
                LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"))")
                LabeledContent("Build", value: BuildIdentity.current().label)
                Button("Check for Updates") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/bnishit/machogs/releases")!)
                }
                Text("Uninstall: turn off Start at Login, quit Machogs, then move it to Trash. Receipts and preferences remain on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .task { await settings.refreshNotificationStatus() }
    }

    @ViewBuilder
    private var notificationRow: some View {
        switch settings.notificationStatus {
        case .denied:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("macOS is blocking Machogs alerts").font(.callout.weight(.semibold))
                    Text("You said no to notifications once, so shoulder taps never reach you. Allow them in System Settings to get them back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open System Settings") { settings.openNotificationSettings() }
            }
        case .notDetermined:
            HStack {
                Text("macOS has not asked you about alerts yet.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Allow notifications") { Task { await settings.requestNotificationsIfNeeded() } }
            }
        default:
            Label("Notifications are on. Shoulder taps will reach you.", systemImage: "bell.badge.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ReviewSheet: View {
    let review: ActionReview
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsEveryItem = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.largeTitle).foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(review.title).font(.title2.bold())
                    Text(review.body).foregroundStyle(.secondary)
                }
            }

            GroupBox {
                switch review.kind {
                case .processes(let findings):
                    VStack(alignment: .leading, spacing: 12) {
                        if showsEveryItem {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(findings) { item in
                                        Text(item.story)
                                            .font(.caption)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(maxHeight: 260)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(review.processGroups) { group in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(group.owner.isEmpty ? "Unknown app" : group.owner)
                                                .font(.headline)
                                            Text(groupLabel(group))
                                                .font(.body.weight(.semibold))
                                            Text(group.story)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityElement(children: .combine)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(maxHeight: 260)
                        }

                        if findings.count > review.processGroups.count {
                            Button(showsEveryItem ? "Show grouped summary" : "Show all \(findings.count) items") {
                                showsEveryItem.toggle()
                            }
                            .font(.callout.weight(.medium))
                        }
                    }
                case .port(let item):
                    LabeledContent("Port \(item.port)", value: "\(item.process) • \(item.owner)")
                case .disk(let item):
                    LabeledContent(item.label, value: item.sizeText)
                }
            }

            HStack {
                Button("Keep them running", role: .cancel) { model.cancelReview(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isActing)
                Spacer()
                Button(review.confirmLabel, role: .destructive) {
                    Task { await model.confirmReview(); dismiss() }
                }
                .disabled(model.isActing)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func groupLabel(_ group: FindingGroup) -> String {
        let noun = group.what.isEmpty ? "background item" : group.what
        return "\(group.count) \(noun)\(group.count == 1 || noun.hasSuffix("s") ? "" : "s")"
    }
}

struct SuccessReceipt: View {
    let receipt: CleanupReceipt
    @ObservedObject var model: AppModel
    let viewReceipt: () -> Void
    let dismiss: () -> Void
    @State private var copied = false
    @State private var copyError: String?

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            PigMascot(mood: .pleased, size: 86)
            VStack(alignment: .leading, spacing: 7) {
                Label("Caught in 4K.", systemImage: "camera.fill")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(receipt.message).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if receipt.canShare {
                        Button("View receipt", action: viewReceipt)
                            .buttonStyle(.borderedProminent)
                        Button(copied ? "Copied — paste it anywhere" : "Copy the evidence") { copyEvidence() }
                    } else {
                        Button("Done", action: dismiss)
                            .buttonStyle(.borderedProminent)
                    }
                    if let copyError { Text(copyError).font(.caption).foregroundStyle(.orange) }
                }
            }
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill").font(.title3).accessibilityLabel("Dismiss receipt")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color.pink.opacity(0.16), Color.orange.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.pink.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }

    private func copyEvidence() {
        Task {
            do {
                let card = try await model.makeShareCard()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card, forType: .string)
                copied = true; copyError = nil
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                copied = false
            } catch { copyError = error.localizedDescription }
        }
    }
}

struct CalmResult: View {
    let receipt: CleanupReceipt
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PigMascot(mood: .curious, size: 38)
            Text(receipt.message).font(.callout.weight(.medium))
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").accessibilityLabel("Dismiss result") }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

// Numbers that roll up from zero when they land on screen.
struct CountUp: View, Animatable {
    var value: Double
    var suffix: String = ""
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text("\(Int(value))\(suffix)")
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .monospacedDigit()
    }
}

struct StatCard: View {
    let emoji: String
    let value: Double
    let suffix: String
    let caption: String
    let tint: Color
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emoji).font(.system(size: 18)).accessibilityHidden(true)
            CountUp(value: shown || reduceMotion ? value : 0, suffix: suffix)
                .foregroundStyle(
                    LinearGradient(colors: [tint, tint.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom))
            Text(caption)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .hoverLift()
        .accessibilityElement(children: .combine)
        .onAppear {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.9).delay(0.15)) { shown = true }
        }
    }
}

struct MetricCard: View {
    let title: String, value: String, detail: String, symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .hoverLift()
        .accessibilityElement(children: .combine)
    }
}

struct PageIntro: View {
    let title: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

struct EmptyState: View {
    let symbol: String, title: String, detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity).padding(30)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorCard: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Spacer(); Button("Retry", action: retry)
        }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }
}

struct PromiseRow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Label(text, systemImage: "checkmark.shield").foregroundStyle(.secondary) }
}

struct ReceiptEvent: Identifiable {
    let id = UUID()
    let date: Date
    let owner: String
    let what: String
    let cpuSeconds: Int

    static func load() -> [ReceiptEvent] {
        let path = NSString(string: "~/Library/Logs/machogs.log").expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 7, fields[1] == "closed", let date = formatter.date(from: String(fields[0])) else { return nil }
            return ReceiptEvent(date: date, owner: String(fields[3]), what: String(fields[4]), cpuSeconds: Int(Double(fields[6]) ?? 0))
        }.reversed()
    }
}
