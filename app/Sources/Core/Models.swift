import Foundation

/// The one way megabytes become words anywhere in the app, so 1536 never
/// shows as "1536 MB" on one screen and "1.5 GB" on another.
func mbText(_ mb: Int) -> String {
    mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
}

public struct HostSnapshot: Codable, Equatable, Sendable {
    public let load: Double
    public let cores: Int
    public let swapUsedMB: Double
    public let swapTotalMB: Double
    public let swapPercent: Int
    public let uptimeDays: Int

    enum CodingKeys: String, CodingKey {
        case load, cores
        case swapUsedMB = "swap_used_mb"
        case swapTotalMB = "swap_total_mb"
        case swapPercent = "swap_pct"
        case uptimeDays = "uptime_days"
    }
}

public struct ReportSummary: Codable, Equatable, Sendable {
    public let reapable: Int
    public let killed: Int
}

public enum FindingAction: String, Codable, Sendable {
    case reapable
    case needsDuplicatesFlag = "needs-dupes-flag"
    case protected
    case neverKilled = "never-killed"
    case reportOnly = "report-only"
    case killed

    public var isActionable: Bool {
        self == .reapable || self == .needsDuplicatesFlag
    }
}

public struct Finding: Codable, Equatable, Identifiable, Sendable {
    public let pid: Int
    public let identity: String
    public let section: String
    public let action: FindingAction
    public let cpu: Double
    public let cpuSeconds: Int
    /// phys_footprint, the number Activity Monitor shows. Optional in the
    /// JSON: an older engine on the user's PATH emits no memory_mb key, and
    /// the app must keep reading its reports rather than refusing them.
    public let memoryMB: Int
    public let age: String
    public let owner: String
    public let what: String
    public let detail: String
    public let story: String

    public var id: Int { pid }
    public var stableGroupKey: String { "\(section)|\(owner)|\(what)" }

    enum CodingKeys: String, CodingKey {
        case pid, identity, section, action, cpu, age, owner, what, detail, story
        case cpuSeconds = "cpu_seconds"
        case memoryMB = "memory_mb"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pid = try values.decode(Int.self, forKey: .pid)
        identity = try values.decode(String.self, forKey: .identity)
        section = try values.decode(String.self, forKey: .section)
        action = try values.decode(FindingAction.self, forKey: .action)
        cpu = try values.decode(Double.self, forKey: .cpu)
        cpuSeconds = try values.decode(Int.self, forKey: .cpuSeconds)
        memoryMB = try values.decodeIfPresent(Int.self, forKey: .memoryMB) ?? 0
        age = try values.decode(String.self, forKey: .age)
        owner = try values.decode(String.self, forKey: .owner)
        what = try values.decode(String.self, forKey: .what)
        detail = try values.decode(String.self, forKey: .detail)
        story = try values.decode(String.self, forKey: .story)
    }
}

public struct EngineReport: Codable, Equatable, Sendable {
    public let mode: String
    public let host: HostSnapshot
    public let summary: ReportSummary
    public let findings: [Finding]

    public var actionableFindings: [Finding] {
        findings.filter { $0.action.isActionable }
    }

    public var protectedFindings: [Finding] {
        findings.filter { $0.action == .protected || $0.action == .neverKilled }
    }

    public var killedFindings: [Finding] {
        findings.filter { $0.action == .killed }
    }

    public var reportOnlyFindings: [Finding] {
        findings.filter { $0.action == .reportOnly }
    }

    // Memory findings are shown and never reaped, so they stay out of
    // `groups`, which is what the kill flows and the CPU rules read. The
    // watchdog still has to see them to tap a shoulder about a hoarder, so
    // they group on their own, ranked by the number that matters here.
    public var memoryGroups: [FindingGroup] {
        Dictionary(grouping: reportOnlyFindings, by: \.stableGroupKey)
            .values
            .map(FindingGroup.init)
            .sorted { $0.totalMemoryMB > $1.totalMemoryMB }
    }

    public var groups: [FindingGroup] {
        Dictionary(grouping: actionableFindings, by: \.stableGroupKey)
            .values
            .map(FindingGroup.init)
            .sorted {
                if $0.isHot != $1.isHot { return $0.isHot }
                if $0.totalCPU != $1.totalCPU { return $0.totalCPU > $1.totalCPU }
                return $0.story < $1.story
            }
    }
}

public struct FindingGroup: Equatable, Identifiable, Sendable {
    public let members: [Finding]

    public init(_ members: [Finding]) {
        self.members = members.sorted { $0.pid < $1.pid }
    }

