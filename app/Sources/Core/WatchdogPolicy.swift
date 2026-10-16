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
    private var notifiedCloneCounts: [String: Int] = [:]
    private var memoryBaselines: [String: (app: AppMemory, swap: Int, at: Date)] = [:]
    private var memoryNotices: [String: (app: AppMemory, critical: Bool)] = [:]
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
            $0.count >= 8 && ($0.count >= (notifiedCloneCounts[$0.id] ?? 0) + 8
                || $0.count >= (notifiedCloneCounts[$0.id] ?? 0) * 2) && canNotify($0.id)
        }) {
            notifiedCloneCounts[group.id] = group.count
            return emit(WatchdogEvent(kind: .clones, title: "Clone army in the background",
                                      body: group.story, targets: group.targets, groupID: group.id), groupID: group.id)
        }
        return nil
    }

    public mutating func evaluateMemory(_ snapshot: MemorySnapshot) -> WatchdogEvent? {
        guard snapshot.physicalMB > 0 else { return nil }
        let time = now()
        let names = Set(snapshot.apps.map(\.app))
        memoryBaselines = memoryBaselines.filter { names.contains($0.key) }
        memoryNotices = memoryNotices.filter { names.contains($0.key) }
        var result: WatchdogEvent?
        for app in snapshot.apps {
            let id = "memory|\(app.app)"
            let baseline = memoryBaselines[app.app]
            if baseline == nil || time.timeIntervalSince(baseline!.at) > 600 {
                memoryBaselines[app.app] = (app, snapshot.swapUsedMB, time)
            }
            let critical = app.memoryMB >= snapshot.physicalMB / 2
            let pressure = snapshot.swapUsedMB >= snapshot.physicalMB / 4
            let large = app.memoryMB >= snapshot.physicalMB / 4
            let cold = app.compressedMB >= app.memoryMB / 2
            let memoryGrowth = baseline.map { app.memoryMB - $0.app.memoryMB } ?? 0
            let processGrowth = baseline.map { app.processCount - $0.app.processCount } ?? 0
            let recent = baseline.map { time.timeIntervalSince($0.at) <= 600 } ?? false
            let growing = recent && (memoryGrowth >= 1024
                || (memoryGrowth >= 512 && processGrowth >= 8)
                || (processGrowth >= 16 && app.processCount >= 32 && memoryGrowth >= 256))
            guard critical || (large && (pressure || cold)) || growing else {
                if app.memoryMB < snapshot.physicalMB / 8 { memoryNotices.removeValue(forKey: app.app) }
                continue
            }
            let previous = memoryNotices[app.app]
            let worsened = previous.map { (critical && !$0.critical) || app.memoryMB >= $0.app.memoryMB + 1024
                || (app.processCount >= $0.app.processCount + 16 && app.memoryMB >= $0.app.memoryMB + 256) } ?? true
            let snoozed = (snoozedUntil[id] ?? .distantPast) > time
            let elapsed = time.timeIntervalSince(lastNotified[id] ?? .distantPast)
            guard result == nil, !snoozed, previous == nil || worsened || elapsed >= cooldown,
                  lastNotified[id] == nil || elapsed >= (worsened ? 60 : cooldown) else { continue }
            let growth = growing ? " Up \(String(format: "%.1f", Double(memoryGrowth) / 1024)) GB and \(max(0, processGrowth)) processes since an earlier check." : ""
            let body = "\(app.app) is using \(app.memoryText) across \(app.processCount) processes.\(growth) Save your work, then close unused tabs or restart the app when ready."
            memoryNotices[app.app] = (app, critical)
            result = emit(WatchdogEvent(kind: .memory,
                title: critical ? "\(app.app) is using at least half your RAM" : "\(app.app)'s memory use needs a look",
                body: body, targets: [], groupID: id), groupID: id)
        }
        return result
    }

}
