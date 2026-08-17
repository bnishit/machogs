// Machogs.app — the pig in your menu bar.
//
// A thin SwiftUI shell over the machogs bash engine. The engine does all the
// finding and all the safety reasoning; the app only renders its JSON and, on
// an explicit click, closes the pids the engine already vetted as reapable.
// It never invents its own verdicts and never touches a pid the engine
// marked protected or never-killed.

import SwiftUI
import AppKit
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

// `machogs disk --json` — the storage X-ray. Report-only; nothing is deleted.
struct DiskInfo: Codable {
    let used_gb: Int
    let total_gb: Int
    let pct: Int
}

struct DiskItem: Codable, Identifiable {
    let label: String
    let icon: String
    let path: String
    let size_mb: Int
    let verdict: String
    let how: String
    var id: String { path }

    var sizeText: String {
        if size_mb >= 10240 { return "\(size_mb / 1024) GB" }
        if size_mb >= 1024 { return String(format: "%.1f GB", Double(size_mb) / 1024) }
        return "\(size_mb) MB"
    }
    var verdictText: String {
        switch verdict {
        case "safe": return "Safe to clear:"
        case "check": return "Check first:"
        default: return "Your call:"
        }
    }
    var verdictColor: Color {
        switch verdict {
        case "safe": return .green
        case "check": return .orange
        default: return .blue
        }
    }
}

struct DiskReport: Codable {
    let mode: String
    let disk: DiskInfo
    let items: [DiskItem]
}

// `machogs ports --json` — who is squatting which port.
struct PortItem: Codable, Identifiable {
    let port: Int
    let pid: Int
    let process: String
    let owner: String
    let cwd: String
    let age: String
    let system: Bool
    let protected: Bool
    let note: String
    var id: String { "\(port):\(pid)" }
    // System daemons and launchd-resurrected squatters aren't worth killing;
    // protected pids belong to a live coding session.
    var killable: Bool { !system && !protected && note.isEmpty }
}

struct PortsReport: Codable {
    let mode: String
    let ports: [PortItem]
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

// MARK: - Juice (sound + haptics)

enum Sfx {
    static var on: Bool {
        UserDefaults.standard.object(forKey: "soundOn") == nil
            || UserDefaults.standard.bool(forKey: "soundOn")
    }
    // System sounds ship with macOS, so the app stays asset-free.
    static func pop()  { play("Pop") }
    static func win()  { play("Glass") }
    static func play(_ name: String) {
        guard on else { return }
        NSSound(named: name)?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

// MARK: - Engine wrapper

@MainActor
final class Engine: ObservableObject {
    @Published var report: Report?
    @Published var groups: [FindingGroup] = []
    @Published var receipt: String?
    @Published var errorText: String?
    @Published var refreshing = false
    @Published var diskReport: DiskReport?
    @Published var diskLoading = false
    @Published var portsReport: PortsReport?
    @Published var portsLoading = false
    @Published var celebrate = 0   // bumping this fires the confetti cannon

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
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        self.groups = Dictionary(grouping: closable, by: { $0.story })
                            .map { FindingGroup(story: $0.key, members: $0.value) }
                            .sorted { $0.totalCPU > $1.totalCPU }
                    }
                case .failure(let err):
                    self.errorText = err.message
                }
            }
        }
    }

    struct EngineError: Error { let message: String }

    // One runner for every engine mode: exit 10 means "findings exist", not failure.
    nonisolated private static func runJSON<T: Decodable>(_ args: [String], as type: T.Type) -> Result<T, EngineError> {
        guard let script = scriptPath() else {
            return .failure(EngineError(message: "Can't find the machogs engine. Reinstall the app or `brew install bnishit/tap/machogs`."))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script] + args
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
        guard p.terminationStatus == 0 || p.terminationStatus == 10 else {
            return .failure(EngineError(message: "Engine exited with status \(p.terminationStatus)."))
        }
        do {
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .failure(EngineError(message: "Couldn't read the engine's report."))
        }
    }

    nonisolated private static func runEngine() -> Result<Report, EngineError> {
        runJSON(["--json", "--sessions"], as: Report.self)
    }

    func checkDisk() {
        guard !diskLoading else { return }
        diskLoading = true
        Task.detached(priority: .utility) {
            let result = Self.runJSON(["disk", "--json"], as: DiskReport.self)
            await MainActor.run {
                self.diskLoading = false
                switch result {
                case .success(let d):
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { self.diskReport = d }
                case .failure(let e): self.errorText = e.message
                }
            }
        }
    }

    func checkPorts() {
        guard !portsLoading else { return }
        portsLoading = true
        Task.detached(priority: .utility) {
            let result = Self.runJSON(["ports", "--json"], as: PortsReport.self)
            await MainActor.run {
                self.portsLoading = false
                switch result {
                case .success(let p):
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { self.portsReport = p }
                case .failure(let e): self.errorText = e.message
                }
            }
        }
    }

    func freePort(_ item: PortItem) {
        guard item.killable else { return }
        if kill(pid_t(item.pid), SIGKILL) == 0 {
            Sfx.pop()
            celebrate += 1
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                receipt = "🔌 Port \(item.port) is free. Go run your thing."
                if let p = portsReport {
                    portsReport = PortsReport(mode: p.mode, ports: p.ports.filter { $0.id != item.id })
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.checkPorts() }
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
        Sfx.pop()
        celebrate += 1
        var lines = ["🎉 Closed \(closed) program\(closed == 1 ? "" : "s")."]
        let cores = freedCPU / 100
        if cores >= 0.2 { lines.append("Got back \(String(format: "%.1f", cores)) of a CPU core.") }
        let charges = freedSecs / 9000  // ~6W core, ~15Wh phone battery
        if charges >= 2 { lines.append("⚡ The wasted power ≈ \(charges) phone charges.") }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            receipt = lines.joined(separator: " ")
            groups.removeAll { $0.id == group.id }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
    }

    // The whole list in one go: one kill sweep, one receipt, one confetti payoff.
    func closeAll() {
        var closed = 0
        var freedCPU = 0.0
        var freedSecs = 0
        for g in groups {
            for f in g.members where f.closable {
                if kill(pid_t(f.pid), SIGKILL) == 0 {
                    closed += 1
                    freedCPU += f.cpu
                    freedSecs += f.cpu_seconds
                    Self.log(f)
                }
            }
        }
        guard closed > 0 else { return }
        Sfx.pop()
        celebrate += 1
        var lines = ["🎉 Closed all \(closed) of them."]
        let cores = freedCPU / 100
        if cores >= 0.2 { lines.append("Got back \(String(format: "%.1f", cores)) of a CPU core.") }
        let charges = freedSecs / 9000
        if charges >= 2 { lines.append("⚡ The wasted power ≈ \(charges) phone charges.") }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            receipt = lines.joined(separator: " ")
            groups.removeAll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
    }

    // Run `machogs brag` and put the card on the clipboard, ready to paste.
    func copyBrag() {
        Task.detached(priority: .userInitiated) {
            guard let script = Self.scriptPath() else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script, "brag"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                Sfx.pop()
                self.celebrate += 1
            }
        }
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

// MARK: - Reusable juice

// Buttons squish like something physical. Every tappable thing uses this.
struct Squish: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

// Cards lift toward the cursor.
struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: .black.opacity(hovering ? 0.16 : 0.05),
                    radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
            .onHover { h in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h }
            }
    }
}

