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

    @MainActor
    func testFailedStorageRefreshKeepsTheLastMeasuredAnswer() async throws {
        let report = try fixture([])
        let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
        fake.diskReport = try diskFixture(freedMB: 512).report
        let model = AppModel(service: fake)

        await model.loadDisk()
        fake.diskError = MachogsClientError.invalidResponse
        await model.loadDisk()

        XCTAssertEqual(model.diskReport?.items.first?.label, "App Caches")
        XCTAssertNotNil(model.diskError)
        XCTAssertNotNil(model.lastSuccessfulDiskScan)
        XCTAssertFalse(model.isLoadingDisk)
    }

    @MainActor
    func testPortsLoadKeepsProtectedAndClosableRowsSeparate() async throws {
        let report = try fixture([])
        let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
        fake.portsReport = try portsFixture()
        let model = AppModel(service: fake)

        await model.loadPorts()

        XCTAssertEqual(model.portsReport?.ports.filter(\.isClosable).map(\.port), [3000])
        XCTAssertEqual(model.portsReport?.ports.filter(\.protected).map(\.port), [4000])
        XCTAssertNotNil(model.lastSuccessfulPortsScan)
        XCTAssertFalse(model.isLoadingPorts)
    }

    @MainActor
    func testPortFreeRequestRevalidatesAndOnlyOpensReview() async throws {
        let report = try fixture([])
        let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
        fake.portsReport = try portsFixture()
        let model = AppModel(service: fake)
        let item = fake.portsReport!.ports[0]

        await model.requestPortReview(item)

        XCTAssertEqual(fake.inspectedPorts, [3000])
        XCTAssertEqual(model.pendingReview?.title, "Free port 3000?")
        XCTAssertTrue(fake.closedPortTargets.isEmpty)
    }

    @MainActor
    func testRapidRepeatedPortFreeRequestsCreateOneReview() async throws {
        let report = try fixture([])
        let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
        fake.portsReport = try portsFixture()
        fake.portInspectionDelayNanoseconds = 20_000_000
        let model = AppModel(service: fake)
        let item = fake.portsReport!.ports[0]

        async let first: Void = model.requestPortReview(item)
        async let second: Void = model.requestPortReview(item)
        _ = await (first, second)

        XCTAssertEqual(fake.inspectedPorts, [3000])
        XCTAssertEqual(model.pendingReview?.title, "Free port 3000?")
        XCTAssertTrue(fake.closedPortTargets.isEmpty)
    }

    @MainActor
    func testChangedPortIdentityProducesNoReviewOrClose() async throws {
        let report = try fixture([])
        let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
        let original = try portsFixture(identity: "old").ports[0]
        fake.portsReport = try portsFixture(identity: "new")
        let model = AppModel(service: fake)

        await model.requestPortReview(original)

        XCTAssertNil(model.pendingReview)
        XCTAssertEqual(model.receipt?.message, "The listener changed after the scan. Nothing was closed.")
        XCTAssertTrue(fake.closedPortTargets.isEmpty)
    }

    @MainActor
    func testMemoryMonitorWarnsWithoutOfferingProtectedWorkForCleanup() async throws {
        let empty = try fixture([])
        let fake = FakeService(scanReport: empty, planReport: empty, closeReport: empty)
        fake.memorySnapshot = MemorySnapshot(
            apps: [AppMemory(app: "ChatGPT", memoryMB: 32942, compressedMB: 24000, processCount: 200)],
            physicalMB: 16384, swapUsedMB: 15800)
        let model = AppModel(service: fake)
        await model.sampleMemory()
        XCTAssertEqual(model.watchdogEvent?.kind, .memory)
        XCTAssertTrue(model.watchdogEvent?.targets.isEmpty == true)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertTrue(fake.closeTargets.isEmpty)
        XCTAssertNil(model.memoryScanError)
    }

    private func fixture(_ findings: [String], mode: String = "report", killed: Int = 0) throws -> EngineReport {
        let data = """
        {"mode":"\(mode)","host":{"load":1.5,"cores":8,"swap_used_mb":10,"swap_total_mb":100,"swap_pct":10,"uptime_days":2},"summary":{"reapable":\(findings.count),"killed":\(killed)},"findings":[\(findings.joined(separator: ","))]}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(EngineReport.self, from: data)
    }

    @MainActor
    func testAutomaticCleanupRequiresOptInAndFiveContinuousMinutes() async throws {
        let report = try fixture([finding(pid: 10, identity: "old")])
        let killed = try fixture([finding(pid: 10, identity: "old", action: "killed")], mode: "kill", killed: 1)
        let fake = FakeService(scanReport: report, planReport: report, closeReport: killed)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = AppModel(service: fake, defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000)
        await model.cleanAbandonedHelpers(now: start)
        XCTAssertEqual(fake.abandonedScans, 0)
        model.automaticCleanupEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "automaticAbandonedCleanup"))
        for minute in 0..<5 {
            await model.cleanAbandonedHelpers(now: start.addingTimeInterval(Double(minute * 60)))
            XCTAssertTrue(fake.automaticTargets.isEmpty)
        }
        await model.cleanAbandonedHelpers(now: start.addingTimeInterval(300))
        XCTAssertEqual(fake.automaticTargets, [ProcessTarget(pid: 10, identity: "old")])
        XCTAssertTrue(fake.closeTargets.isEmpty, "Must use the stricter engine path")
        XCTAssertTrue(model.automaticCleanupStatus.contains("Automatically closed 1"))
    }

    @MainActor
    func testAutomaticCleanupResetsOnSleepFailureIdentityChangeOrDisappearance() async throws {
        for change in ["sleep", "failure", "identity", "gone", "disabled"] {
            let report = try fixture([finding(pid: 10, identity: "old")])
            let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
            let model = AppModel(service: fake, defaults: UserDefaults(suiteName: UUID().uuidString)!)
            model.automaticCleanupEnabled = true
            let start = Date(timeIntervalSince1970: 1_000)
            for minute in 0..<5 { await model.cleanAbandonedHelpers(now: start.addingTimeInterval(Double(minute * 60))) }
            switch change {
            case "failure": fake.abandonedError = MachogsClientError.invalidResponse
            case "identity": fake.abandonedReport = try fixture([finding(pid: 10, identity: "new")])
            case "gone": fake.abandonedReport = try fixture([])
            case "disabled": model.automaticCleanupEnabled = false
            default: break
            }
            await model.cleanAbandonedHelpers(now: start.addingTimeInterval(change == "sleep" ? 500 : 300))
            XCTAssertTrue(fake.automaticTargets.isEmpty, change)
        }
    }

    @MainActor
    func testAutomaticCleanupLeavesProtectedDuplicatesAndUnrelatedFindings() async throws {
        let rows = [finding(pid: 10, identity: "live", action: "protected"),
                    finding(pid: 11, identity: "session", action: "never-killed"),
                    finding(pid: 12, identity: "dupe", action: "needs-dupes-flag"),
                    finding(pid: 13, identity: "spinner").replacingOccurrences(of: "\"section\":\"2\"", with: "\"section\":\"1b\"")]
        let report = try fixture(rows)
        let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
        let model = AppModel(service: fake, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        model.automaticCleanupEnabled = true
        for minute in 0...6 { await model.cleanAbandonedHelpers(now: Date(timeIntervalSince1970: Double(1_000 + minute * 60))) }
        XCTAssertTrue(fake.automaticTargets.isEmpty)
    }

    @MainActor
    func testAutomaticCleanupClosesToolsFromChatsGoneStill() async throws {
        let stale = finding(pid: 20, identity: "chat").replacingOccurrences(of: "\"section\":\"2\"", with: "\"section\":\"2c\"")
        let fake = FakeService(scanReport: try fixture([stale]), planReport: try fixture([]), closeReport: try fixture([]))
        let model = AppModel(service: fake, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        model.automaticCleanupEnabled = true
        for minute in 0...5 { await model.cleanAbandonedHelpers(now: Date(timeIntervalSince1970: Double(1_000 + minute * 60))) }
        XCTAssertEqual(fake.automaticTargets, [ProcessTarget(pid: 20, identity: "chat")])
    }

    @MainActor
    func testNoAlertForLeftoversAutomaticCleanupWillClose() async throws {
        let rows = (1...8).map { finding(pid: 100 + $0, identity: "t\($0)").replacingOccurrences(of: "\"section\":\"2\"", with: "\"section\":\"2c\"") }
        for enabled in [true, false] {
            let fake = FakeService(scanReport: try fixture([]), planReport: try fixture([]), closeReport: try fixture([]))
            let model = AppModel(service: fake, defaults: UserDefaults(suiteName: UUID().uuidString)!)
            model.automaticCleanupEnabled = enabled
            await model.scan()
            fake.scanReport = try fixture(rows)
            await model.scan()
            XCTAssertEqual(model.watchdogEvent == nil, enabled, "enabled=\(enabled)")
        }
    }

    func testEveningRecapSummarisesTodayOnly() {
        let log = """
        2026-10-25 21:00:00\tclosed\t1\tChatGPT\tnode\t0.0\t600
        2026-10-26 12:00:00\tclosed\t2\tChatGPT\tautomatic cleanup: node\t0.0\t90
        2026-10-26 13:00:00\tclosed\t3\tChatGPT\tautomatic cleanup: AI tool helper\t0.0\t60
        2026-10-26 14:00:00\tclosed\t4\tCursor\tnode\t0.0\t30
        2026-10-26 15:00:00\tcleared\tnpm cache\t/Users/x/.npm\t2048
        """
        let now = ISO8601DateFormatter().date(from: "2026-10-26T19:00:00Z")!
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let formatterZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        defer { NSTimeZone.default = formatterZone }
        let recap = DailyRecap.make(log: log, now: now, freeGB: 41, removableCopiesMB: 9300, calendar: utc)
        XCTAssertEqual(recap?.title, "Today: 3 leftovers closed")
        XCTAssertEqual(recap?.body, "2 closed on their own, 1 by you. They had used 3 min of CPU. Cleared 2.0 GB of storage. 9.1 GB of old coding copies can go. 41 GB free.")
        XCTAssertEqual(recap?.page, "storage")
        XCTAssertNil(DailyRecap.make(log: "", now: now, freeGB: 200, removableCopiesMB: 0, calendar: utc), "a quiet day sends nothing")
        XCTAssertEqual(DailyRecap.make(log: "", now: now, freeGB: 12, removableCopiesMB: 0, calendar: utc)?.title, "Your Mac is low on space")
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

    private func portsFixture(identity: String = "a") throws -> PortsReport {
        let data = """
        {"mode":"ports","ports":[
          {"port":3000,"pid":10,"identity":"\(identity)","process":"node","owner":"Vite","cwd":"/tmp/project","age":"01:00:00","system":false,"protected":false,"note":"","action":null},
          {"port":4000,"pid":11,"identity":"b","process":"node","owner":"Claude Code","cwd":"/tmp/live","age":"00:10:00","system":false,"protected":true,"note":"Live session","action":null}
        ]}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(PortsReport.self, from: data)
    }
}

