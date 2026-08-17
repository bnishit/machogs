// The Receipts — machogs' full-window scoreboard.
//
// The popover is the 10-second surface; this is the dwell surface. It reads
// ~/Library/Logs/machogs.log (the same file the CLI writes) and turns weeks
// of closes into a story: hero totals, a Hall of Shame leaderboard, a
// two-week activity chart, and a one-click brag card. Read-only over the log;
// it closes nothing and deletes nothing.

import SwiftUI
import AppKit
import Charts

// MARK: - Log parsing

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
    var worstSingle: CloseEvent? { events.max { $0.cpuSeconds < $1.cpuSeconds } }

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

// MARK: - Pieces

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

// MARK: - The window

struct StoryView: View {
    @ObservedObject var engine: Engine
    @State private var story = Story.load()
    @State private var appeared = false
    @State private var bragCopied = false

    var body: some View {
        ZStack(alignment: .top) {
            // A soft warm wash at the top so the window has weather, not just walls.
            LinearGradient(colors: [Color.pink.opacity(0.10), Color.orange.opacity(0.04), .clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header.reveal(appeared, delay: 0)
                    liveNow.reveal(appeared, delay: 0.04)
                    if story.events.isEmpty {
                        emptyState.reveal(appeared, delay: 0.08)
                    } else {
                        heroRow.reveal(appeared, delay: 0.08)
                        hallOfShame.reveal(appeared, delay: 0.12)
                        activity.reveal(appeared, delay: 0.16)
                        bragRow.reveal(appeared, delay: 0.2)
                    }
                    footer.reveal(appeared, delay: 0.25)
                }
                .padding(22)
                .padding(.top, 14)   // clear the floating traffic lights
            }

            ConfettiBurst(trigger: engine.celebrate)
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear {
            story = Story.load()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
            // The window is a command center, not just a scoreboard: load the
            // live picture (ports are instant; the disk scan takes ~15s).
            if engine.portsReport == nil { engine.checkPorts() }
            if engine.diskReport == nil { engine.checkDisk() }
        }
        // Closing things bumps the log; keep the scoreboard in sync.
        .onChange(of: engine.celebrate) { _ in story = Story.load() }
    }

    // MARK: - Right now: everything the popover can do, in the big window.

    private var liveNow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(engine.clean && !engine.swapTrouble ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("Right now")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Spacer()
                if engine.refreshing || engine.portsLoading || engine.diskLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    engine.refresh(); engine.checkPorts(); engine.checkDisk()
                } label: {
                    Text("Re-check")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(Squish())
            }

            if engine.swapTrouble { SwapCard(engine: engine) }

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

            if engine.groups.isEmpty {
                HStack(spacing: 6) {
                    Text("✨")
                    Text("Nothing is hogging your Mac right now.")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.green)
                }
            } else {
                if engine.groups.count > 1 {
                    HStack {
                        Text("\(engine.groups.reduce(0) { $0 + $1.count }) things worth closing")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
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

            HStack(alignment: .top, spacing: 14) {
                // Ports — instant answer to "who's on 3000?"
                VStack(alignment: .leading, spacing: 7) {
                    Text("🔌 Ports")
                        .font(.system(.callout, design: .rounded).weight(.bold))
                    if let p = engine.portsReport {
                        if p.ports.isEmpty {
                            Text("Nothing is listening.")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(p.ports) { item in
                            PortRow(item: item) { engine.freePort(item) }
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Storage — safe caches clear right here.
                VStack(alignment: .leading, spacing: 7) {
                    Text("💾 Storage")
                        .font(.system(.callout, design: .rounded).weight(.bold))
                    if let d = engine.diskReport {
                        if d.items.isEmpty {
                            Text("Junk spots are clean — the disk is your real files.")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(d.items) { item in
                            DiskRow(item: item,
                                    clearing: engine.clearingPath == item.path,
                                    clear: { engine.clearDisk(item) })
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                        }
                    } else if engine.diskLoading {
                        Text("Weighing the junk spots…")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: engine.receipt)
    }

    private var header: some View {
        HStack(spacing: 12) {
            MascotPig(hot: false, refreshing: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("The Receipts")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                Text(sinceText)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
        return VStack(alignment: .leading, spacing: 10) {
            Text("🏆 Hall of Shame")
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text("Who leaves the most junk running on this Mac.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(Array(ranked.prefix(6).enumerated()), id: \.element.id) { rank, app in
                shameRow(rank: rank, app: app, heavyBurn: heavyBurn,
                         maxSecs: maxSecs, maxCloses: maxCloses)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
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
        VStack(alignment: .leading, spacing: 10) {
            Text("📈 The last two weeks")
                .font(.system(.title3, design: .rounded).weight(.bold))
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
            Text("Programs caught per day. Quiet days mean your Mac behaved.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
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
            Text("Close your first hog from the menu bar and this page starts keeping score.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("caught in 4k by machogs · github.com/bnishit/machogs")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}
