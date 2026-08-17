// The Machogs window — a real macOS app, not a feed.
//
// A sidebar of places, one purpose per screen:
//   Now       — is my Mac okay, and what needs closing this minute
//   Ports     — every listening port, grouped by what you may do about it
//   Storage   — where the disk went, with safe caches clearable in place
//   Receipts  — the scoreboard: totals, Hall of Shame, two-week chart, brag
//   Settings  — the switches, plus a preview of the island for the curious
//
// The popover stays the 10-second surface; this is the app. It opens via
// `open machogs://receipts` or 📜 in the popover.

import SwiftUI
import AppKit
import Charts
import ServiceManagement

// MARK: - Log parsing (the receipts data)

struct CloseEvent {
    let date: Date
    let owner: String
    let what: String
    let cpu: Double
    let cpuSeconds: Int
}

struct AppScore: Identifiable {
    let owner: String
    let closes: Int
    let cpuSeconds: Int
    var id: String { owner }
}

struct DayCount: Identifiable {
    let day: Date
    let label: String
    let count: Int
    var id: Date { day }
}

struct Story {
    let events: [CloseEvent]
    let since: Date?
    let byApp: [AppScore]
    let days: [DayCount]

    var totalCloses: Int { events.count }
    var totalCPUSeconds: Int { events.reduce(0) { $0 + $1.cpuSeconds } }
    var phoneCharges: Int { totalCPUSeconds / 9000 }

    static func load() -> Story {
        let path = NSString(string: "~/Library/Logs/machogs.log").expandingTildeInPath
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var events: [CloseEvent] = []
        if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in raw.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard f.count >= 7, f[1] == "closed", let d = fmt.date(from: String(f[0])) else { continue }
                events.append(CloseEvent(
                    date: d,
                    owner: String(f[3]),
                    what: String(f[4]),
                    cpu: Double(f[5]) ?? 0,
                    cpuSeconds: Int(Double(f[6]) ?? 0)))
            }
        }
        let byApp = Dictionary(grouping: events, by: { $0.owner })
            .map { AppScore(owner: $0.key,
                            closes: $0.value.count,
                            cpuSeconds: $0.value.reduce(0) { $0 + $1.cpuSeconds }) }
            .sorted { ($0.cpuSeconds, $0.closes) > ($1.cpuSeconds, $1.closes) }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "d MMM"
        let days: [DayCount] = (0..<14).reversed().compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            let count = events.filter { cal.isDate($0.date, inSameDayAs: day) }.count
            return DayCount(day: day, label: dayFmt.string(from: day), count: count)
        }
        return Story(events: events,
                     since: events.map(\.date).min(),
                     byApp: byApp,
                     days: days)
    }
}

// MARK: - Shared pieces

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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emoji).font(.system(size: 18))
            CountUp(value: shown ? value : 0, suffix: suffix)
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
        .modifier(HoverLift())
        .onAppear {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.9).delay(0.15)) { shown = true }
        }
    }
}

// A section slab — every page builds out of these.
struct Slab<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder let content: Content

    init(_ title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
            }
            if let caption {
                Text(caption)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - The window: sidebar + pages

enum AppPage: String, CaseIterable, Identifiable {
    case now, ports, storage, receipts, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .now: return "Now"
        case .ports: return "Ports"
        case .storage: return "Storage"
        case .receipts: return "The Receipts"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .now: return "gauge.with.needle"
        case .ports: return "cable.connector"
        case .storage: return "internaldrive"
        case .receipts: return "trophy"
        case .settings: return "gearshape"
        }
    }
}

struct StoryView: View {
    @ObservedObject var engine: Engine
    // Persisted so the popover doorways can open the window on a chosen page.
    @AppStorage("appPage") private var pageRaw = AppPage.now.rawValue
    @State private var story = Story.load()

