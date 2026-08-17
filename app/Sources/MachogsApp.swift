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
    // Stable identity across polls: the story text mutates as ages tick
    // ("idle 49 minutes" → "50 minutes"), so anything that must recognize
    // "the same hog as last poll" — the watchdog, close-by-key — uses this.
    var key: String {
        guard let m = members.first else { return story }
        return "\(m.section)|\(m.what)|\(m.owner)"
    }
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
    @Published var clearingPath: String?   // disk item being cleared right now
    @Published var celebrate = 0   // bumping this fires the confetti cannon
    @Published var bust: BustEvent?          // what the Caught-in-4K window shows
    @Published var bustPending: BustEvent?   // caught, not yet seen: 📸 icon + popover banner

    let watchdog = Watchdog()
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
        watchdog.attach(self)
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
                    self.watchdog.evaluate(report: report, groups: self.groups)
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

    // Clear one safe disk item. The engine re-checks the path against its own
    // safe list and refuses anything else, so the app can't be talked into
    // deleting something that matters.
    func clearDisk(_ item: DiskItem) {
        guard item.verdict == "safe", clearingPath == nil else { return }
        clearingPath = item.path
        struct ClearResult: Codable { let mode: String; let label: String; let freed_mb: Int }
        Task.detached(priority: .userInitiated) {
            let result = Self.runJSON(["disk", "clear", item.path, "--json"], as: ClearResult.self)
            await MainActor.run {
                self.clearingPath = nil
                switch result {
                case .success(let r):
                    let text = r.freed_mb >= 1024
                        ? String(format: "💾 Cleared %@ — got back %.1f GB.", item.label, Double(r.freed_mb) / 1024)
                        : "💾 Cleared \(item.label) — got back \(r.freed_mb) MB."
                    Sfx.win()
                    self.celebrate += 1
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { self.receipt = text }
                    self.checkDisk()
                case .failure(let e):
                    self.errorText = e.message
                }
            }
        }
    }

    // The one fix for exhausted swap. The UI double-confirms before this runs.
    func restartMac() {
        NSAppleScript(source: "tell application \"System Events\" to restart")?
            .executeAndReturnError(nil)
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

    // One close path for everything — popover cards, "Close everything", the
    // Caught-in-4K window, and the notification's Close button. Only pids the
    // engine marked closable ever reach the kill(); returns the receipt text.
    @discardableResult
    func closeMatching(_ keys: Set<String>) -> String? {
        let targets = groups.filter { keys.contains($0.key) }
        guard !targets.isEmpty else { return nil }
        var closed = 0
        var freedCPU = 0.0
        var freedSecs = 0
        for g in targets {
            for f in g.members where f.closable {
                if kill(pid_t(f.pid), SIGKILL) == 0 {
                    closed += 1
                    freedCPU += f.cpu
                    freedSecs += f.cpu_seconds
                    Self.log(f)
                }
            }
        }
        guard closed > 0 else { return nil }
        let sweptAll = targets.count == groups.count && closed > 1
        var lines = [sweptAll ? "🎉 Closed all \(closed) of them."
                              : "🎉 Closed \(closed) program\(closed == 1 ? "" : "s")."]
        let cores = freedCPU / 100
        if cores >= 0.2 { lines.append("Got back \(String(format: "%.1f", cores)) of a CPU core.") }
        let charges = freedSecs / 9000  // ~6W core, ~15Wh phone battery
        if charges >= 2 { lines.append("⚡ The wasted power ≈ \(charges) phone charges.") }
        let text = lines.joined(separator: " ")
        Sfx.pop()
        celebrate += 1
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            receipt = text
            groups.removeAll { keys.contains($0.key) }
        }
        pruneBustPending()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
        return text
    }

    func close(_ group: FindingGroup) { closeMatching([group.key]) }
    func closeAll() { closeMatching(Set(groups.map(\.key))) }

    // A pending catch whose groups are all gone has resolved itself — stop
    // showing 📸 for a mess that no longer exists.
    func pruneBustPending() {
        guard let bp = bustPending else { return }
        if !groups.contains(where: { bp.keys.contains($0.key) }) { bustPending = nil }
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

// Gradient action pill — the only kind of "do something" button in the app.
// File-scope so the popover and the Caught-in-4K window share one look.
func pill(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
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
func ghost(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
    .buttonStyle(Squish())
}

func chip(_ text: String, _ color: Color) -> some View {
    // .secondary-on-.secondary is unreadably low-contrast; muted tags get
    // primary-based ink instead.
    let muted = color == .secondary
    return Text(text)
        .font(.system(.caption2, design: .rounded).weight(.semibold))
        .foregroundStyle(muted ? Color.primary.opacity(0.65) : color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(muted ? Color.primary.opacity(0.08) : color.opacity(0.12)))
}

// One hog group as a card — story, heat tag, close pill. Shared by the
// popover list and the Caught-in-4K window so a hog looks the same everywhere.
struct HogCard: View {
    let group: FindingGroup
    let close: () -> Void

    var body: some View {
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
                        chip("🔥 \(String(format: "%.0f", group.totalCPU))% of a core", .orange)
                    } else {
                        chip("💤 idle, holding memory", .secondary)
                    }
                    Spacer()
                    pill(group.count > 1 ? "Close all \(group.count) 💥" : "Close it 💥",
                         tint: group.hot ? .orange : .pink,
                         action: close)
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
}

// A two-step action: first tap arms it ("sure?"), second tap fires. Arms
// disarm themselves after a beat so a stray click never commits anything.
struct ArmedPill: View {
    let idle: String
    let armedTitle: String
    let tint: Color
    let fire: () -> Void
    @State private var armed = false

    var body: some View {
        pill(armed ? armedTitle : idle, tint: armed ? .red : tint) {
            if armed {
                armed = false
                fire()
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { armed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { armed = false }
                }
            }
        }
    }
}

// The one problem closing programs cannot fix. Says why in plain words and
// offers the actual fix, double-confirmed. Shared by popover and Receipts.
struct SwapCard: View {
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("🌡️").font(.system(size: 20))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Out of fast memory.")
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                    Text("\(engine.report?.host.uptime_days ?? 0) days since the last restart")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                ArmedPill(idle: "Restart now ⏻", armedTitle: "Sure? Everything closes ⏻",
                          tint: .indigo) { engine.restartMac() }
            }
            Text("Your Mac's fast memory is full, so it is shuffling work to the much slower disk — a desk so buried you're working out of boxes on the floor. That's the slowness you feel, and closing apps barely helps. A restart clears the desk; nothing else does.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(red: 0.72, green: 0.48, blue: 0.10),
                                              Color(red: 0.55, green: 0.38, blue: 0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
        .shadow(color: Color(red: 0.72, green: 0.48, blue: 0.10).opacity(0.35), radius: 6, y: 2)
    }
}

// One listening port as a row. Shared by the popover and the Receipts window.
struct PortRow: View {
    let item: PortItem
    let free: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(":\(String(item.port))")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.16)))
                    .foregroundStyle(tint)
                Text(item.process)
                    .font(.system(.callout, design: .rounded))
                    .lineLimit(1)
                Spacer()
                if item.killable {
                    pill("Free it ⚡", tint: .pink, action: free)
                } else if item.protected {
                    chip("your session", .green)
                } else {
                    chip("macOS", .secondary)
                }
            }
            Text(subtitle)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.leading, 2)
        }
    }

    private var tint: Color {
        if item.protected { return .green }
        if !item.killable { return .secondary }
        return .cyan
    }

    private var subtitle: String {
        if !item.note.isEmpty { return item.note }
        var bits: [String] = []
        if !item.owner.isEmpty { bits.append("started by \(item.owner)") }
        if !item.cwd.isEmpty && item.cwd != "/" { bits.append("in \(item.cwd)") }
        bits.append("running \(item.age)")
        return bits.joined(separator: " · ")
    }
}