// The mascot idles with a slow breath; while scanning it gets excited.
struct MascotPig: View {
    let hot: Bool
    let refreshing: Bool
    @State private var breathe = false
    var body: some View {
        Text(hot ? "🔥" : "🐷")
            .font(.system(size: 36))
            .scaleEffect(breathe ? 1.07 : 0.96)
            .rotationEffect(.degrees(breathe ? 4 : -4))
            .animation(.easeInOut(duration: refreshing ? 0.3 : 1.8).repeatForever(autoreverses: true),
                       value: breathe)
            .shadow(color: (hot ? Color.orange : Color.pink).opacity(0.5), radius: 10)
            .onAppear { breathe = true }
    }
}

// Emoji confetti cannon, drawn on a Canvas so 30 particles cost nothing.
struct ConfettiBurst: View {
    let trigger: Int

    struct P {
        let emoji: String
        let x: CGFloat
        let vx: CGFloat
        let vy: CGFloat
        let size: CGFloat
        let delay: Double
    }

    @State private var particles: [P] = []
    @State private var start: Date?
    @State private var active = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { timeline in
            Canvas { ctx, size in
                guard let start else { return }
                let t = timeline.date.timeIntervalSince(start)
                for p in particles {
                    let pt = t - p.delay
                    guard pt > 0, pt < 1.4 else { continue }
                    let x = size.width * p.x + p.vx * pt
                    let y = size.height * 0.22 + p.vy * pt + 520 * pt * pt
                    ctx.opacity = max(0, 1.25 - pt)
                    ctx.draw(ctx.resolve(Text(p.emoji).font(.system(size: p.size))),
                             at: CGPoint(x: x, y: y))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { fired in
            guard fired > 0 else { return }
            let emojis = ["🎉", "✨", "⚡", "💥", "🐷"]
            particles = (0..<30).map { _ in
                P(emoji: emojis.randomElement() ?? "🎉",
                  x: CGFloat.random(in: 0.3...0.7),
                  vx: CGFloat.random(in: -240...240),
                  vy: CGFloat.random(in: -460 ... -180),
                  size: CGFloat.random(in: 13...26),
                  delay: Double.random(in: 0...0.12))
            }
            start = Date()
            active = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { active = false }
        }
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
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(0.15)) { shown = true }
        }
    }
}