    private var page: AppPage { AppPage(rawValue: pageRaw) ?? .now }
    private var pageSelection: Binding<AppPage> {
        Binding(get: { AppPage(rawValue: pageRaw) ?? .now },
                set: { pageRaw = $0.rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: pageSelection) {
                ForEach(AppPage.allCases) { p in
                    Label(p.label, systemImage: p.symbol)
                        .badge(badge(for: p))
                        .tag(p)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
            .safeAreaInset(edge: .bottom) {
                // The mascot lives at the bottom of the sidebar, being a pig.
                VStack(spacing: 4) {
                    MascotPig(hot: engine.hot, refreshing: engine.refreshing)
                    Text("machogs")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
            }
        } detail: {
            detailPage
                .navigationTitle(page.label)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            engine.refresh(); engine.checkPorts(); engine.checkDisk()
                            story = Story.load()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Check everything again")
                    }
                }
        }
        .frame(minWidth: 780, minHeight: 560)
        .overlay(ConfettiBurst(trigger: engine.celebrate))
        .onAppear {
            story = Story.load()
            if engine.portsReport == nil { engine.checkPorts() }
            if engine.diskReport == nil { engine.checkDisk() }
        }
        .onChange(of: engine.celebrate) { _ in story = Story.load() }
    }

    // Sidebar badges carry the "does anything need me?" answer.
    private func badge(for p: AppPage) -> Int {
        switch p {
        case .now: return engine.groups.reduce(0) { $0 + $1.count } + (engine.swapTrouble ? 1 : 0)
        case .ports: return engine.portsReport?.ports.filter(\.killable).count ?? 0
        case .storage: return engine.diskReport?.items.filter { $0.verdict == "safe" }.count ?? 0
        default: return 0
        }
    }

    @ViewBuilder
    private var detailPage: some View {
        switch page {
        case .now: NowPage(engine: engine)
        case .ports: PortsPage(engine: engine)
        case .storage: StoragePage(engine: engine)
        case .receipts: ReceiptsPage(engine: engine, story: story)
        case .settings: SettingsPage(engine: engine)
        }
    }
}

// MARK: - Now

struct NowPage: View {
    @ObservedObject var engine: Engine
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                verdict.reveal(appeared, delay: 0)
                vitals.reveal(appeared, delay: 0.04)

