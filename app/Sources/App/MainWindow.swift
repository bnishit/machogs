import AppKit
import MachogsCore
import ServiceManagement
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case now, ports, storage, receipts, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: return "Now"
        case .ports: return "Ports"
        case .storage: return "Storage"
        case .receipts: return "Receipts"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .now: return "gauge.with.needle"
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

    var body: some View {
        NavigationSplitView {
            List(selection: $router.page) {
                ForEach(AppPage.allCases) { page in
                    Label(page.title, systemImage: page.symbol)
                        .tag(page)
                        .badge(badge(for: page))
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 5) {
                    PigMascot(mood: .pleased, size: 32)
                    Text("Finds the hog. Names the app.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        } detail: {
            page
                .navigationTitle(router.page.title)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 600, idealHeight: 680)
        .sheet(item: reviewBinding) { review in
            ReviewSheet(review: review, model: model)
        }
        .onAppear {
            DispatchQueue.main.async {
                guard let window = NSApp.keyWindow, window.contentView?.frame.width ?? 0 < 820 else { return }
                window.setContentSize(NSSize(width: 900, height: 680))
                window.center()
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch router.page {
        case .now: NowPage(model: model)
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
        case .ports: return model.portsReport?.ports.filter(\.isClosable).count ?? 0
        case .storage: return model.diskReport?.items.filter { $0.verdict == "safe" }.count ?? 0
        default: return 0
        }
    }

}

struct NowPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StatusHero(model: model)
                if let receipt = model.receipt { ReceiptBanner(receipt: receipt, dismiss: model.dismissReceipt) }
                if model.hasSwapPressure { memoryWarning }
                if let report = model.report { vitals(report.host) }
                findings
            }
            .padding(20)
        }
        .overlay { if model.isScanning && model.report == nil { ProgressView("Sniffing around…") } }
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
                            Text("\(model.groups.reduce(0) { $0 + $1.count }) reviewed candidates")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Review all closes") {
                                Task { await model.requestProcessReview(model.groups) }
                            }
                            .disabled(model.isStale || model.isReviewing)
                        }
                        .padding(.bottom, 10)
                    }
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider() }
                        FindingRow(group: group, disabled: model.isStale || model.isReviewing) {
                            Task { await model.requestProcessReview([group]) }
                        }
                    }
                }
            }
        } label: {
            Label("Background work", systemImage: "waveform.path.ecg")
                .font(.headline)
        }
    }

    private func vitals(_ host: HostSnapshot) -> some View {
        HStack(spacing: 12) {
            MetricCard(title: "System load", value: String(format: "%.1f", host.load), detail: "across \(host.cores) cores", symbol: "cpu")
            MetricCard(title: "Swap used", value: "\(host.swapPercent)%", detail: "fast-memory overflow", symbol: "memorychip")
            MetricCard(title: "Uptime", value: "\(host.uptimeDays)d", detail: "since restart", symbol: "clock")
        }
    }

    private var memoryWarning: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2).foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your Mac is out of fast memory").font(.headline)
                    Text("It is shuffling work to disk. Closing background leftovers will not fix that; save your work and restart from the Apple menu when you can.")
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
        if model.hasHotFinding { return "Found the hog" }
        if !model.groups.isEmpty { return "Leftovers found" }
        if model.report != nil { return "Nothing is hogging your Mac" }
        return "Sniffing around…"
    }

    private var detail: String {
        if let error = model.scanError { return error }
        if model.hasHotFinding { return "A background program is using enough CPU to cause heat or fan noise." }
        if !model.groups.isEmpty { return "Idle background work is holding memory. Review it before anything closes." }
        return "Looking changes nothing. Closing is always your call."
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
            Button("Review close", action: review)
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
                PageIntro(title: "Who is holding your ports?", detail: "Machogs names the listener and leaves macOS services and live coding sessions alone.")
                if let error = model.portsError { ErrorCard(message: error, retry: { Task { await model.loadPorts() } }) }
                if let report = model.portsReport {
                    let closable = report.ports.filter(\.isClosable)
                    let protected = report.ports.filter(\.protected)
                    let system = report.ports.filter { !$0.isClosable && !$0.protected }
                    PortSection(title: "Yours", detail: "Can be reviewed", items: closable, model: model)
                    PortSection(title: "Protected live work", detail: "Shown, never stopped", items: protected, model: model)
                    PortSection(title: "macOS and managed services", detail: "Killing these would not help", items: system, model: model)
                    if report.ports.isEmpty { EmptyState(symbol: "network", title: "No listening ports", detail: "Nothing is listening for local connections right now.") }
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
                            Text(":\(item.port)").font(.headline.monospacedDigit()).frame(width: 58, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.process).font(.body.weight(.medium))
                                Text(portDetail(item)).font(.caption).foregroundStyle(.secondary)
                                if !item.note.isEmpty { Text(item.note).font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            if item.isClosable {
                                Button("Review freeing port") { Task { await model.requestPortReview(item) } }
                            } else {
                                Label(item.protected ? "Protected" : "Left alone", systemImage: "lock.shield")
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

struct StoragePage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageIntro(title: "A storage X-ray, not a file cleaner", detail: "Machogs measures common junk spots. Personal files never get a delete button.")
                if let error = model.diskError { ErrorCard(message: error, retry: { Task { await model.loadDisk() } }) }
                if let report = model.diskReport {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text("\(report.disk.usedGB) GB used").font(.title2.bold()); Spacer(); Text("of \(report.disk.totalGB) GB") }
                            ProgressView(value: Double(report.disk.percent), total: 100)
                            Text("\(report.disk.percent)% full").font(.caption).foregroundStyle(.secondary)
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
                                        Button("Review clearing") { model.requestDiskReview(item) }
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
}

struct ReceiptsPage: View {
    @ObservedObject var model: AppModel
    let openNow: () -> Void
    @State private var history: [ReceiptEvent] = []
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageIntro(title: "Proof, not cleaner theatre", detail: "Receipts come from successful engine actions. Failed, cancelled, protected, and already-gone reviews do not count.")
                if history.isEmpty {
                    EmptyState(symbol: "doc.text", title: "No receipts yet", detail: "Close your first reviewed hog from Now and the shared engine log will appear here.")
                    Button("Open Now", action: openNow)
                } else {
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
                    } label: { Label("Close history", systemImage: "clock.arrow.circlepath") }

                    HStack {
                        Button(copied ? "Copied" : "Copy my receipt card") { copyCard() }
                        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            .padding(20)
        }
        .onAppear { history = ReceiptEvent.load() }
        .onChange(of: model.receipt) { _ in history = ReceiptEvent.load() }
    }

    private func copyCard() {
        Task {
            do {
                let card = try await model.makeShareCard()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card, forType: .string)
                copied = true; error = nil
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                copied = false
            } catch { self.error = error.localizedDescription }
        }
    }
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
                Toggle("Shoulder taps", isOn: $shoulderTaps)
                    .onChange(of: shoulderTaps) { value in Task { await settings.setShoulderTaps(value) } }
                Text("Alerts lead to Review. They never close a process.").font(.caption).foregroundStyle(.secondary)
                Toggle("Start at Login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { value in
                        if !settings.setStartAtLogin(value) { startAtLogin = settings.startAtLogin }
                    }
                Toggle("Sounds", isOn: $soundOn)
                    .onChange(of: soundOn, perform: settings.setSound)
                if let error = settings.setupError { Text(error).foregroundStyle(.orange) }
            }
            Section("The promises") {
                PromiseRow("Looking changes nothing.")
                PromiseRow("Every action is named, reviewed, and checked again by the engine.")
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
    }
}

struct ReviewSheet: View {
    let review: ActionReview
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

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
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(findings) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.story).font(.body.weight(.medium))
                                Text("\(item.owner) • PID \(item.pid)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                case .port(let item):
                    LabeledContent("Port \(item.port)", value: "\(item.process) • \(item.owner)")
                case .disk(let item):
                    LabeledContent(item.label, value: item.sizeText)
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { model.cancelReview(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(review.confirmLabel, role: .destructive) {
                    Task { await model.confirmReview(); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct ReceiptBanner: View {
    let receipt: CleanupReceipt
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PigMascot(mood: receipt.closedCount > 0 ? .pleased : .curious, size: 38)
            Text(receipt.message).font(.callout.weight(.medium))
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").accessibilityLabel("Dismiss result") }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.green.opacity(0.08)))
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