    public var id: String { members.first?.stableGroupKey ?? "empty" }
    public var story: String { members.first?.story ?? "Background work was found." }
    public var owner: String { members.first?.owner ?? "Unknown app" }
    public var what: String { members.first?.what ?? "background program" }
    public var count: Int { members.count }
    public var targets: [ProcessTarget] {
        members.map { ProcessTarget(pid: $0.pid, identity: $0.identity) }
    }
    public var totalCPU: Double { members.reduce(0) { $0 + $1.cpu } }
    public var totalCPUSeconds: Int { members.reduce(0) { $0 + $1.cpuSeconds } }
    public var totalMemoryMB: Int { members.reduce(0) { $0 + $1.memoryMB } }
    public var memoryText: String { mbText(totalMemoryMB) }
    public var isHot: Bool { totalCPU >= 20 }
    public var needsDuplicatesFlag: Bool {
        members.contains { $0.action == .needsDuplicatesFlag }
    }
}

public struct ProcessTarget: Codable, Hashable, Sendable {
    public let pid: Int
    public let identity: String

    public init(pid: Int, identity: String) {
        self.pid = pid
        self.identity = identity
    }
}

public struct DiskInfo: Codable, Equatable, Sendable {
    public let usedGB: Int
    public let totalGB: Int
    public let percent: Int

    enum CodingKeys: String, CodingKey {
        case usedGB = "used_gb"
        case totalGB = "total_gb"
        case percent = "pct"
    }
}

public struct DiskItem: Codable, Equatable, Identifiable, Sendable {
    public let label: String
    public let icon: String
    public let path: String
    public let sizeMB: Int
    public let verdict: String
    public let how: String

    public var id: String { path }
    public var sizeText: String { mbText(sizeMB) }

    enum CodingKeys: String, CodingKey {
        case label, icon, path, verdict, how
        case sizeMB = "size_mb"
    }
}

public struct DiskReport: Codable, Equatable, Sendable {
    public let mode: String
    public let disk: DiskInfo
    public let items: [DiskItem]
}

public struct DiskClearResult: Codable, Equatable, Sendable {
    public let mode: String
    public let path: String
    public let label: String
    public let freedMB: Int

    enum CodingKeys: String, CodingKey {
        case mode, path, label
        case freedMB = "freed_mb"
    }
}

public struct PortItem: Codable, Equatable, Identifiable, Sendable {
    public let port: Int
    public let pid: Int
    public let identity: String
    public let process: String
    public let owner: String
    public let cwd: String
    public let age: String
    public let system: Bool
    public let protected: Bool
    public let note: String
    public let action: String?

    public var id: String { "\(port):\(pid)" }
    public var isClosable: Bool { !system && !protected && note.isEmpty }
}

public struct PortTarget: Hashable, Sendable {
    public let port: Int
    public let pid: Int
    public let identity: String

    public init(port: Int, pid: Int, identity: String) {
        self.port = port
        self.pid = pid
        self.identity = identity
    }
}

public struct PortsReport: Codable, Equatable, Sendable {
    public let mode: String
    public let ports: [PortItem]
}

public struct MemoryProcess: Codable, Equatable, Identifiable, Sendable {
    public let pid: Int
    public let name: String
    public let memoryMB: Int
    public let compressedMB: Int
    public let age: String

    public var id: Int { pid }
    public var memoryText: String { mbText(memoryMB) }

    enum CodingKeys: String, CodingKey {
        case pid, name, age
        case memoryMB = "memory_mb"
        case compressedMB = "compressed_mb"
    }

    public init(pid: Int, name: String, memoryMB: Int, compressedMB: Int, age: String) {
        self.pid = pid
        self.name = name
        self.memoryMB = memoryMB
        self.compressedMB = compressedMB
        self.age = age
    }
}

public struct MemoryApp: Codable, Equatable, Identifiable, Sendable {
    public let app: String
    public let memoryMB: Int
    public let compressedMB: Int
    public let processCount: Int
    public let oldestAge: String
    public let processes: [MemoryProcess]

    public var id: String { app }
    public var memoryText: String { mbText(memoryMB) }
    /// How much of the footprint macOS has compressed away because nothing
    /// touched it. Used memory stays resident; hoarded memory goes cold.
    public var coldPercent: Int {
        guard memoryMB > 0 else { return 0 }
        return min(100, compressedMB * 100 / memoryMB)
    }
    /// The engine's list is sorted biggest-first, so the worst child is row one.
    public var biggestProcess: MemoryProcess? { processes.first }
    public var isHoarding: Bool {
        Self.isHoarding(memoryMB: memoryMB, compressedMB: compressedMB, processCount: processCount)
    }

    /// Mirror of the engine's `hoarding` rule (MEM_APP_MB / MEM_COLD_PCT /
    /// MEM_APP_PROCS defaults), computed here from the raw numbers so the app
    /// never trusts a flag it cannot explain: big, and either mostly cold or a
    /// crowd of processes. A large-but-warm app (an active Xcode build, a VM
    /// doing work) does not trip it.
    public static func isHoarding(memoryMB: Int, compressedMB: Int, processCount: Int) -> Bool {
        guard memoryMB >= 4096 else { return false }
        if memoryMB > 0, compressedMB * 100 / memoryMB >= 60 { return true }
        return processCount >= 20
    }

