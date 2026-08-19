import Foundation

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
    public var sizeText: String {
        if sizeMB >= 1024 {
            return String(format: "%.1f GB", Double(sizeMB) / 1024)
        }
        return "\(sizeMB) MB"
    }

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

public struct CleanupReceipt: Equatable, Sendable {
    public let closedCount: Int
    public let cpuFreed: Double
    public let cpuSecondsAlreadyUsed: Int
    public let message: String
    public let isSuccess: Bool
    public let canShare: Bool

    public init(
        closedCount: Int,
        cpuFreed: Double,
        cpuSecondsAlreadyUsed: Int,
        message: String,
        isSuccess: Bool? = nil,
        canShare: Bool? = nil
    ) {
        self.closedCount = closedCount
        self.cpuFreed = cpuFreed
        self.cpuSecondsAlreadyUsed = cpuSecondsAlreadyUsed
        self.message = message
        self.isSuccess = isSuccess ?? (closedCount > 0)
        self.canShare = canShare ?? (closedCount > 0)
    }

    public static func make(from report: EngineReport) -> CleanupReceipt {
        let killed = report.killedFindings
        let cpu = killed.reduce(0) { $0 + $1.cpu }
        let seconds = killed.reduce(0) { $0 + $1.cpuSeconds }
        let message: String
        if killed.isEmpty {
            message = "Nothing was closed. It may have ended on its own or become protected."
        } else if cpu >= 20 {
            message = "Closed \(killed.count) background program\(killed.count == 1 ? "" : "s") and freed about \(String(format: "%.1f", cpu / 100)) of a CPU core."
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
