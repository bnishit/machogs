import Foundation

public struct WatchdogEvent: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case hot, clones, sweep, memory }
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
    private var notifiedMemory: Set<String> = []
    // The count each group had when its last clone notification went out.
    // A plain edge trigger ("crossed 8") fired once and then watched a swarm
    // grow 8 -> 49 in silence, because 49 never crosses 8 again. Growth since
    // the last notification is what re-arms it.
    private var notifiedCloneCounts: [String: Int] = [:]
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

    /// A clone group is worth another tap when it has doubled, or grown by
    /// another army's worth, since the last tap. Both bounds matter: doubling
    /// alone goes quiet on huge swarms (98 -> 195 before the next word),
    /// stepping alone nags on churny mid-size ones.
    private func cloneWorthNotifying(_ count: Int, lastNotifiedAt: Int) -> Bool {
        guard count >= 8 else { return false }
        guard lastNotifiedAt > 0 else { return true }
        return count >= lastNotifiedAt * 2 || count >= lastNotifiedAt + 8
    }

    public mutating func evaluate(_ report: EngineReport) -> WatchdogEvent? {
        let groups = report.groups
        let memory = report.memoryGroups
        let hot = Set(groups.filter { $0.totalCPU >= 60 }.map(\.id))
        let counts = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.count) })
        let sessions = Set(report.findings.filter { $0.action == .neverKilled }.map { $0.identity })
        let keys = Set(groups.map(\.id))
        defer {
            previousHot = hot
            notifiedHot.formIntersection(hot)
            notifiedMemory.formIntersection(Set(memory.map(\.id)))
            // Forget a group that is gone or has shrunk back under an army:
            // if it grows past 8 again later, that is a fresh event.
            notifiedCloneCounts = notifiedCloneCounts.filter { (counts[$0.key] ?? 0) >= 8 }
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
            cloneWorthNotifying($0.count, lastNotifiedAt: notifiedCloneCounts[$0.id] ?? 0) && canNotify($0.id)
        }) {
            notifiedCloneCounts[group.id] = group.count
            return emit(WatchdogEvent(kind: .clones, title: "Clone army in the background",
                                      body: group.story, targets: group.targets, groupID: group.id), groupID: group.id)
        }

        // Memory hogs. A gigabyte parked idle deserves a tap only when the Mac
        // is actually feeling it: with swap climbing, hoarded memory is what
        // the person's real work is being pushed to disk to make room for. On
        // an unpressured machine only a truly huge hog is worth interrupting
        // anyone over.
        let memoryFloorMB = report.host.swapPercent >= 60 ? 1024 : 4096
        if let group = memory.first(where: {
            $0.totalMemoryMB >= memoryFloorMB && !notifiedMemory.contains($0.id) && canNotify($0.id)
        }) {
            notifiedMemory.insert(group.id)
            return emit(WatchdogEvent(kind: .memory, title: "Found what's eating your memory",
                                      body: group.story, targets: group.targets, groupID: group.id), groupID: group.id)
        }
        return nil
    }
}