// MARK: - UI

struct ContentView: View {
    @ObservedObject var engine: Engine
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("soundOn") private var soundOn = true
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                header
                    .reveal(appeared, delay: 0)
                if let err = engine.errorText {
                    banner(err, colors: [.red.opacity(0.9), .red])
                }
                if engine.swapTrouble {
                    banner("🌡️ Your Mac is out of fast memory after \(engine.report?.host.uptime_days ?? 0) days on. Closing programs won't fix that part — restart when you can.",
                           colors: [Color(red: 0.72, green: 0.48, blue: 0.10), Color(red: 0.55, green: 0.38, blue: 0.12)])
                }
                if let receipt = engine.receipt {
                    banner(receipt, colors: [.green, .teal])
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                hogs
                    .reveal(appeared, delay: 0.05)
                sectionBox { ports }
                    .reveal(appeared, delay: 0.1)
                sectionBox { storage }
                    .reveal(appeared, delay: 0.15)
                footer
                    .reveal(appeared, delay: 0.2)
            }
            .padding(14)

            ConfettiBurst(trigger: engine.celebrate)
        }
        .frame(width: 400)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: engine.receipt)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            MascotPig(hot: engine.hot, refreshing: engine.refreshing)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text(subline)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(engine.clean ? Color.green : Color.orange)
            }
            Spacer()
            Button {
                openWindow(id: "story")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("📜")
                    .font(.system(size: 13))
                    .padding(7)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(Squish())
            .modifier(HoverLift())
            .help("The Receipts — your Mac's full scoreboard")
            Button {
                engine.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .rotationEffect(.degrees(engine.refreshing ? 360 : 0))
                    .animation(engine.refreshing
                               ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                               : .default,
                               value: engine.refreshing)
                    .padding(8)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(Squish())
            .modifier(HoverLift())
            .help("Check again")
        }
    }

    private var headline: String {
        if engine.hot { return "Found the hog." }
        if engine.clean { return "machogs" }
        return "Leftovers found."
    }

    private var subline: String {
        if engine.refreshing { return "sniffing around…" }
        if engine.hot { return "something is cooking your CPU" }
        if engine.clean { return "all clear — your Mac is vibing ✨" }
        return "idle junk holding memory"
    }

    // MARK: hogs

    @ViewBuilder
    private var hogs: some View {
        if engine.clean && engine.errorText == nil {
            HStack(spacing: 10) {
                Text("✨")
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing is hogging your Mac.")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                    Text("No stuck or abandoned programs anywhere.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color.green.opacity(0.12), Color.teal.opacity(0.10)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
            )
        } else {
            VStack(spacing: 8) {
                if engine.groups.count > 1 {
                    HStack {
                        Text("\(engine.groups.reduce(0) { $0 + $1.count }) things worth closing")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        pill("Close everything 🧹", tint: .pink) { engine.closeAll() }
                    }
                    .padding(.horizontal, 2)
                }
                ForEach(engine.groups) { group in
                    card(group)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .scale(scale: 0.8).combined(with: .opacity)))
                }
            }
        }
    }

    private func card(_ group: FindingGroup) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // A glyph avatar per card, rhyming with the mascot: circle + glow.
            Image(systemName: group.hot ? "flame.fill" : "moon.zzz.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(group.hot ? Color.orange : Color.pink)
                .frame(width: 26, height: 26)
                .background(Circle().fill((group.hot ? Color.orange : Color.pink).opacity(0.15)))
            VStack(alignment: .leading, spacing: 8) {
                Text(group.story)
                    .font(.system(.callout, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if group.hot {
                        tag("🔥 \(String(format: "%.0f", group.totalCPU))% of a core", .orange)
                    } else {
                        tag("💤 idle, holding memory", .secondary)
                    }
                    Spacer()
                    pill(group.count > 1 ? "Close all \(group.count) 💥" : "Close it 💥",
                         tint: group.hot ? .orange : .pink) {
                        engine.close(group)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    group.hot
                    ? AnyShapeStyle(LinearGradient(colors: [.orange, .red.opacity(0.6)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color.primary.opacity(0.08)),
                    lineWidth: 1)
        )
        .modifier(HoverLift())
    }

    // MARK: ports

    private var ports: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("🔌", "Ports", tint: .cyan)
                Spacer()
                if engine.portsLoading {
                    ProgressView().controlSize(.small)
                } else {
                    ghost(engine.portsReport == nil ? "Check" : "Re-check") { engine.checkPorts() }
                }
            }
            if let p = engine.portsReport {
                if p.ports.isEmpty {
                    HStack(spacing: 6) {
                        Text("✅")
                        Text("Nothing is listening on any port.")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(p.ports) { item in
                            portRow(item)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 210)
            } else if !engine.portsLoading {
                Text("\"Port already in use\"? Find out who is squatting it.")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
            }
        }
    }

    private func portRow(_ item: PortItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(":\(String(item.port))")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(portTint(item).opacity(0.16)))
                    .foregroundStyle(portTint(item))
                Text(item.process)
                    .font(.system(.callout, design: .rounded))
                    .lineLimit(1)
                Spacer()
                if item.killable {
                    pill("Free it ⚡", tint: .pink) { engine.freePort(item) }
                } else if item.protected {
                    tag("your session", .green)
                } else {
                    tag("macOS", .secondary)
                }
            }
            Text(subtitle(for: item))
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.leading, 2)
        }
    }

    private func portTint(_ item: PortItem) -> Color {
        if item.protected { return .green }
        if !item.killable { return .secondary }
        return .cyan
    }

    private func subtitle(for item: PortItem) -> String {
        if !item.note.isEmpty { return item.note }
        var bits: [String] = []
        if !item.owner.isEmpty { bits.append("started by \(item.owner)") }
        if !item.cwd.isEmpty && item.cwd != "/" { bits.append("in \(item.cwd)") }
        bits.append("running \(item.age)")
        return bits.joined(separator: " · ")
    }

    // MARK: storage

    private var storage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("💾", "Storage", tint: .teal)
                Spacer()
                if engine.diskLoading {
                    ProgressView().controlSize(.small)
                } else {
                    ghost(engine.diskReport == nil ? "Check" : "Re-check") { engine.checkDisk() }
                }
            }
            if let d = engine.diskReport {
                VStack(alignment: .leading, spacing: 4) {
                    DiskGauge(pct: d.disk.pct)
                    Text("\(d.disk.used_gb) GB used of \(d.disk.total_gb) GB (\(d.disk.pct)% full)")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(d.disk.pct >= 90 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                if d.items.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text("✅")
                        Text("Nothing chunky in the usual junk spots — whatever fills your disk is your real files.")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                ForEach(d.items) { item in
                    diskRow(item)
                }
                Text("Nothing is deleted. It points; you decide.")
                    .font(.system(.caption2, design: .rounded)).foregroundStyle(.tertiary)
            } else if !engine.diskLoading {
                Text("Where did your storage go? Takes ~15 seconds.")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
            }
        }
    }

    private func diskRow(_ item: DiskItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(item.icon) \(item.label)")
                    .font(.system(.callout, design: .rounded))
                Spacer()
                Text(item.sizeText)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                ghost("Show") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                }
            }
            HStack(spacing: 4) {
                Text(item.verdictText)
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundStyle(item.verdictColor)
                Text(item.how)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: shared pieces

    private func sectionBox<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }

    private func sectionTitle(_ emoji: String, _ title: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Text(emoji)
                .font(.system(size: 13))
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint.opacity(0.14)))
            Text(title).font(.system(.subheadline, design: .rounded).weight(.bold))
        }
    }

    // Gradient action pill — the only kind of "do something" button in the app.
    private func pill(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    Capsule().fill(LinearGradient(colors: [tint, tint.opacity(0.7)],
                                                  startPoint: .top, endPoint: .bottom))
                )
                .shadow(color: tint.opacity(0.45), radius: 4, y: 1)
        }
        .buttonStyle(Squish())
    }

    // Quiet secondary button.
    private func ghost(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(Squish())
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        // .secondary-on-.secondary is unreadably low-contrast; muted tags get
        // primary-based ink instead.
        let muted = color == .secondary
        return Text(text)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(muted ? Color.primary.opacity(0.65) : color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(muted ? Color.primary.opacity(0.08) : color.opacity(0.12)))
    }

    private func banner(_ text: String, colors: [Color]) -> some View {
        Text(text)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: colors.map { $0.opacity(0.9) },
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .shadow(color: (colors.first ?? .clear).opacity(0.35), radius: 6, y: 2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Start at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(.caption, design: .rounded))
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Button {
                soundOn.toggle()
                if soundOn { Sfx.pop() }
            } label: {
                Image(systemName: soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(Squish())
            .help(soundOn ? "Sounds on" : "Sounds off")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(Squish())
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

// Staggered entrance: each section fades in a beat after the one above it.
extension View {
    func reveal(_ appeared: Bool, delay: Double) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(delay), value: appeared)
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

        // `open machogs://receipts` lands here — the popover button, agents,
        // and the CLI can all summon the scoreboard.
        Window("The Receipts", id: "story") {
            StoryView(engine: engine)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 660, height: 640)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["receipts"])
    }
}
