import Foundation

public struct WatchdogEvent: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case hot, clones, sweep }
    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let body: String
    public let targets: [ProcessTarget]
    public let groupID: String
}

public struct WatchdogPolicy: Sendable {
    private var primed = false
    private var previousHot: Set<String> = []
    private var notifiedHot: Set<String> = []
    private var previousCounts: [String: Int] = [:]
    private var previousSessions: Set<String> = []
    private var previousGroupKeys: Set<String> = []
    private var lastNotified: [String: Date] = [:]
    private var snoozedUntil: [String: Date] = [:]
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date

    public init(cooldown: TimeInterval = 30 * 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cooldown = cooldown
        self.now = now
    }

    public mutating func snooze(groupID: String, minutes: Int = 60) {
        snoozedUntil[groupID] = now().addingTimeInterval(TimeInterval(minutes * 60))
    }

    private func canNotify(_ groupID: String) -> Bool {
        let time = now()
        if let until = snoozedUntil[groupID], until > time { return false }
        if let last = lastNotified[groupID], time.timeIntervalSince(last) < cooldown { return false }
        return true
    }

    private mutating func emit(_ event: WatchdogEvent, groupID: String) -> WatchdogEvent {
        lastNotified[groupID] = now()
        return event
    }

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
        if endedSession, let group = groups.first(where: { newKeys.contains($0.id) && canNotify($0.id) }) {
            return emit(WatchdogEvent(kind: .sweep, title: "Session over, mess left",
                                      body: group.story, targets: group.targets, groupID: group.id), groupID: group.id)
        }

        if let group = groups.first(where: {
            hot.contains($0.id) && previousHot.contains($0.id) && !notifiedHot.contains($0.id) && canNotify($0.id)
        }) {
            notifiedHot.insert(group.id)
            return emit(WatchdogEvent(kind: .hot, title: "Found what's cooking your CPU",
                                      body: group.story, targets: group.targets, groupID: group.id), groupID: group.id)
        }

        if let group = groups.first(where: {
            $0.count >= 8 && (previousCounts[$0.id] ?? 0) < 8 && canNotify($0.id)
        }) {
            return emit(WatchdogEvent(kind: .clones, title: "Clone army in the background",
                                      body: group.story, targets: group.targets, groupID: group.id), groupID: group.id)
        }
        return nil
    }
}