// One junk spot as a row. Safe items get a real Clear button (armed, two-tap);
// everything else keeps Show-in-Finder only — same promise as the CLI.
struct DiskRow: View {
    let item: DiskItem
    let clearing: Bool
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(item.icon) \(item.label)")
                    .font(.system(.callout, design: .rounded))
                Spacer()
                Text(item.sizeText)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                if clearing {
                    ProgressView().controlSize(.small)
                } else if item.verdict == "safe" {
                    ArmedPill(idle: "Clear it 🧨", armedTitle: "Really clear \(item.sizeText)? 💥",
                              tint: .teal, fire: clear)
                }
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
}

// The mascot is a drawn pig, not a font glyph, so it can act: it breathes,
// blinks on its own clock, perks its ears and blushes when the cursor
// arrives, and oinks with its snout when hovered or poked. When something is
// cooking the CPU it carries a small flame and glows hotter.
struct MascotPig: View {
    let hot: Bool
    let refreshing: Bool
    @State private var breathe = false
    @State private var blink = false
    @State private var hovering = false
    @State private var oink = false

    var body: some View {
        PigFace(blink: blink, hovering: hovering, oink: oink, hot: hot)
            .frame(width: 42, height: 42)
            .scaleEffect(x: breathe ? 1.015 : 0.985, y: breathe ? 0.985 : 1.015)
            .rotationEffect(.degrees(breathe ? 1.4 : -1.4))
            .animation(.spring(response: refreshing ? 0.34 : 1.8, dampingFraction: 0.82)
                .repeatForever(autoreverses: true),
                       value: breathe)
            .shadow(color: (hot ? Color.orange : Color.pink).opacity(0.28), radius: 7, y: 2)
            .onAppear { breathe = true }
            .task {
                // Blink on a lazy, slightly irregular clock — alive, not metronomic.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000_000...5_000_000_000))
                    withAnimation(.spring(response: 0.11, dampingFraction: 0.92)) { blink = true }
                    try? await Task.sleep(nanoseconds: 115_000_000)
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.72)) { blink = false }
                }
            }
            .onHover { h in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { hovering = h }
                if h { doOink() }
            }
            .onTapGesture { doOink() }
    }

    private func doOink() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.35)) { oink = true }
        Sfx.play("Pop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { oink = false }
        }
    }
}

