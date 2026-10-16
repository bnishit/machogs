import Foundation

/// One description of what a scan proves, shared by the window and menu.
public struct ScanPresentation: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case initial, checking, unavailable, stale, refreshing
        case memoryPressure, actionable, protectedWork, quiet
    }

    public let state: State
    public let protectedFindings: [Finding]
    public let actionableCount: Int
    public let hasSwapPressure: Bool

    public var protectedCount: Int { protectedFindings.count }
    public var protectedCPU: Double { protectedFindings.reduce(0) { $0 + $1.cpu } }
    public var protectedIsBusy: Bool { protectedCPU >= 20 }
    public var canClaimFreshResult: Bool {
        [.memoryPressure, .actionable, .protectedWork, .quiet].contains(state)
    }

    public init(report: EngineReport?, isScanning: Bool, scanError: String?) {
        // One process can trigger several detector rules. Count it once, using
        // the highest observed CPU sample rather than adding duplicate rows.
        protectedFindings = Dictionary(grouping: report?.protectedFindings ?? []) {
            ProcessTarget(pid: $0.pid, identity: $0.identity)
        }.values.compactMap { $0.max { $0.cpu < $1.cpu } }
            .sorted { $0.pid == $1.pid ? $0.identity < $1.identity : $0.pid < $1.pid }
        actionableCount = report?.actionableFindings.count ?? 0
        hasSwapPressure = (report?.host.swapPercent ?? 0) > 80

        if scanError != nil {
            state = report == nil ? .unavailable : .stale
        } else if isScanning {
            state = report == nil ? .checking : .refreshing
        } else if report == nil {
            state = .initial
        } else if hasSwapPressure {
            state = .memoryPressure
        } else if actionableCount > 0 {
            state = .actionable
        } else if !protectedFindings.isEmpty {
            state = .protectedWork
        } else {
            state = .quiet
        }
    }

    public var title: String {
        switch state {
        case .initial: return "Ready for a look"
        case .checking: return "Checking your Mac"
        case .unavailable: return "Could not check your Mac"
        case .stale: return "Last check could not refresh"
        case .refreshing: return "Checking again"
        case .memoryPressure: return "Memory needs attention"
        case .actionable: return "Found work left behind"
        case .protectedWork: return protectedIsBusy ? "Protected work is using CPU" : "Protected work stays running"
        case .quiet: return "No cleanup found"
        }
    }

    public var detail: String {
        switch state {
        case .initial, .checking:
            return "This check only looks. Nothing will close."
        case .unavailable:
            return "There is no successful scan to show. Try checking again."
        case .stale:
            return "Showing the last successful check. Check again before acting on it."
        case .refreshing:
            return "The previous result stays visible while a fresh check runs."
        case .memoryPressure:
            return "Disk-backed memory use is high. Save your work and restart; closing leftovers alone will not fix this."
        case .actionable:
            return "Review the findings below before choosing what to close."
        case .protectedWork:
            return protectedIsBusy
                ? "Nothing is offered for cleanup. Protected work is using CPU; manage it in the app that owns it."
                : "Nothing is offered for cleanup. Protected processes were mostly idle in this check."
        case .quiet:
            return "This check found no stuck or abandoned work to close. It does not rule out other causes of a slow Mac."
        }
    }
}

public extension AppModel {
    var scanPresentation: ScanPresentation {
        ScanPresentation(report: report, isScanning: isScanning, scanError: scanError)
    }
}
