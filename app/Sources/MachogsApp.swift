// Machogs.app — the pig in your menu bar.
//
// A thin SwiftUI shell over the machogs bash engine. The engine does all the
// finding and all the safety reasoning; the app only renders its JSON and, on
// an explicit click, closes the pids the engine already vetted as reapable.
// It never invents its own verdicts and never touches a pid the engine
// marked protected or never-killed.

import SwiftUI
import ServiceManagement

// MARK: - Engine JSON

struct Host: Codable {
    let load: Double
    let cores: Int
    let swap_pct: Int
    let uptime_days: Int
}

struct Summary: Codable {
    let reapable: Int
    let killed: Int
}

struct Finding: Codable, Identifiable {
    let pid: Int
    let section: String
    let action: String
    let cpu: Double
    let cpu_seconds: Int
    let age: String
    let owner: String
    let what: String
    let detail: String
    let story: String
    var id: Int { pid }

    var closable: Bool { action == "reapable" || action == "needs-dupes-flag" }
    var hot: Bool { cpu >= 20 }
}

struct Report: Codable {
    let mode: String
    let host: Host
    let summary: Summary
    let findings: [Finding]
}

// One card in the UI = one identical story, however many pids share it.
struct FindingGroup: Identifiable {
    let story: String
    let members: [Finding]
    var id: String { story }
    var count: Int { members.count }
    var hot: Bool { members.contains { $0.hot } }
    var totalCPU: Double { members.reduce(0) { $0 + $1.cpu } }
    var totalCPUSeconds: Int { members.reduce(0) { $0 + $1.cpu_seconds } }
}

// MARK: - Engine wrapper

@MainActor
final class Engine: ObservableObject {
    @Published var report: Report?
    @Published var groups: [FindingGroup] = []
    @Published var receipt: String?
    @Published var errorText: String?
    @Published var refreshing = false

    private var timer: Timer?
    private var started = false

    var hot: Bool { groups.contains { $0.hot } }
    var clean: Bool { groups.isEmpty }
    var swapTrouble: Bool { (report?.host.swap_pct ?? 0) > 80 }

    // Bundled copy first, then wherever the CLI already lives.
    nonisolated static func scriptPath() -> String? {
        if let p = Bundle.main.path(forResource: "machogs", ofType: nil) { return p }
        for p in ["/opt/homebrew/bin/machogs", "/usr/local/bin/machogs"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        errorText = nil
        Task.detached(priority: .utility) {
            let result = Self.runEngine()
            await MainActor.run {
                self.refreshing = false
                switch result {
                case .success(let report):
                    self.report = report
                    let closable = report.findings.filter { $0.closable }
                    self.groups = Dictionary(grouping: closable, by: { $0.story })
                        .map { FindingGroup(story: $0.key, members: $0.value) }
                        .sorted { $0.totalCPU > $1.totalCPU }
                case .failure(let err):
                    self.errorText = err.message
                }
            }
        }
    }

    struct EngineError: Error { let message: String }

    nonisolated private static func runEngine() -> Result<Report, EngineError> {
        guard let script = scriptPath() else {
            return .failure(EngineError(message: "Can't find the machogs engine. Reinstall the app or `brew install bnishit/tap/machogs`."))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, "--json", "--sessions"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return .failure(EngineError(message: "Couldn't run the engine: \(error.localizedDescription)"))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // exit 10 = findings exist; that is a report, not an error
        guard p.terminationStatus == 0 || p.terminationStatus == 10 else {
            return .failure(EngineError(message: "Engine exited with status \(p.terminationStatus)."))
        }
        do {
            return .success(try JSONDecoder().decode(Report.self, from: data))
        } catch {
            return .failure(EngineError(message: "Couldn't read the engine's report."))
        }
    }

    // Close one group. Only pids the engine marked closable ever reach here.
    func close(_ group: FindingGroup) {
        var closed = 0
        var freedCPU = 0.0
        var freedSecs = 0
        for f in group.members where f.closable {
            if kill(pid_t(f.pid), SIGKILL) == 0 {
                closed += 1
                freedCPU += f.cpu
                freedSecs += f.cpu_seconds
                Self.log(f)
            }
        }
        guard closed > 0 else { return }
        var lines = ["🎉 Closed \(closed) program\(closed == 1 ? "" : "s")."]
        let cores = freedCPU / 100
        if cores >= 0.2 { lines.append("Got back \(String(format: "%.1f", cores)) of a CPU core.") }
        let charges = freedSecs / 9000  // ~6W core, ~15Wh phone battery
        if charges >= 2 { lines.append("⚡ The wasted power ≈ \(charges) phone charges.") }
        receipt = lines.joined(separator: " ")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
    }

    // Same tab-separated line the CLI writes, so `machogs blame` counts us.
    nonisolated private static func log(_ f: Finding) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let owner = f.owner.isEmpty ? "unknown" : f.owner
        let what = f.what.isEmpty ? "program" : f.what
        let line = "\(fmt.string(from: Date()))\tclosed\t\(f.pid)\t\(owner)\t\(what)\t\(f.cpu)\t\(f.cpu_seconds)\n"
        let path = NSString(string: "~/Library/Logs/machogs.log").expandingTildeInPath
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @ObservedObject var engine: Engine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let err = engine.errorText {
                Text(err).font(.callout).foregroundStyle(.red)
            }
            if engine.swapTrouble {
                banner("🌡️ Your Mac is out of fast memory after \(engine.report?.host.uptime_days ?? 0) days on. Closing programs won't fix that part — restart when you can.")
            }
            if let receipt = engine.receipt {
                banner(receipt, color: .green)
            }
            if engine.clean && engine.errorText == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("✨ Nothing is hogging your Mac.").font(.headline)
                    Text("No stuck or abandoned programs. It's just vibing.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(engine.groups) { group in
                    card(group)
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text(engine.hot ? "🐷 Found the hog." : (engine.clean ? "🐷 machogs" : "🧹 Leftovers found."))
                .font(.headline)
            Spacer()
            if engine.refreshing {
                ProgressView().controlSize(.small)
            } else {
                Button { engine.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Check again")
            }
        }
    }

    private func card(_ group: FindingGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.story)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if group.hot {
                    Text("🔥 \(String(format: "%.0f", group.totalCPU))% of a CPU core")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("💤 idle, holding memory")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(group.count > 1 ? "Close all \(group.count)" : "Close it") {
                    engine.close(group)
                }
                .buttonStyle(.borderedProminent)
                .tint(group.hot ? .orange : .accentColor)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private func banner(_ text: String, color: Color = .orange) -> some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.15)))
    }

    private var footer: some View {
        HStack {
            Toggle("Start at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.callout)
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.callout)
        }
    }
}

@main
struct MachogsApp: App {
    @StateObject private var engine = Engine()

    var body: some Scene {
        MenuBarExtra {
            ContentView(engine: engine)
        } label: {
            // The whole app in one glyph: pig = fine, fire = something's cooking.
            // The label is on screen from launch, so it also boots the engine.
            Text(engine.hot ? "🔥" : "🐷")
                .onAppear { engine.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