// Compact rounded-triangle ear, designed to tuck into the top of the head.
private struct PigEarShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.width * 0.08, y: r.height * 0.92))
        p.addCurve(to: CGPoint(x: r.width * 0.37, y: r.height * 0.08),
                   control1: CGPoint(x: r.width * 0.10, y: r.height * 0.56),
                   control2: CGPoint(x: r.width * 0.16, y: r.height * 0.13))
        p.addCurve(to: CGPoint(x: r.width * 0.94, y: r.height * 0.88),
                   control1: CGPoint(x: r.width * 0.59, y: -r.height * 0.02),
                   control2: CGPoint(x: r.width * 0.91, y: r.height * 0.50))
        p.addCurve(to: CGPoint(x: r.width * 0.08, y: r.height * 0.92),
                   control1: CGPoint(x: r.width * 0.76, y: r.height),
                   control2: CGPoint(x: r.width * 0.28, y: r.height))
        return p
    }
}

// Apple's pig has small, high-set almond eyes rather than cartoon circles.
private struct PigEyeShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.midY),
                   control1: CGPoint(x: r.minX + r.width * 0.28, y: r.minY),
                   control2: CGPoint(x: r.maxX - r.width * 0.28, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.midY),
                   control1: CGPoint(x: r.maxX - r.width * 0.28, y: r.maxY),
                   control2: CGPoint(x: r.minX + r.width * 0.28, y: r.maxY))
        return p
    }
}

private struct PigSmileShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.height * 0.18))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.height * 0.18),
                   control1: CGPoint(x: r.width * 0.24, y: r.height * 0.92),
                   control2: CGPoint(x: r.width * 0.76, y: r.height * 0.92))
        return p
    }
}

private struct PigFlameShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX + r.width * 0.12, y: r.height * 0.58),
                   control1: CGPoint(x: r.width * 0.22, y: r.maxY),
                   control2: CGPoint(x: r.minX, y: r.height * 0.78))
        p.addCurve(to: CGPoint(x: r.width * 0.46, y: r.minY),
                   control1: CGPoint(x: r.width * 0.26, y: r.height * 0.38),
                   control2: CGPoint(x: r.width * 0.42, y: r.height * 0.24))
        p.addCurve(to: CGPoint(x: r.maxX - r.width * 0.08, y: r.height * 0.54),
                   control1: CGPoint(x: r.width * 0.74, y: r.height * 0.20),
                   control2: CGPoint(x: r.maxX, y: r.height * 0.34))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.height * 0.78),
                   control2: CGPoint(x: r.width * 0.78, y: r.maxY))
        return p
    }
}

// Every measurement is proportional, so the same designed face stays crisp in
// the 42pt header and at the larger size used by Receipts.
struct PigFace: View {
    let blink: Bool
    let hovering: Bool
    let oink: Bool
    let hot: Bool

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                ear(s: s)
                    .rotationEffect(.degrees(hovering ? -3 : -12), anchor: .bottomTrailing)
                    .offset(x: -s * 0.205, y: -s * 0.305)
                ear(s: s)
                    .scaleEffect(x: -1)
                    .rotationEffect(.degrees(hovering ? 3 : 12), anchor: .bottomLeading)
                    .offset(x: s * 0.205, y: -s * 0.305)

