import XCTest
@testable import MachogsCore

final class ScanPresentationTests: XCTestCase {
    @MainActor
    func testOverlappingRulesKeepOverviewGroupsAndReviewCountInAgreement() async {
        let first = finding(cpu: 15, action: .reapable)
        let strongest = finding(cpu: 30, action: .needsDuplicatesFlag, section: "2b")
        let duplicate = finding(cpu: 30, action: .reapable, section: "3")
        let result = report([first, strongest, duplicate])
        XCTAssertEqual(result.actionableFindings, [strongest])
        XCTAssertEqual(result.groups.flatMap(\.members), [strongest])
        let service = SuspendedRetryService(report: result)
        let model = AppModel(service: service)
        await model.scan()
        await model.requestProcessReview(model.groups)
        XCTAssertEqual(model.scanPresentation.actionableCount, 1)
        XCTAssertEqual(model.pendingReview?.itemCount, 1)
        XCTAssertEqual(model.pendingReview?.processGroups.flatMap(\.targets),
                       [ProcessTarget(pid: strongest.pid, identity: strongest.identity)])
    }

    @MainActor
    func testProtectionWinsOverAnOverlappingActionableRule() async {
        for protectedAction in [FindingAction.protected, .neverKilled] {
            let result = report([
                finding(cpu: 80, action: .reapable),
                finding(cpu: 0, action: protectedAction, section: "5")
            ])
            XCTAssertTrue(result.actionableFindings.isEmpty)
            XCTAssertTrue(result.groups.isEmpty)
            let model = AppModel(service: SuspendedRetryService(report: result))
            await model.scan()
            await model.requestProcessTargets([ProcessTarget(pid: 42, identity: "stable")])
            XCTAssertEqual(model.scanPresentation.actionableCount, 0)
            XCTAssertEqual(model.scanPresentation.protectedCount, 1)
            XCTAssertNil(model.pendingReview)
        }
    }