    enum CodingKeys: String, CodingKey {
        case app
        case memoryMB = "memory_mb"
        case compressedMB = "compressed_mb"
        case processCount = "processes"
        case oldestAge = "oldest_age"
        case processes = "procs"
    }

    public init(app: String, memoryMB: Int, compressedMB: Int, processCount: Int,
                oldestAge: String, processes: [MemoryProcess]) {
        self.app = app
        self.memoryMB = memoryMB
        self.compressedMB = compressedMB
        self.processCount = processCount
        self.oldestAge = oldestAge
        self.processes = processes
    }
}

public struct MemoryReport: Codable, Equatable, Sendable {
    public let mode: String
    public let host: HostSnapshot
    public let apps: [MemoryApp]

    public var hoardingApps: [MemoryApp] { apps.filter(\.isHoarding) }
}

/// The one way a battery cost becomes words anywhere in the app. macOS answers
/// this question with "Energy Impact: 32.4", which is unitless and means
/// nothing to anyone; minutes of an afternoon is what a person actually feels.
/// Under a minute is named rather than rounded, because "0 minutes" reads like
/// the measurement failed.
func batteryMinutesText(_ minutes: Double) -> String {
    if minutes < 1 { return "under a minute" }
    if minutes < 1.5 { return "about a minute" }
    return "about \(Int(minutes.rounded())) minutes"
}

public struct PowerState: Codable, Equatable, Sendable {
    public let batteryPresent: Bool
    public let onBattery: Bool
    public let charging: Bool
    public let chargePercent: Int
    /// Already in words from the engine ("about 3 hours 10 minutes"), and
    /// empty whenever macOS refuses to estimate — which it does for minutes
    /// after every plug change.
    public let timeLeft: String
    public let watts: Double
    /// True while plugged in: there is no drain to measure when the wall is
    /// paying, so the figure is modelled from how hard the Mac is working.
    public let wattsEstimated: Bool

    enum CodingKeys: String, CodingKey {
        case batteryPresent = "battery_present"
        case onBattery = "on_battery"
        case charging
        case chargePercent = "charge_pct"
        case timeLeft = "time_left"
        case watts
        case wattsEstimated = "watts_estimated"
    }

    public init(batteryPresent: Bool, onBattery: Bool, charging: Bool, chargePercent: Int,
                timeLeft: String, watts: Double, wattsEstimated: Bool) {
        self.batteryPresent = batteryPresent
        self.onBattery = onBattery
        self.charging = charging
        self.chargePercent = chargePercent
        self.timeLeft = timeLeft
        self.watts = watts
        self.wattsEstimated = wattsEstimated
    }

    public var wattsText: String { "about \(Int(watts.rounded())) watts" }

    /// The state of the machine in one sentence, in the order a person asks
    /// it: am I on battery, how much is left, how long have I got.
    public var summary: String {
        guard batteryPresent else {
            return "This Mac runs off the wall, so nothing is draining."
        }
        if onBattery {
            let left = timeLeft.isEmpty ? "" : ", \(timeLeft) to go"
            return "On battery, \(chargePercent)% left\(left)."
        }
        return "Plugged in\(charging ? " and charging" : ""), \(chargePercent)%. Nothing is draining right now."
    }
}

public struct EnergyProcess: Codable, Equatable, Identifiable, Sendable {
    public let pid: Int
    public let name: String
    public let minutesPerHour: Double
    public let age: String

    public var id: Int { pid }
    public var drainText: String { "\(batteryMinutesText(minutesPerHour)) an hour" }

    enum CodingKeys: String, CodingKey {
        case pid, name, age
        case minutesPerHour = "minutes_per_hour"
    }

    public init(pid: Int, name: String, minutesPerHour: Double, age: String) {
        self.pid = pid
        self.name = name
        self.minutesPerHour = minutesPerHour
        self.age = age
    }
}

public struct EnergyApp: Codable, Equatable, Identifiable, Sendable {
    public let app: String
    public let minutesPerHour: Double
    public let sharePercent: Int
    public let processCount: Int
    public let cpuSeconds: Int
    public let lifetimeSeconds: Int
    public let oldestAge: String
    public let processes: [EnergyProcess]

    public var id: String { app }
    public var drainText: String { "\(batteryMinutesText(minutesPerHour)) an hour" }
    /// The engine's list is sorted costliest-first, so the worst child is row one.
    public var biggestProcess: EnergyProcess? { processes.first }
    public var isDraining: Bool {
        Self.isDraining(minutesPerHour: minutesPerHour, cpuSeconds: cpuSeconds,
                        lifetimeSeconds: lifetimeSeconds)
    }