                Ellipse()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.969, green: 0.780, blue: 0.745),
                                 Color(red: 0.937, green: 0.659, blue: 0.627)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.92, height: s * 0.84)
                    .overlay(
                        Ellipse()
                            .fill(LinearGradient(colors: [.clear,
                                                          Color(red: 0.68, green: 0.30, blue: 0.28).opacity(0.16)],
                                                 startPoint: .center, endPoint: .bottom))
                            .frame(width: s * 0.92, height: s * 0.84)
                    )
                    .overlay(
                        Ellipse()
                            .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.96, blue: 0.87).opacity(0.55),
                                                          .white.opacity(0)],
                                                 center: UnitPoint(x: 0.38, y: 0.12),
                                                 startRadius: 0, endRadius: s * 0.37))
                            .frame(width: s * 0.78, height: s * 0.56)
                            .offset(x: -s * 0.045, y: -s * 0.095)
                    )
                    .shadow(color: Color(red: 0.46, green: 0.20, blue: 0.18).opacity(0.20),
                            radius: s * 0.05, y: s * 0.038)
                    .offset(y: s * 0.06)

                Group {
                    blush(s: s).offset(x: -s * 0.315, y: s * 0.115)
                    blush(s: s).offset(x: s * 0.315, y: s * 0.115)
                }
                .opacity(hovering ? 0.78 : 0)
                .scaleEffect(hovering ? 1 : 0.2)

                Group {
                    eye(s: s).offset(x: -s * 0.125, y: -s * 0.035)
                    eye(s: s).offset(x: s * 0.125, y: -s * 0.035)
                }

                PigSmileShape()
                    .stroke(Color(red: 0.48, green: 0.20, blue: 0.19).opacity(0.60),
                            style: StrokeStyle(lineWidth: max(0.7, s * 0.018), lineCap: .round))
                    .frame(width: s * 0.18, height: s * 0.075)
                    .offset(y: s * 0.355)

                // This soft shadow is the contact point that makes the snout
                // read as a raised muzzle rather than a sticker.
                Capsule()
                    .fill(Color(red: 0.45, green: 0.18, blue: 0.19).opacity(0.17))
                    .frame(width: s * 0.44, height: s * 0.27)
                    .blur(radius: s * 0.035)
                    .offset(y: s * 0.225)
                    .scaleEffect(oink ? 1.25 : (hovering ? 1.06 : 1))

                snout(s: s)
                    .offset(y: s * 0.19)
                    .scaleEffect(oink ? 1.27 : (hovering ? 1.055 : 1))

                if hot {
                    flameBadge(s: s)
                        .offset(x: s * 0.34, y: -s * 0.31)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .frame(width: s, height: s)
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.spring(response: 0.30, dampingFraction: 0.64), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.48), value: oink)
            .animation(.spring(response: 0.36, dampingFraction: 0.78), value: hot)
            .compositingGroup()
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func ear(s: CGFloat) -> some View {
        ZStack {
            PigEarShape()
                .fill(LinearGradient(colors: [Color(red: 0.97, green: 0.75, blue: 0.72),
                                               Color(red: 0.88, green: 0.51, blue: 0.51)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            PigEarShape()
                .fill(Color(red: 0.70, green: 0.29, blue: 0.34).opacity(0.62))
                .scaleEffect(x: 0.54, y: 0.59, anchor: UnitPoint.bottom)
                .offset(y: s * 0.012)
        }
        .frame(width: s * 0.25, height: s * 0.30)
        .shadow(color: Color.black.opacity(0.12), radius: s * 0.022, y: s * 0.015)
    }

    private func eye(s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            PigEyeShape()
                .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.16, blue: 0.13),
                                               Color(red: 0.12, green: 0.055, blue: 0.045)],
                                     startPoint: .top, endPoint: .bottom))
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: s * 0.024, height: s * 0.024)
                .offset(x: s * 0.016, y: s * 0.014)
        }
        .frame(width: s * (hovering ? 0.098 : 0.092),
               height: s * (hovering ? 0.155 : 0.145))
        .scaleEffect(y: blink ? 0.08 : 1, anchor: .center)
    }

    private func blush(s: CGFloat) -> some View {
        Ellipse()
            .fill(RadialGradient(colors: [Color(red: 0.88, green: 0.32, blue: 0.38).opacity(0.58),
                                          Color(red: 0.88, green: 0.32, blue: 0.38).opacity(0)],
                                 center: .center, startRadius: 0, endRadius: s * 0.10))
            .frame(width: s * 0.20, height: s * 0.115)
    }

    private func snout(s: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 0.99, green: 0.72, blue: 0.72),
                                               Color(red: 0.91, green: 0.49, blue: 0.53)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    Capsule()
                        .stroke(LinearGradient(colors: [Color(red: 1.0, green: 0.94, blue: 0.87).opacity(0.70),
                                                        .white.opacity(0.04)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: max(0.6, s * 0.016))
                )
                .shadow(color: Color(red: 0.50, green: 0.16, blue: 0.18).opacity(0.22),
                        radius: s * 0.025, y: s * 0.018)
            HStack(spacing: s * 0.115) {
                nostril(s: s)
                nostril(s: s)
            }
        }
        .frame(width: s * 0.44, height: s * 0.27)
    }

    private func nostril(s: CGFloat) -> some View {
        Ellipse()
            .fill(LinearGradient(colors: [Color(red: 0.38, green: 0.15, blue: 0.16),
                                          Color(red: 0.56, green: 0.22, blue: 0.24)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: s * 0.068, height: s * 0.112)
            .overlay(Ellipse().stroke(Color.white.opacity(0.10), lineWidth: s * 0.008))
    }

    private func flameBadge(s: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.white, Color(red: 1.0, green: 0.82, blue: 0.67)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Color.orange.opacity(0.42), radius: s * 0.045, y: s * 0.018)
            PigFlameShape()
                .fill(LinearGradient(colors: [.yellow, .orange, .red],
                                     startPoint: .bottom, endPoint: .top))
                .padding(s * 0.055)
        }
        .frame(width: s * 0.29, height: s * 0.29)
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
    @AppStorage("watchdogOn") private var watchdogOn = true
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                header
                    .reveal(appeared, delay: 0)
                if let err = engine.errorText {
                    banner(err, colors: [.red.opacity(0.9), .red])
                }
                // The watchdog caught something while the popover was closed.
                if let bp = engine.bustPending {
                    Button {
                        engine.bust = bp
                        engine.bustPending = nil
                        openWindow(id: "bust")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        banner("📸 \(bp.headline) — tap to see the catch.",
                               colors: [.orange, .pink])
                    }
                    .buttonStyle(Squish())
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                if engine.swapTrouble {
                    SwapCard(engine: engine)
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
            // Ports answer in well under a second — load them so opening the
            // popover already shows who is squatting what.
            if engine.portsReport == nil { engine.checkPorts() }
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
                    HogCard(group: group) { engine.close(group) }
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .scale(scale: 0.8).combined(with: .opacity)))
                }
            }
        }
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
                // A plain bounded list, killable ports first. (A ScrollView
                // collapses to zero height in this self-sizing popover.)
                let ranked = p.ports.sorted {
                    ($0.killable ? 0 : $0.protected ? 1 : 2, $0.port)
                        < ($1.killable ? 0 : $1.protected ? 1 : 2, $1.port)
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(ranked.prefix(7)) { item in
                        PortRow(item: item) { engine.freePort(item) }
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                }
                if p.ports.count > 7 {
                    Text("+ \(p.ports.count - 7) more — the Receipts window 📜 lists them all")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            } else if !engine.portsLoading {
                Text("\"Port already in use\"? Find out who is squatting it.")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
            }
        }
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
                    DiskRow(item: item,
                            clearing: engine.clearingPath == item.path,
                            clear: { engine.clearDisk(item) })
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .move(edge: .trailing).combined(with: .opacity)))
                }
                Text("Rebuildable caches get a Clear button. Everything else: it points; you decide.")
                    .font(.system(.caption2, design: .rounded)).foregroundStyle(.tertiary)
            } else if !engine.diskLoading {
                Text("Where did your storage go? Takes ~15 seconds.")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
            }
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
            Button {
                watchdogOn.toggle()
                if watchdogOn { Sfx.pop() }
            } label: {
                Image(systemName: watchdogOn ? "bell.fill" : "bell.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(Squish())
            .help(watchdogOn
                  ? "Shoulder taps on — a ping when something starts cooking your CPU or an AI session leaves a mess"
                  : "Shoulder taps off — machogs stays quiet until you open it")
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
            // The whole app in one glyph: pig = fine, fire = something's
            // cooking, camera = the watchdog caught something you haven't seen.
            // The label is on screen from launch, so it also boots the engine.
            Text(engine.bustPending != nil ? "📸" : engine.hot ? "🔥" : "🐷")
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

        // `machogs://bust` lands here — the reveal for a watchdog catch, opened
        // by the notification click or the popover banner.
        Window("Caught in 4K", id: "bust") {
            BustView(engine: engine)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["bust"])
    }
}
