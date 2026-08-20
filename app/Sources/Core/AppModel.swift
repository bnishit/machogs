import Combine
import Foundation

public struct ActionReview: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case processes([Finding])
        case port(PortItem)
        case disk(DiskItem)
    }

    public let id = UUID()
    public let kind: Kind
    public let checkedAt: Date

    public var itemCount: Int {
        switch kind {
        case .processes(let findings): return findings.count
        case .port, .disk: return 1
        }
    }

    public var processGroups: [FindingGroup] {
        guard case .processes(let findings) = kind else { return [] }
        return Dictionary(grouping: findings, by: \.stableGroupKey)
            .values
            .map(FindingGroup.init)
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.story < $1.story
            }
    }

    public var title: String {
        switch kind {
        case .processes(let findings):
            let owners = Set(findings.map(\.owner).filter { !$0.isEmpty })
            let source = owners.count == 1 ? owners.first! : owners.isEmpty ? "an unknown app" : "\(owners.count) apps"
            let noun = findings.count == 1 ? "thing" : "things"
            return "Close \(findings.count) unused \(noun) from \(source)?"
        case .port(let item):
            return "Free port \(item.port)?"
        case .disk(let item):
            return "Clear \(item.label)?"
        }
    }

    public var body: String {
        switch kind {
        case .processes:
            return "MacHogs checked them again just now. Only the items summarized below will close. If one holds unsaved work, that work could be lost. Live coding sessions and macOS are protected."
        case .port(let item):
            let location = item.cwd.isEmpty ? "" : " in \(item.cwd)"
            return "Machogs checked the listener again. This will stop \(item.process)\(location). Unsaved work inside it can be lost. macOS services and live coding sessions stay protected."
        case .disk(let item):
            return "This removes \(item.sizeText) from an engine-approved cache path. Apps can rebuild it. Machogs checks the exact path again before clearing anything."
        }
    }

    public var confirmLabel: String {
        switch kind {
        case .processes(let findings):
            return "Close \(findings.count) thing\(findings.count == 1 ? "" : "s")"
        case .port(let item):
            return "Stop \(item.process) and free port"
        case .disk:
            return "Clear cache"
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var report: EngineReport?
    @Published public private(set) var lastSuccessfulScan: Date?
    @Published public private(set) var scanError: String?
    @Published public private(set) var isScanning = false
    @Published public private(set) var pendingReview: ActionReview?
    @Published public private(set) var isReviewing = false
    @Published public private(set) var isActing = false
    @Published public private(set) var receipt: CleanupReceipt?
    @Published public private(set) var portsReport: PortsReport?
    @Published public private(set) var portsError: String?
    @Published public private(set) var isLoadingPorts = false
    @Published public private(set) var lastSuccessfulPortsScan: Date?
    @Published public private(set) var diskReport: DiskReport?
    @Published public private(set) var diskError: String?
    @Published public private(set) var isLoadingDisk = false
    @Published public private(set) var lastSuccessfulDiskScan: Date?
    @Published public private(set) var watchdogEvent: WatchdogEvent?

    private let service: any MachogsServing
    private var pollingTask: Task<Void, Never>?
    private var watchdog = WatchdogPolicy()

    public init(service: any MachogsServing) {
        self.service = service
    }

    public var groups: [FindingGroup] { report?.groups ?? [] }
    public var isStale: Bool { report != nil && scanError != nil }
    public var hasHotFinding: Bool { groups.contains(where: \.isHot) }
    public var hasSwapPressure: Bool { (report?.host.swapPercent ?? 0) > 80 }

    public func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            await self?.scan()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.scan()
            }
        }
    }

    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        do {
            let fresh = try await service.scan()
            report = fresh
            lastSuccessfulScan = Date()
            watchdogEvent = watchdog.evaluate(fresh)
        } catch {
            scanError = error.localizedDescription
        }
    }

    public func loadPorts() async {
        guard !isLoadingPorts else { return }
        isLoadingPorts = true
        portsError = nil
        defer { isLoadingPorts = false }
        do {
            portsReport = try await service.inspectPorts()
            lastSuccessfulPortsScan = Date()
        }
        catch { portsError = error.localizedDescription }
    }

    public func loadDisk() async {
        guard !isLoadingDisk else { return }
        isLoadingDisk = true
        diskError = nil
        defer { isLoadingDisk = false }
        do {
            diskReport = try await service.inspectDisk()
            lastSuccessfulDiskScan = Date()
        }
        catch { diskError = error.localizedDescription }
    }

    public func requestProcessReview(_ groups: [FindingGroup]) async {
        guard !isStale else {
            scanError = "Check again before closing anything. The last result is old."
            return
        }
        let targets = groups.flatMap(\.targets)
        await requestProcessTargets(targets)
    }

    public func requestProcessTargets(_ targets: [ProcessTarget]) async {
        guard !isStale else {
            scanError = "Check again before closing anything. The last result is old."
            return
        }
        guard !targets.isEmpty, !isReviewing else { return }
        isReviewing = true
        defer { isReviewing = false }
        do {
            let fresh = try await service.planClose(targets: targets)
            let actionable = fresh.actionableFindings
            if actionable.isEmpty {
                if fresh.protectedFindings.isEmpty {
                    receipt = CleanupReceipt(closedCount: 0, cpuFreed: 0, cpuSecondsAlreadyUsed: 0,
                                             message: "Already gone. Nothing to close.")
                } else {
                    receipt = CleanupReceipt(closedCount: 0, cpuFreed: 0, cpuSecondsAlreadyUsed: 0,
                                             message: "Left alone. It now belongs to a protected live session.")
                }
                pendingReview = nil
            } else {
                pendingReview = ActionReview(kind: .processes(actionable), checkedAt: Date())
            }
        } catch {
            scanError = error.localizedDescription
        }
    }

    public func requestPortReview(_ item: PortItem) async {
        guard item.isClosable, !isReviewing else { return }
        isReviewing = true
        defer { isReviewing = false }
        do {
            let fresh = try await service.inspectPort(item.port)
            guard let match = fresh.ports.first(where: {
                $0.pid == item.pid && $0.identity == item.identity && $0.isClosable
            }) else {
                pendingReview = nil
                receipt = CleanupReceipt(closedCount: 0, cpuFreed: 0, cpuSecondsAlreadyUsed: 0,
                                         message: "The listener changed after the scan. Nothing was closed.")
                return
            }
            pendingReview = ActionReview(kind: .port(match), checkedAt: Date())
        } catch {
            portsError = error.localizedDescription
        }
    }

    public func requestDiskReview(_ item: DiskItem) {
        guard item.verdict == "safe", !isActing else { return }
        pendingReview = ActionReview(kind: .disk(item), checkedAt: Date())
    }

    public func cancelReview() {
        pendingReview = nil
    }

    /// One-tap close for the menu bar popover: re-verifies with the engine
    /// (protected sessions are refused there) but skips the review modal.
    public func closeTargetsNow(_ targets: [ProcessTarget]) async {
        guard !isStale else {
            scanError = "Check again before closing anything. The last result is old."
            return
        }
        guard !targets.isEmpty, !isActing else { return }
        isActing = true
        defer { isActing = false }
        do {
            let plan = try await service.planClose(targets: targets)
            let actionable = plan.actionableFindings
            if actionable.isEmpty {
                let message = plan.protectedFindings.isEmpty
                    ? "Already gone. Nothing to close."
                    : "Left alone. It now belongs to a protected live session."
                receipt = CleanupReceipt(closedCount: 0, cpuFreed: 0, cpuSecondsAlreadyUsed: 0, message: message)
            } else {
                let result = try await service.closeReviewed(
                    targets: actionable.map { ProcessTarget(pid: $0.pid, identity: $0.identity) }
                )
                receipt = Self.processReceipt(result, expected: actionable.count)
            }
            await scan()
        } catch {
            scanError = error.localizedDescription
        }
    }

    public func closeGroupNow(_ group: FindingGroup) async {
        await closeTargetsNow(group.targets)
    }

    public func closeEverythingNow() async {
        await closeTargetsNow(groups.flatMap(\.targets))
    }

    public func snoozeGroup(_ groupID: String, minutes: Int = 60) {
        watchdog.snooze(groupID: groupID, minutes: minutes)
        if watchdogEvent != nil { watchdogEvent = nil }
    }

    /// Swap-pressure escape hatch: asks macOS for a normal restart (apps get
    /// a chance to save); nothing is forced.
    public func restartMac() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to restart"]
        try? process.run()
    }

    public func confirmReview() async {
        guard let review = pendingReview, !isActing else { return }
        isActing = true
        defer { isActing = false }
        do {
            switch review.kind {
            case .processes(let findings):
                let result = try await service.closeReviewed(
                    targets: findings.map { ProcessTarget(pid: $0.pid, identity: $0.identity) }
                )
                receipt = Self.processReceipt(result, expected: findings.count)
                await scan()
            case .port(let item):
                let result = try await service.closePort(
                    PortTarget(port: item.port, pid: item.pid, identity: item.identity)
                )
                let action = result.ports.first?.action
                let message: String
                switch action {
                case "killed": message = "Port \(item.port) is free. Machogs closed \(item.process)."
                case "refused-protected": message = "Left alone. The listener now belongs to a protected live session."
                case "identity-changed", nil: message = "The listener changed after review. Nothing was closed."
                default: message = "Machogs could not free port \(item.port). Nothing else was closed."
                }
                receipt = CleanupReceipt(closedCount: action == "killed" ? 1 : 0, cpuFreed: 0,
                                         cpuSecondsAlreadyUsed: 0, message: message,
                                         isSuccess: action == "killed", canShare: false, kind: .port)
                await loadPorts()
            case .disk(let item):
                let result = try await service.clearDisk(path: item.path)
                let amount = result.freedMB >= 1024
                    ? String(format: "%.1f GB", Double(result.freedMB) / 1024)
                    : "\(result.freedMB) MB"
                receipt = CleanupReceipt(closedCount: 0, cpuFreed: 0, cpuSecondsAlreadyUsed: 0,
                                         message: "Cleared \(result.label) and recovered \(amount).",
                                         isSuccess: result.freedMB > 0, canShare: false, kind: .disk)
                await loadDisk()
            }
        } catch {
            switch review.kind {
            case .processes: scanError = error.localizedDescription
            case .port: portsError = error.localizedDescription
            case .disk: diskError = error.localizedDescription
            }
        }
        pendingReview = nil
    }

    public func makeShareCard() async throws -> String {
        try await service.shareCard()
    }

    public func dismissReceipt() {
        receipt = nil
    }

    private static func processReceipt(_ report: EngineReport, expected: Int) -> CleanupReceipt {
        let killed = report.killedFindings
        let protected = report.protectedFindings.count
        let failed = report.findings.filter { $0.action.isActionable }.count
        let accounted = killed.count + protected + failed
        let gone = max(0, expected - accounted)
        let cpu = killed.reduce(0) { $0 + $1.cpu }
        let seconds = killed.reduce(0) { $0 + $1.cpuSeconds }

        var parts: [String] = []
        if !killed.isEmpty { parts.append("Closed \(killed.count).") }
        if gone > 0 { parts.append("\(gone) had already gone.") }
        if protected > 0 { parts.append("\(protected) became protected and was left alone.") }
        if failed > 0 { parts.append("\(failed) could not be closed.") }
        if parts.isEmpty { parts.append("Already gone. Nothing to close.") }
        if cpu >= 20 {
            parts.append("Freed about \(String(format: "%.1f", cpu / 100)) of a CPU core.")
        } else if !killed.isEmpty {
            parts.append("They were wasting memory, not heating your Mac.")
        }
        let phoneCharges = seconds / 9000
        if phoneCharges >= 1 {
            parts.append("They had already burned about \(phoneCharges) phone charge\(phoneCharges == 1 ? "" : "s") of energy.")
        }
        return CleanupReceipt(closedCount: killed.count, cpuFreed: cpu,
                              cpuSecondsAlreadyUsed: seconds, message: parts.joined(separator: " "))
    }
}