    /// Mirror of the engine's `draining` rule (ENERGY_APP_MINS /
    /// ENERGY_SUSTAIN_PCT / ENERGY_MIN_SECONDS defaults), computed here from
    /// the raw numbers so the app never shows a badge it cannot explain.
    /// Cost alone would accuse whatever the person is using right now, which
    /// is true and useless; an app worth naming has also been expensive for as
    /// long as it has been open, not for the minute since you gave it work.
    public static func isDraining(minutesPerHour: Double, cpuSeconds: Int, lifetimeSeconds: Int) -> Bool {
        guard minutesPerHour >= 10, lifetimeSeconds >= 1800 else { return false }
        return Double(cpuSeconds) * 100 / Double(lifetimeSeconds) >= 25
    }

    enum CodingKeys: String, CodingKey {
        case app
        case minutesPerHour = "minutes_per_hour"
        case sharePercent = "share_pct"
        case processCount = "processes"
        case cpuSeconds = "cpu_seconds"
        case lifetimeSeconds = "lifetime_seconds"
        case oldestAge = "oldest_age"
        case processes = "procs"
    }

    public init(app: String, minutesPerHour: Double, sharePercent: Int, processCount: Int,
                cpuSeconds: Int, lifetimeSeconds: Int, oldestAge: String,
                processes: [EnergyProcess]) {
        self.app = app
        self.minutesPerHour = minutesPerHour
        self.sharePercent = sharePercent
        self.processCount = processCount
        self.cpuSeconds = cpuSeconds
        self.lifetimeSeconds = lifetimeSeconds
        self.oldestAge = oldestAge
        self.processes = processes
    }
}

public struct EnergyReport: Codable, Equatable, Sendable {
    public let mode: String
    public let power: PowerState
    public let apps: [EnergyApp]

    /// Anything under a minute an hour is not an answer to anybody's question.
    public var appsWorthNaming: [EnergyApp] { apps.filter { $0.minutesPerHour >= 1 } }
    public var drainingApps: [EnergyApp] { apps.filter(\.isDraining) }
    public var worstApp: EnergyApp? { appsWorthNaming.first }

    /// The headline: one sentence naming one app, which is the whole answer
    /// for most people. Plugged in there is no drain to report, so the same
    /// cost is stated as what it would take the moment they unplug — never as
    /// a live drain that is not happening, and never as a zero.
    public func costSentence(for app: EnergyApp) -> String {
        let cost = batteryMinutesText(app.minutesPerHour)
        if power.onBattery {
            return "\(app.app) is costing you \(cost) of battery every hour."
        }
        return "Unplugged, \(app.app) would cost you \(cost) of battery every hour."
    }
}

public struct CleanupReceipt: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case processes, port, disk }

    public let closedCount: Int
    public let cpuFreed: Double
    public let cpuSecondsAlreadyUsed: Int
    public let message: String
    public let isSuccess: Bool
    public let canShare: Bool
    public let kind: Kind

    public init(
        closedCount: Int,
        cpuFreed: Double,
        cpuSecondsAlreadyUsed: Int,
        message: String,
        isSuccess: Bool? = nil,
        canShare: Bool? = nil,
        kind: Kind = .processes
    ) {
        self.closedCount = closedCount
        self.cpuFreed = cpuFreed
        self.cpuSecondsAlreadyUsed = cpuSecondsAlreadyUsed
        self.message = message
        self.isSuccess = isSuccess ?? (closedCount > 0)
        self.canShare = canShare ?? (closedCount > 0)
        self.kind = kind
    }

    public static func make(from report: EngineReport) -> CleanupReceipt {
        let killed = report.killedFindings
        let cpu = killed.reduce(0) { $0 + $1.cpu }
        let seconds = killed.reduce(0) { $0 + $1.cpuSeconds }
        let memory = killed.reduce(0) { $0 + $1.memoryMB }
        let message: String
        if killed.isEmpty {
            message = "Nothing was closed. It may have ended on its own or become protected."
        } else if cpu >= 20 {
            message = "Closed \(killed.count) background program\(killed.count == 1 ? "" : "s") and freed about \(String(format: "%.1f", cpu / 100)) of a CPU core."
        } else if memory >= 100 {
            // idle closes free memory, not heat — say how much came back
            message = "Closed \(killed.count) idle background program\(killed.count == 1 ? "" : "s") and got back \(mbText(memory)) of memory."
        } else {
            message = "Closed \(killed.count) idle background program\(killed.count == 1 ? "" : "s"). They were wasting memory, not heating your Mac."
        }
        return CleanupReceipt(
            closedCount: killed.count,
            cpuFreed: cpu,
            cpuSecondsAlreadyUsed: seconds,
            message: message,
            isSuccess: !killed.isEmpty,
            canShare: !killed.isEmpty
        )
    }
}
