import Foundation

public struct WatchdogEvent: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case hot, clones, sweep }
    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let body: String
    public let targets: [ProcessTarget]
}

public struct WatchdogPolicy: Sendable {
    private var primed = false
    private var previousHot: Set<String> = []
    private var notifiedHot: Set<String> = []
    private var previousCounts: [String: Int] = [:]
    private var previousSessions: Set<String> = []
    private var previousGroupKeys: Set<String> = []

    public init() {}

    public mutating func evaluate(_ report: EngineReport) -> WatchdogEvent? {
        let groups = report.groups
        let hot = Set(groups.filter { $0.totalCPU >= 60 }.map(\.id))
        let counts = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.count) })
        let sessions = Set(report.findings.filter { $0.action == .neverKilled }.map { $0.identity })
        let keys = Set(groups.map(\.id))
        defer {
            previousHot = hot
            notifiedHot.formIntersection(hot)
            previousCounts = counts
            previousSessions = sessions
            previousGroupKeys = keys
            primed = true
        }
        guard primed else { return nil }

        let endedSession = !previousSessions.subtracting(sessions).isEmpty
        let newKeys = keys.subtracting(previousGroupKeys)
        if endedSession, let group = groups.first(where: { newKeys.contains($0.id) }) {
            return WatchdogEvent(kind: .sweep, title: "Session over, mess left",
                                 body: group.story, targets: group.targets)
        }

        if let group = groups.first(where: {
            hot.contains($0.id) && previousHot.contains($0.id) && !notifiedHot.contains($0.id)
        }) {
            notifiedHot.insert(group.id)
            return WatchdogEvent(kind: .hot, title: "Found what's cooking your CPU",
                                 body: group.story, targets: group.targets)
        }

        if let group = groups.first(where: {
            $0.count >= 8 && (previousCounts[$0.id] ?? 0) < 8
        }) {
            return WatchdogEvent(kind: .clones, title: "Clone army in the background",
                                 body: group.story, targets: group.targets)
        }
        return nil
    }
}