private final class FakeService: MachogsServing, @unchecked Sendable {
    var scanReport: EngineReport
    var planReport: EngineReport
    var closeReport: EngineReport
    var memorySnapshot: MemorySnapshot?
    var abandonedReport: EngineReport?
    var abandonedError: Error?
    var automaticTargets: [ProcessTarget] = []
    var abandonedScans = 0
    var scanError: Error?
    var diskReport: DiskReport?
    var diskError: Error?
    var diskClearResult: DiskClearResult?
    var portsReport: PortsReport?
    var portsError: Error?
    var inspectedPorts: [Int] = []
    var closedPortTargets: [PortTarget] = []
    var portInspectionDelayNanoseconds: UInt64 = 0
    var planTargets: [ProcessTarget] = []
    var closeTargets: [ProcessTarget] = []

    init(scanReport: EngineReport, planReport: EngineReport, closeReport: EngineReport) {
        self.scanReport = scanReport
        self.planReport = planReport
        self.closeReport = closeReport
    }

    func scanAbandoned() async throws -> EngineReport {
        abandonedScans += 1
        if let abandonedError { throw abandonedError }
        return abandonedReport ?? scanReport
    }
    func closeAbandoned(targets: [ProcessTarget]) async throws -> EngineReport {
        automaticTargets = targets
        return closeReport
    }
    func inspectMemory() async throws -> MemorySnapshot {
        guard let memorySnapshot else { throw MachogsClientError.invalidResponse }
        return memorySnapshot
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
    func inspectPorts() async throws -> PortsReport {
        if let portsError { throw portsError }
        guard let portsReport else { throw MachogsClientError.invalidResponse }
        return portsReport
    }
    func inspectPort(_ port: Int) async throws -> PortsReport {
        inspectedPorts.append(port)
        if portInspectionDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: portInspectionDelayNanoseconds)
        }
        guard let portsReport else { throw MachogsClientError.invalidResponse }
        return portsReport
    }
    func closePort(_ target: PortTarget) async throws -> PortsReport {
        closedPortTargets.append(target)
        guard let portsReport else { throw MachogsClientError.invalidResponse }
        return portsReport
    }
    func inspectDisk() async throws -> DiskReport {
        if let diskError { throw diskError }
        guard let diskReport else { throw MachogsClientError.invalidResponse }
        return diskReport
    }
    func clearDisk(path: String) async throws -> DiskClearResult {
        guard let diskClearResult else { throw MachogsClientError.invalidResponse }
        return diskClearResult
    }
    func shareCard() async throws -> String { "receipt" }
}