    @MainActor
    func testFailedScanStaysStaleUntilRetryActuallySucceeds() async {
        let service = SuspendedRetryService(report: report([finding(cpu: 0, action: .reapable)]))
        let model = AppModel(service: service)
        await model.scan()
        await model.scan()
        XCTAssertTrue(model.isStale)
        let retry = Task { await model.scan() }
        await service.waitForRetry()
        XCTAssertTrue(model.isScanning)
        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.scanPresentation.state, .stale)
        await model.closeEverythingNow()
        let closeCount = await service.closeCount
        XCTAssertEqual(closeCount, 0, "A retry must not enable closing cached findings")
        await service.finishRetry()
        await retry.value
        XCTAssertFalse(model.isStale)
        XCTAssertNil(model.scanError)
    }

    func testInitialAndFirstScanCannotClaimFreshResult() {
        for scanning in [false, true] {
            let value = ScanPresentation(report: nil, isScanning: scanning, scanError: nil)
            XCTAssertEqual(value.state, scanning ? .checking : .initial)
            XCTAssertFalse(value.canClaimFreshResult)
        }
    }

    func testIdleProtectedWorkIsVisibleButNotCalledHeat() {
        let value = presentation([finding(cpu: 0)])
        XCTAssertEqual(value.state, .protectedWork)
        XCTAssertEqual(value.protectedCount, 1)
        XCTAssertFalse(value.protectedIsBusy)
        XCTAssertEqual(value.actionableCount, 0)
        XCTAssertTrue(value.detail.contains("mostly idle"))
    }

    func testBusyProtectedProcessIsCountedOnceAcrossDetectorRules() {
        let value = presentation([finding(cpu: 90), finding(cpu: 95, section: "2b")])
        XCTAssertEqual(value.protectedCount, 1)
        XCTAssertEqual(value.protectedCPU, 95)
        XCTAssertTrue(value.protectedIsBusy)
        XCTAssertEqual(value.title, "Protected work is using CPU")
    }

    func testDistinctIdentitiesAndNeverKilledSessionsAreIncluded() {
        let value = presentation([
            finding(cpu: 10), finding(cpu: 15, identity: "other", action: .neverKilled)
        ])
        XCTAssertEqual(value.protectedCount, 2)
        XCTAssertEqual(value.protectedCPU, 25)
    }

    func testFailedRefreshOfEmptyReportCannotSayAllClear() {
        let value = ScanPresentation(report: report([]), isScanning: false, scanError: "offline")
        XCTAssertEqual(value.state, .stale)
        XCTAssertFalse(value.canClaimFreshResult)
        let retry = ScanPresentation(report: report([]), isScanning: true, scanError: "offline")
        XCTAssertEqual(retry.state, .stale)
    }

    func testRefreshWithoutErrorStillLabelsCachedResult() {
        let value = ScanPresentation(report: report([]), isScanning: true, scanError: nil)
        XCTAssertEqual(value.state, .refreshing)
        XCTAssertFalse(value.canClaimFreshResult)
    }

    func testSwapWarningSurvivesZeroActionableFindings() {
        let value = presentation([], swap: 95)
        XCTAssertEqual(value.state, .memoryPressure)
        XCTAssertTrue(value.hasSwapPressure)
        XCTAssertEqual(value.actionableCount, 0)
    }

    func testActionableWorkDoesNotHideProtectedTotals() {
        let value = presentation([finding(cpu: 40), finding(cpu: 0, identity: "cleanup", action: .reapable)])
        XCTAssertEqual(value.state, .actionable)
        XCTAssertEqual(value.actionableCount, 1)
        XCTAssertEqual(value.protectedCount, 1)
        XCTAssertEqual(presentation([]).state, .quiet)
    }

    private func presentation(_ findings: [Finding], swap: Int = 0) -> ScanPresentation {
        ScanPresentation(report: report(findings, swap: swap), isScanning: false, scanError: nil)
    }

    private func report(_ findings: [Finding], swap: Int = 0) -> EngineReport {
        EngineReport(mode: "report", host: HostSnapshot(load: 1, cores: 10, swapUsedMB: 0,
            swapTotalMB: 100, swapPercent: swap, uptimeDays: 1),
            summary: ReportSummary(reapable: 0, killed: 0), findings: findings)
    }

    private func finding(cpu: Double, identity: String = "stable", action: FindingAction = .protected,
                         section: String = "1b") -> Finding {
        Finding(pid: 42, identity: identity, section: section, action: action, cpu: cpu,
                cpuSeconds: 100, age: "01:00", owner: "Codex", what: "coding helper",
                detail: "Live work", story: "Codex has a live helper. It stays protected.")
    }
}

private actor SuspendedRetryService: MachogsServing {
    let report: EngineReport
    private var scanCount = 0
    private var retry: CheckedContinuation<EngineReport, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var closeCount = 0

    init(report: EngineReport) { self.report = report }

    func scan() async throws -> EngineReport {
        scanCount += 1
        if scanCount == 1 { return report }
        if scanCount == 2 { throw MachogsClientError.invalidResponse }
        return await withCheckedContinuation {
            retry = $0
            waiting?.resume()
            waiting = nil
        }
    }
    func waitForRetry() async {
        if retry != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finishRetry() { retry?.resume(returning: report); retry = nil }
    func planClose(targets: [ProcessTarget]) async throws -> EngineReport { report }
    func closeReviewed(targets: [ProcessTarget]) async throws -> EngineReport { closeCount += 1; return report }
    func inspectPorts() async throws -> PortsReport { throw MachogsClientError.invalidResponse }
    func inspectPort(_ port: Int) async throws -> PortsReport { throw MachogsClientError.invalidResponse }
    func closePort(_ target: PortTarget) async throws -> PortsReport { throw MachogsClientError.invalidResponse }
    func inspectDisk() async throws -> DiskReport { throw MachogsClientError.invalidResponse }
    func clearDisk(path: String) async throws -> DiskClearResult { throw MachogsClientError.invalidResponse }
    func shareCard() async throws -> String { "" }
}
