import XCTest
@testable import MachogsCore

final class MachogsCoreTests: XCTestCase {
    func testReportGroupsOnlyActionableFindings() throws {
        let report = try fixture([
            finding(pid: 10, identity: "a", action: "reapable", owner: "ChatGPT"),
            finding(pid: 11, identity: "b", action: "protected", owner: "Claude"),
            finding(pid: 12, identity: "c", action: "never-killed", owner: "Claude")
        ])

        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.targets, [ProcessTarget(pid: 10, identity: "a")])
        XCTAssertEqual(report.protectedFindings.count, 2)
    }

    func testGroupsUseStableFactsInsteadOfChangingStoryText() throws {
        let report = try fixture([
            finding(pid: 10, identity: "a", story: "Idle for one hour."),
            finding(pid: 11, identity: "b", story: "Idle for two hours.")
        ])
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.count, 2)
    }

    func testLargeReviewKeepsCulpritsGroupedInsteadOfRenderingEveryProcess() throws {
        let chatGPTBrowser = (1...28).map {
            finding(pid: $0, identity: "browser-\($0)", owner: "ChatGPT", what: "browser-control helper")
        }
        let chatGPTAI = (29...54).map {
            finding(pid: $0, identity: "ai-\($0)", owner: "ChatGPT", what: "AI tool helper")
        }
        let report = try fixture(chatGPTBrowser + chatGPTAI, mode: "plan")
        let review = ActionReview(kind: .processes(report.actionableFindings), checkedAt: Date())

        XCTAssertEqual(review.processGroups.map(\.count), [28, 26])
        XCTAssertEqual(review.processGroups.map(\.owner), ["ChatGPT", "ChatGPT"])
        XCTAssertEqual(review.title, "Close 54 unused things from ChatGPT?")
    }

    func testCloseArgumentsCarryStableIdentityAndNoPIDOnlyTarget() {
        let args = MachogsClient.closeArguments(for: [
            ProcessTarget(pid: 42, identity: "9001"),
            ProcessTarget(pid: 42, identity: "9001"),
            ProcessTarget(pid: 7, identity: "123")
        ])
        XCTAssertEqual(args, ["kill", "--json", "--sessions", "--dupes", "--target=7:123", "--target=42:9001"])
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("--pid=") }))
    }

    func testWatchdogFirstPollIsOnlyABaseline() throws {
        var policy = WatchdogPolicy()
        let hot = try fixture([finding(pid: 10, identity: "a", cpu: 80)])
        XCTAssertNil(policy.evaluate(hot))
    }

    func testWatchdogNeedsTwoHotPollsAndNeverOffersAnAction() throws {
        var policy = WatchdogPolicy()
        let hot = try fixture([finding(pid: 10, identity: "a", cpu: 80)])
        XCTAssertNil(policy.evaluate(hot))
        let event = policy.evaluate(hot)
        XCTAssertEqual(event?.kind, .hot)
        XCTAssertEqual(event?.targets, [ProcessTarget(pid: 10, identity: "a")])
        XCTAssertNil(policy.evaluate(hot), "The same continuously hot group should not nag every minute")
    }

    func testWatchdogCallsIdleClonesMemoryWasteNotFanNoise() throws {
        var policy = WatchdogPolicy()
        _ = policy.evaluate(try fixture([]))
        let clones = try fixture((1...8).map { finding(pid: $0, identity: "id\($0)", cpu: 0) })
        let event = policy.evaluate(clones)
        XCTAssertEqual(event?.kind, .clones)
        XCTAssertFalse(event?.body.localizedCaseInsensitiveContains("fan") ?? true)
    }

    @MainActor
    func testReviewPlansButDoesNotCloseUntilConfirmation() async throws {
        let initial = try fixture([finding(pid: 10, identity: "original")])
        let fresh = try fixture([finding(pid: 10, identity: "original", story: "Fresh engine story.")], mode: "plan")
        let killed = try fixture([finding(pid: 10, identity: "original", action: "killed")], mode: "kill", killed: 1)
        let fake = FakeService(scanReport: initial, planReport: fresh, closeReport: killed)
        let model = AppModel(service: fake)

        await model.scan()
        await model.requestProcessReview(model.groups)
        XCTAssertEqual(fake.planTargets, [ProcessTarget(pid: 10, identity: "original")])
        XCTAssertTrue(fake.closeTargets.isEmpty)
        XCTAssertEqual(model.pendingReview?.title, "Close 1 unused thing from ChatGPT?")

        await model.confirmReview()
        XCTAssertEqual(fake.closeTargets, [ProcessTarget(pid: 10, identity: "original")])
        XCTAssertEqual(model.receipt?.closedCount, 1)
    }

    @MainActor
    func testCancelCreatesNoActionOrReceipt() async throws {
        let report = try fixture([finding(pid: 10, identity: "a")])
        let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
        let model = AppModel(service: fake)
        await model.scan()
        await model.requestProcessReview(model.groups)
        model.cancelReview()

        XCTAssertNil(model.pendingReview)
        XCTAssertNil(model.receipt)
        XCTAssertTrue(fake.closeTargets.isEmpty)
    }

    @MainActor
    func testReusedOrGoneTargetNeverFallsBackToCurrentFindings() async throws {
        let initial = try fixture([finding(pid: 10, identity: "old")])
        let emptyPlan = try fixture([], mode: "plan")
        let fake = FakeService(scanReport: initial, planReport: emptyPlan, closeReport: emptyPlan)
        let model = AppModel(service: fake)
        await model.scan()
        await model.requestProcessReview(model.groups)

        XCTAssertNil(model.pendingReview)
        XCTAssertEqual(model.receipt?.message, "Already gone. Nothing to close.")
        XCTAssertTrue(fake.closeTargets.isEmpty)
    }

    @MainActor
    func testNewlyProtectedTargetIsLeftAlone() async throws {
        let initial = try fixture([finding(pid: 10, identity: "same")])
        let protected = try fixture([finding(pid: 10, identity: "same", action: "protected")], mode: "plan")
        let fake = FakeService(scanReport: initial, planReport: protected, closeReport: protected)
        let model = AppModel(service: fake)
        await model.scan()
        await model.requestProcessReview(model.groups)

        XCTAssertNil(model.pendingReview)
        XCTAssertEqual(model.receipt?.message, "Left alone. It now belongs to a protected live session.")
        XCTAssertTrue(fake.closeTargets.isEmpty)
    }

    @MainActor
    func testFailedRefreshKeepsLastDataButMakesItStale() async throws {
        let report = try fixture([finding(pid: 10, identity: "a")])
        let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
        let model = AppModel(service: fake)
        await model.scan()
        fake.scanError = MachogsClientError.invalidResponse
        await model.scan()

        XCTAssertEqual(model.groups.count, 1)
        XCTAssertTrue(model.isStale)
        await model.requestProcessReview(model.groups)
        XCTAssertNil(model.pendingReview)
        XCTAssertTrue(fake.planTargets.isEmpty)
    }

    @MainActor
    func testDiskClearProducesAnUnshareableSuccessReceipt() async throws {
        let report = try fixture([])
        let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
        let disk = try diskFixture(freedMB: 1536)
        fake.diskReport = disk.report
        fake.diskClearResult = disk.result
        let model = AppModel(service: fake)

        model.requestDiskReview(disk.item)
        await model.confirmReview()

        XCTAssertEqual(model.receipt?.closedCount, 0)
        XCTAssertEqual(model.receipt?.isSuccess, true)
        XCTAssertEqual(model.receipt?.canShare, false)
        XCTAssertEqual(model.receipt?.message, "Cleared App Caches and recovered 1.5 GB.")
    }

    private func fixture(_ findings: [String], mode: String = "report", killed: Int = 0) throws -> EngineReport {
        let data = """
        {"mode":"\(mode)","host":{"load":1.5,"cores":8,"swap_used_mb":10,"swap_total_mb":100,"swap_pct":10,"uptime_days":2},"summary":{"reapable":\(findings.count),"killed":\(killed)},"findings":[\(findings.joined(separator: ","))]}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(EngineReport.self, from: data)
    }

    private func finding(pid: Int, identity: String, action: String = "reapable", owner: String = "ChatGPT", what: String = "browser helper", story: String = "ChatGPT left a helper behind.", cpu: Double = 0) -> String {
        """
        {"pid":\(pid),"identity":"\(identity)","section":"2","action":"\(action)","cpu":\(cpu),"cpu_seconds":12,"age":"01:00:00","owner":"\(owner)","what":"\(what)","detail":"orphaned helper","story":"\(story)"}
        """
    }

    private func diskFixture(freedMB: Int) throws -> (report: DiskReport, item: DiskItem, result: DiskClearResult) {
        let itemJSON = """
        {"label":"App Caches","icon":"🗃️","path":"/tmp/machogs-test-cache","size_mb":2048,"verdict":"safe","how":"Apps can rebuild this."}
        """
        let reportData = """
        {"mode":"disk","disk":{"used_gb":80,"total_gb":100,"pct":80},"items":[\(itemJSON)]}
        """.data(using: .utf8)!
        let resultData = """
        {"mode":"disk-clear","path":"/tmp/machogs-test-cache","label":"App Caches","freed_mb":\(freedMB)}
        """.data(using: .utf8)!
        let report = try JSONDecoder().decode(DiskReport.self, from: reportData)
        let result = try JSONDecoder().decode(DiskClearResult.self, from: resultData)
        return (report, report.items[0], result)
    }
}

private final class FakeService: MachogsServing, @unchecked Sendable {
    var scanReport: EngineReport
    var planReport: EngineReport
    var closeReport: EngineReport
    var scanError: Error?
    var diskReport: DiskReport?
    var diskClearResult: DiskClearResult?
    var planTargets: [ProcessTarget] = []
    var closeTargets: [ProcessTarget] = []

    init(scanReport: EngineReport, planReport: EngineReport, closeReport: EngineReport) {
        self.scanReport = scanReport
        self.planReport = planReport
        self.closeReport = closeReport
    }

    func scan() async throws -> EngineReport {
        if let scanError { throw scanError }
        return scanReport
    }
    func planClose(targets: [ProcessTarget]) async throws -> EngineReport {
        planTargets = targets; return planReport
    }
    func closeReviewed(targets: [ProcessTarget]) async throws -> EngineReport {
        closeTargets = targets; return closeReport
    }
    func inspectPorts() async throws -> PortsReport { throw MachogsClientError.invalidResponse }
    func inspectPort(_ port: Int) async throws -> PortsReport { throw MachogsClientError.invalidResponse }
    func closePort(_ target: PortTarget) async throws -> PortsReport { throw MachogsClientError.invalidResponse }
    func inspectDisk() async throws -> DiskReport {
        guard let diskReport else { throw MachogsClientError.invalidResponse }
        return diskReport
    }
    func clearDisk(path: String) async throws -> DiskClearResult {
        guard let diskClearResult else { throw MachogsClientError.invalidResponse }
        return diskClearResult
    }
    func shareCard() async throws -> String { "receipt" }
}