                if let receipt = engine.receipt {
                    Text(receipt)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .foregroundStyle(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: [.green.opacity(0.9), .teal.opacity(0.9)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }

                if engine.swapTrouble {
                    SwapCard(engine: engine).reveal(appeared, delay: 0.08)
                }

                hogs.reveal(appeared, delay: 0.12)
            }
            .padding(18)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: engine.receipt)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { appeared = true }
        }
    }

    // The one-line answer, biggest thing on the page.
    private var verdict: some View {
        HStack(spacing: 12) {
            Text(engine.hot ? "🔥" : engine.clean && !engine.swapTrouble ? "✨" : "🧹")
                .font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Text(subline)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var headline: String {
        if engine.hot { return "Found the hog." }
        if engine.swapTrouble { return "Out of fast memory." }
        if engine.clean { return "Your Mac is fine." }
        return "Leftovers found."
    }
    private var subline: String {
        if engine.hot { return "Something is cooking your CPU right now." }
        if engine.swapTrouble { return "Programs are fine — the memory is the problem. See below." }
        if engine.clean { return "Nothing stuck, nothing abandoned, nothing cooking." }
        return "Idle junk is holding memory. Close it whenever."
    }

    // The vitals strip: four numbers that say how the machine actually is.
    private var vitals: some View {
        HStack(spacing: 10) {
            vital("cpu", "CPU load",
                  value: String(format: "%.1f", engine.report?.host.load ?? 0),
                  detail: "of \(engine.report?.host.cores ?? 0) cores",
                  bad: (engine.report?.host.load ?? 0) > Double(engine.report?.host.cores ?? 1))
            vital("memorychip", "Fast memory",
                  value: "\(engine.report?.host.swap_pct ?? 0)%",
                  detail: "swap used",
                  bad: engine.swapTrouble)
            vital("clock", "Uptime",
                  value: "\(engine.report?.host.uptime_days ?? 0)d",
                  detail: "since restart",
                  bad: (engine.report?.host.uptime_days ?? 0) >= 14)
            vital("internaldrive", "Disk",
                  value: engine.diskReport.map { "\($0.disk.pct)%" } ?? "…",
                  detail: "full",
                  bad: (engine.diskReport?.disk.pct ?? 0) >= 90)
        }
    }

    private func vital(_ symbol: String, _ title: String, value: String, detail: String, bad: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(bad ? Color.orange : Color.secondary)
                Text(title)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(bad ? Color.orange : Color.primary)
                Text(detail)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(bad ? Color.orange.opacity(0.4) : Color.primary.opacity(0.07), lineWidth: 1))
    }

    @ViewBuilder
    private var hogs: some View {
        if engine.groups.isEmpty {
            Slab("", caption: nil) {
                HStack(spacing: 10) {
                    Text("✨").font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing worth closing.")
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .foregroundStyle(.green)
                        Text("No stuck or abandoned programs anywhere. The pig keeps watching.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(engine.groups.reduce(0) { $0 + $1.count }) thing\(engine.groups.reduce(0) { $0 + $1.count } == 1 ? "" : "s") worth closing")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                    Spacer()
                    if engine.groups.count > 1 {
                        pill("Close everything 🧹", tint: .pink) { engine.closeAll() }
                    }
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
}

// MARK: - Ports

struct PortsPage: View {
    @ObservedObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if engine.portsLoading && engine.portsReport == nil {
                    ProgressView("Checking every listening port…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else if let p = engine.portsReport {
                    if p.ports.isEmpty {
                        Slab("") {
                            Text("✅ Nothing is listening on any port.")
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    } else {
                        let killable = p.ports.filter(\.killable)
                        let sessions = p.ports.filter(\.protected)
                        let system = p.ports.filter { !$0.killable && !$0.protected }
                        if !killable.isEmpty {
                            Slab("Yours to free", caption: "Nothing here belongs to a live coding session — freeing one costs you nothing unsaved.") {
                                rows(killable)
                            }
                        }
                        if !sessions.isEmpty {
                            Slab("Your live sessions", caption: "These belong to coding sessions that are open right now. machogs never touches them.") {
                                rows(sessions)
                            }
                        }
                        if !system.isEmpty {
                            Slab("macOS and squatters", caption: "System daemons, and squatters that killing does not fix — machogs names them instead.") {
                                rows(system)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func rows(_ items: [PortItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                PortRow(item: item) { engine.freePort(item) }
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
    }
}

// MARK: - Storage

struct StoragePage: View {
    @ObservedObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if engine.diskLoading && engine.diskReport == nil {
                    ProgressView("Weighing the usual junk spots… takes ~15 seconds.")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else if let d = engine.diskReport {
                    Slab("") {
                        VStack(alignment: .leading, spacing: 6) {
                            DiskGauge(pct: d.disk.pct)
                            HStack {
                                Text("\(d.disk.used_gb) GB used of \(d.disk.total_gb) GB (\(d.disk.pct)% full)")
                                    .font(.system(.callout, design: .rounded).weight(.semibold))
                                    .foregroundStyle(d.disk.pct >= 90 ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                                Spacer()
                                let reclaimable = d.items.filter { $0.verdict == "safe" }.reduce(0) { $0 + $1.size_mb }
                                if reclaimable >= 512 {
                                    chip("~\(reclaimable >= 10240 ? "\(reclaimable / 1024) GB" : String(format: "%.1f GB", Double(reclaimable) / 1024)) safely clearable", .teal)
                                }
                            }
                        }
                    }
                    if d.items.isEmpty {
                        Slab("") {
                            Text("✅ Nothing chunky in the usual junk spots — whatever fills your disk is your real files.")
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    } else {
                        Slab("The junk spots", caption: "Rebuildable caches get a Clear button — two taps, and the engine refuses anything not on its own safe list. Everything else: it points, you decide.") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(d.items) { item in
                                    DiskRow(item: item,
                                            clearing: engine.clearingPath == item.path,
                                            clear: { engine.clearDisk(item) })
                                        .transition(.asymmetric(
                                            insertion: .opacity,
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
                                }
                            }
                        }
                    }
                    if let receipt = engine.receipt, receipt.hasPrefix("💾") {
                        Text(receipt)
                            .font(.system(.callout, design: .rounded).weight(.medium))
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(colors: [.green.opacity(0.9), .teal.opacity(0.9)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }
            .padding(18)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: engine.receipt)
    }
}

// MARK: - The Receipts (scoreboard)

struct ReceiptsPage: View {
    @ObservedObject var engine: Engine
    let story: Story
    @State private var appeared = false
    @State private var bragCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if story.events.isEmpty {
                    emptyState
                } else {
                    Text(sinceText)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                    heroRow.reveal(appeared, delay: 0.02)
                    hallOfShame.reveal(appeared, delay: 0.06)
                    activity.reveal(appeared, delay: 0.10)
                    bragRow.reveal(appeared, delay: 0.14)
                }
                HStack {
                    Spacer()
                    Text("caught in 4k by machogs · github.com/bnishit/machogs")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(18)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { appeared = true }
        }
    }

    private var sinceText: String {
        guard let since = story.since else { return "What your Mac does behind your back." }
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM"
        return "What your Mac was doing behind your back · since \(fmt.string(from: since))"
    }

    private var heroRow: some View {
        HStack(spacing: 12) {
            StatCard(emoji: "⏱️",
                     value: hoursWasted.value, suffix: hoursWasted.suffix,
                     caption: "of CPU time wasted on programs you never opened",
                     tint: .orange)
            StatCard(emoji: "🧹",
                     value: Double(story.totalCloses), suffix: "",
                     caption: "background programs caught and closed",
                     tint: .pink)
            StatCard(emoji: "⚡",
                     value: Double(story.phoneCharges), suffix: "",
                     caption: story.phoneCharges == 0
                         ? "phone charges wasted — caught them before they cost you 😌"
                         : "phone charges of wasted electricity",
                     tint: .teal)
        }
    }

    private var hoursWasted: (value: Double, suffix: String) {
        let s = story.totalCPUSeconds
        if s >= 7200 { return (Double(s / 3600), "h") }
        if s >= 120 { return (Double(s / 60), "m") }
        return (Double(s), "s")
    }

    private var hallOfShame: some View {
        let heavyBurn = (story.byApp.map(\.cpuSeconds).max() ?? 0) >= 60
        let ranked = heavyBurn ? story.byApp : story.byApp.sorted { $0.closes > $1.closes }
        let maxSecs = max(1, ranked.map(\.cpuSeconds).max() ?? 1)
        let maxCloses = max(1, ranked.map(\.closes).max() ?? 1)
        return Slab("🏆 Hall of Shame", caption: "Who leaves the most junk running on this Mac.") {
            ForEach(Array(ranked.prefix(6).enumerated()), id: \.element.id) { rank, app in
                shameRow(rank: rank, app: app, heavyBurn: heavyBurn,
                         maxSecs: maxSecs, maxCloses: maxCloses)
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
                Text(app.owner == "unknown" ? "mystery programs 👻" : app.owner)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
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
        .modifier(HoverLift())
    }

    private func timeText(_ s: Int) -> String {
        if s >= 7200 { return "\(s / 3600) hrs" }
        if s >= 120 { return "\(s / 60) min" }
        return "\(s) sec"
    }

    private var activity: some View {
        Slab("📈 The last two weeks", caption: "Programs caught per day. Quiet days mean your Mac behaved.") {
            Chart(story.days) { d in
                BarMark(x: .value("Day", d.label), y: .value("Closed", d.count))
                    .foregroundStyle(LinearGradient(colors: [.pink, .orange],
                                                    startPoint: .top, endPoint: .bottom))
                    .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3))
            }
            .frame(height: 110)
        }
    }

    private var bragRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Flex it.")
                    .font(.system(.callout, design: .rounded).weight(.bold))
                Text("One card with your totals, ready to paste anywhere.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                engine.copyBrag()
                bragCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { bragCopied = false }
            } label: {
                Text(bragCopied ? "Copied ✓ go flex" : "Copy the brag card 📋")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(LinearGradient(colors: bragCopied ? [.green, .teal] : [.pink, .orange],
                                                              startPoint: .top, endPoint: .bottom)))
                    .shadow(color: (bragCopied ? Color.green : Color.pink).opacity(0.45), radius: 4, y: 1)
            }
            .buttonStyle(Squish())
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color.pink.opacity(0.10), Color.orange.opacity(0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.pink.opacity(0.2), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("🐷")
                .font(.system(size: 44))
            Text("No receipts yet.")
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text("Close your first hog from Now or the menu bar and this page starts keeping score.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var engine: Engine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("soundOn") private var soundOn = true
    @AppStorage("watchdogOn") private var watchdogOn = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Slab("The watchdog", caption: "The pig checks every minute. When something starts cooking your CPU, an AI session leaves a mess behind, or one app clones itself past reason, it taps your shoulder — once, with a cooldown, never a nag.") {
                    Toggle("Shoulder taps (the island + notifications)", isOn: $watchdogOn)
                        .toggleStyle(.switch)
                        .font(.system(.callout, design: .rounded))
                    HStack {
                        Text("See what a catch looks like:")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                        pill("Preview the island 📸", tint: .indigo) {
                            Island.shared.show(
                                BustEvent(kind: .hot,
                                          headline: "Caught the hog",
                                          subline: "Just a preview — nothing is actually wrong.",
                                          keys: []),
                                engine: engine)
                        }
                    }
                }

                Slab("The app") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Start at login", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .font(.system(.callout, design: .rounded))
                            .onChange(of: launchAtLogin) { on in
                                do {
                                    if on { try SMAppService.mainApp.register() }
                                    else { try SMAppService.mainApp.unregister() }
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                        Toggle("Sounds and haptics", isOn: $soundOn)
                            .toggleStyle(.switch)
                            .font(.system(.callout, design: .rounded))
                            .onChange(of: soundOn) { on in if on { Sfx.pop() } }
                    }
                }

                Slab("The promises", caption: nil) {
                    VStack(alignment: .leading, spacing: 6) {
                        promise("It never closes anything on its own — every close is your click.")
                        promise("It never touches a live coding session or macOS itself.")
                        promise("The only deleting it does is caches from its own safe list, on your two taps.")
                        promise("Every close is logged — that log is The Receipts.")
                    }
                }

                HStack {
                    Spacer()
                    Text("machogs \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · MIT · github.com/bnishit/machogs")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(18)
        }
    }

    private func promise(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("🤝").font(.system(size: 12))
            Text(text)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
