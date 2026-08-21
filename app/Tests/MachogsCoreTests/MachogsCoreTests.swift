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


    func testFindingWithoutMemoryKeyStillDecodes() throws {
        // an older engine on the PATH emits no memory_mb — its reports must
        // keep parsing, with memory read as simply unknown
        let report = try fixture([finding(pid: 10, identity: "a")])
        XCTAssertEqual(report.findings.first?.memoryMB, 0)
    }

    func testFindingCarriesMemoryWhenTheEngineSaysIt() throws {
        let report = try fixture([finding(pid: 10, identity: "a", memoryMB: 7102)])
        XCTAssertEqual(report.findings.first?.memoryMB, 7102)
    }

    func testGroupAddsUpMemoryAcrossMembers() throws {
        let report = try fixture([
            finding(pid: 10, identity: "a", memoryMB: 700),
            finding(pid: 11, identity: "b", memoryMB: 500),
            finding(pid: 12, identity: "c")
        ])
        XCTAssertEqual(report.groups.first?.totalMemoryMB, 1200)
        XCTAssertEqual(report.groups.first?.memoryText, "1.2 GB")
    }

    func testWatchdogCloneRuleRefiresAsTheArmyGrows() throws {
        // The old rule was edge-triggered on crossing 8 and then watched a
        // swarm grow 8 -> 49 in silence. Growth must re-arm it.
        let clock = TestClock()
        var policy = WatchdogPolicy(cooldown: 30 * 60, now: { clock.now })
        func swarm(_ n: Int) throws -> EngineReport {
            try fixture((1...n).map { finding(pid: $0, identity: "id\($0)", cpu: 0) })
        }
        _ = policy.evaluate(try fixture([]))
        var fired = 0
        for count in [8, 20, 49] {
            clock.now += 31 * 60
            if policy.evaluate(try swarm(count))?.kind == .clones { fired += 1 }
        }
        XCTAssertEqual(fired, 3, "each growth step past the last notification deserves its own tap")
        clock.now += 31 * 60
        XCTAssertNil(policy.evaluate(try swarm(49)), "no growth, no nag")
    }

    func testWatchdogCloneRuleStillRespectsCooldown() throws {
        let clock = TestClock()
        var policy = WatchdogPolicy(cooldown: 30 * 60, now: { clock.now })
        func swarm(_ n: Int) throws -> EngineReport {
            try fixture((1...n).map { finding(pid: $0, identity: "id\($0)", cpu: 0) })
        }
        _ = policy.evaluate(try fixture([]))
        clock.now += 31 * 60
        XCTAssertEqual(policy.evaluate(try swarm(8))?.kind, .clones)
        clock.now += 60
        XCTAssertNil(policy.evaluate(try swarm(20)), "growth inside the cooldown stays quiet")
    }

    // The whole point of report-only: a memory hog can be big enough to tap a
    // shoulder about and still never reach anything that closes it. A fat idle
    // process is as often an editor holding unsaved work as it is a leak.
    func testMemoryHogIsNeverOfferedForClosing() throws {
        let report = try fixture([finding(pid: 10, identity: "a", action: "report-only", cpu: 0, memoryMB: 7102)])
        XCTAssertTrue(report.actionableFindings.isEmpty, "a hoarder must not be reapable")
        XCTAssertTrue(report.groups.isEmpty, "and must not reach the kill flows")
        XCTAssertEqual(report.memoryGroups.count, 1, "but the watchdog still sees it")
        XCTAssertEqual(report.memoryGroups.first?.totalMemoryMB, 7102)
    }

    func testWatchdogTapsAFatIdleGroupWhenSwapIsHigh() throws {
        let clock = TestClock()
        var policy = WatchdogPolicy(cooldown: 30 * 60, now: { clock.now })
        let hog = try fixture([finding(pid: 10, identity: "a", action: "report-only", cpu: 0, memoryMB: 7102)], swapPct: 92)
        XCTAssertNil(policy.evaluate(hog), "first poll is only a baseline")
        clock.now += 31 * 60
        let event = policy.evaluate(hog)
        XCTAssertEqual(event?.kind, .memory)
        XCTAssertEqual(event?.title, "Found what's eating your memory")
        clock.now += 31 * 60
        XCTAssertNil(policy.evaluate(hog), "the same hog should not nag every poll")
    }

    func testWatchdogIgnoresAMerelyLargeGroupWhenSwapIsCalm() throws {
        let clock = TestClock()
        var policy = WatchdogPolicy(cooldown: 30 * 60, now: { clock.now })
        let hog = try fixture([finding(pid: 10, identity: "a", action: "report-only", cpu: 0, memoryMB: 1400)], swapPct: 20)
        _ = policy.evaluate(hog)
        clock.now += 31 * 60
        XCTAssertNil(policy.evaluate(hog), "1.4 GB with no swap pressure is a curiosity, not an emergency")
    }

    func testMemoryRollupDecodesAndRanksApps() throws {
        let report = try memoryReportFixture()
        XCTAssertEqual(report.apps.map(\.app), ["ChatGPT", "Xcode"])
        XCTAssertEqual(report.apps[0].memoryMB, 10074)
        XCTAssertEqual(report.apps[0].coldPercent, 93)
        XCTAssertEqual(report.apps[0].biggestProcess?.name, "codex")
        XCTAssertEqual(report.apps[0].biggestProcess?.memoryText, "6.9 GB")
        XCTAssertEqual(report.host.swapPercent, 92)
        XCTAssertEqual(report.hoardingApps.map(\.app), ["ChatGPT"])
    }

    func testHoardingRuleFiresOnColdMemoryNotOnSize() {
        // the incident: 94% of the footprint compressed away = sitting on garbage
        XCTAssertTrue(MemoryApp.isHoarding(memoryMB: 10074, compressedMB: 9421, processCount: 3))
        // the false-positive that must NOT fire: Xcode mid-build, huge but warm
        XCTAssertFalse(MemoryApp.isHoarding(memoryMB: 9800, compressedMB: 500, processCount: 6))
        // 100 processes is damning on its own, warm or not
        XCTAssertTrue(MemoryApp.isHoarding(memoryMB: 5000, compressedMB: 500, processCount: 100))
        // small and cold is just a well-behaved idle app
        XCTAssertFalse(MemoryApp.isHoarding(memoryMB: 900, compressedMB: 850, processCount: 2))
    }

    func testEnergyRollupDecodesAndRanksApps() throws {
        let report = try energyReportFixture()
        XCTAssertEqual(report.apps.map(\.app), ["Codex", "Zoom", "Finder"])
        XCTAssertEqual(report.apps[0].minutesPerHour, 34.6)
        XCTAssertEqual(report.apps[0].biggestProcess?.name, "codex")
        XCTAssertEqual(report.worstApp?.app, "Codex")
        // Finder costs 0.4 minutes an hour, which is not an answer to anyone's
        // question and must not take up a row
        XCTAssertEqual(report.appsWorthNaming.map(\.app), ["Codex", "Zoom"])
        XCTAssertEqual(report.power.chargePercent, 62)
        XCTAssertTrue(report.power.onBattery)
    }

    // The one thing this feature must never do: put macOS's own unitless
    // "Energy Impact" number, or any bare score, in front of a person.
    func testBatteryCostIsAlwaysSpokenInMinutes() throws {
        XCTAssertEqual(batteryMinutesText(34.6), "about 35 minutes")
        XCTAssertEqual(batteryMinutesText(4.2), "about 4 minutes")
        XCTAssertEqual(batteryMinutesText(1.2), "about a minute")
        // never "0 minutes", which reads like the measurement failed
        XCTAssertEqual(batteryMinutesText(0.4), "under a minute")
        let report = try energyReportFixture()
        XCTAssertEqual(report.apps[0].drainText, "about 35 minutes an hour")
        XCTAssertEqual(report.apps[0].biggestProcess?.drainText, "about 21 minutes an hour")
    }

    // Plugged in there is no drain to report. The same cost has to be stated
    // as what it WOULD take, never as a live drain that is not happening.
    func testPluggedInReportsWhatItWouldCostRatherThanAFakeDrain() throws {
        let onBattery = try energyReportFixture()
        let codex = onBattery.apps[0]
        XCTAssertEqual(onBattery.costSentence(for: codex),
                       "Codex is costing you about 35 minutes of battery every hour.")
        XCTAssertEqual(onBattery.power.summary, "On battery, 62% left, about 3 hours 10 minutes to go.")

        let plugged = try energyReportFixture(onBattery: false)
        XCTAssertEqual(plugged.costSentence(for: codex),
                       "Unplugged, Codex would cost you about 35 minutes of battery every hour.")
        XCTAssertEqual(plugged.power.summary, "Plugged in and charging, 62%. Nothing is draining right now.")
        XCTAssertTrue(plugged.power.wattsEstimated, "there is nothing to measure while the wall is paying")
    }

    func testDrainingRuleNeedsSustainedCostNotABusyMoment() {
        // the case worth warning about: a helper that has never stopped
        XCTAssertTrue(EnergyApp.isDraining(minutesPerHour: 34.6, cpuSeconds: 20_000, lifetimeSeconds: 40_000))
        // the slander that must NOT fire: the video call you are on right now.
        // Expensive this minute, idle for the eight hours it has been open.
        XCTAssertFalse(EnergyApp.isDraining(minutesPerHour: 22.0, cpuSeconds: 600, lifetimeSeconds: 28_800))
        // and an app that has only just launched gets its half hour of grace
        XCTAssertFalse(EnergyApp.isDraining(minutesPerHour: 30.0, cpuSeconds: 500, lifetimeSeconds: 600))
        // cheap, however long it has been going
        XCTAssertFalse(EnergyApp.isDraining(minutesPerHour: 2.0, cpuSeconds: 30_000, lifetimeSeconds: 40_000))
    }

    @MainActor
    func testEnergyPageLoadsAndNeverOffersToCloseAnything() async throws {
        let report = try fixture([finding(pid: 10, identity: "a")])
        let fake = FakeService(scanReport: report, planReport: report, closeReport: report)
        fake.energyReport = try energyReportFixture()
        let model = AppModel(service: fake)

        await model.loadEnergy()
        XCTAssertEqual(model.energyReport?.worstApp?.app, "Codex")
        XCTAssertEqual(model.energyReport?.drainingApps.map(\.app), ["Codex"])
        XCTAssertNil(model.energyError)
        XCTAssertTrue(fake.closeTargets.isEmpty, "nothing on the battery screen closes anything")
    }

    private func fixture(_ findings: [String], mode: String = "report", killed: Int = 0, swapPct: Int = 10) throws -> EngineReport {
        let data = """
        {"mode":"\(mode)","host":{"load":1.5,"cores":8,"swap_used_mb":10,"swap_total_mb":100,"swap_pct":\(swapPct),"uptime_days":2},"summary":{"reapable":\(findings.count),"killed":\(killed)},"findings":[\(findings.joined(separator: ","))]}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(EngineReport.self, from: data)
    }

    // memoryMB is nil by default so most fixtures look like an OLDER engine's
    // JSON (no memory_mb key) — decoding them at all IS the back-compat test.
    private func finding(pid: Int, identity: String, action: String = "reapable", owner: String = "ChatGPT", what: String = "browser helper", story: String = "ChatGPT left a helper behind.", cpu: Double = 0, memoryMB: Int? = nil) -> String {
        let memory = memoryMB.map { ",\"memory_mb\":\($0)" } ?? ""
        return """
        {"pid":\(pid),"identity":"\(identity)","section":"2","action":"\(action)","cpu":\(cpu),"cpu_seconds":12,"age":"01:00:00","owner":"\(owner)","what":"\(what)","detail":"orphaned helper","story":"\(story)"\(memory)}
        """
    }

    private func memoryReportFixture() throws -> MemoryReport {
        let data = """
        {"mode":"memory","host":{"load":4.0,"cores":10,"swap_used_mb":17934,"swap_total_mb":19456,"swap_pct":92,"uptime_days":24},
         "apps":[
          {"app":"ChatGPT","memory_mb":10074,"compressed_mb":9421,"cold_pct":93,"processes":100,"oldest_age":"2 days","hoarding":true,
           "procs":[{"pid":98965,"name":"codex","memory_mb":7102,"compressed_mb":6664,"age":"2 days"},
                    {"pid":98978,"name":"Codex Renderer","memory_mb":2370,"compressed_mb":2226,"age":"2 days"}]},
          {"app":"Xcode","memory_mb":9800,"compressed_mb":500,"cold_pct":5,"processes":6,"oldest_age":"1 hour","hoarding":false,
           "procs":[{"pid":510,"name":"Xcode","memory_mb":9800,"compressed_mb":500,"age":"1 hour"}]}
        ]}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(MemoryReport.self, from: data)
    }

    private func energyReportFixture(onBattery: Bool = true) throws -> EnergyReport {
        let power = onBattery
            ? """
              {"battery_present":true,"on_battery":true,"charging":false,"charge_pct":62,
               "time_left":"about 3 hours 10 minutes","watts":24.1,"watts_estimated":false,"busy_cores":2.5}
              """
            : """
              {"battery_present":true,"on_battery":false,"charging":true,"charge_pct":62,
               "time_left":"","watts":32.6,"watts_estimated":true,"busy_cores":4.1}
              """
        let data = """
        {"mode":"energy","power":\(power),
         "apps":[
          {"app":"Codex","minutes_per_hour":34.6,"share_pct":58,"processes":12,"cpu_seconds":20000,
           "lifetime_seconds":40000,"oldest_age":"11 hours","draining":true,
           "procs":[{"pid":98965,"name":"codex","minutes_per_hour":20.9,"age":"11 hours"},
                    {"pid":98978,"name":"Codex (Renderer)","minutes_per_hour":13.7,"age":"11 hours"}]},
          {"app":"Zoom","minutes_per_hour":22.0,"share_pct":36,"processes":4,"cpu_seconds":600,
           "lifetime_seconds":28800,"oldest_age":"8 hours","draining":false,
           "procs":[{"pid":410,"name":"zoom.us","minutes_per_hour":22.0,"age":"8 hours"}]},
          {"app":"Finder","minutes_per_hour":0.4,"share_pct":1,"processes":1,"cpu_seconds":30,
           "lifetime_seconds":86400,"oldest_age":"1 day","draining":false,
           "procs":[{"pid":511,"name":"Finder","minutes_per_hour":0.4,"age":"1 day"}]}
        ]}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(EnergyReport.self, from: data)
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

/// A hand-cranked clock so cooldown behaviour is tested, not slept through.
private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 0)
}

private final class FakeService: MachogsServing, @unchecked Sendable {
    var scanReport: EngineReport
    var planReport: EngineReport
    var closeReport: EngineReport
    var scanError: Error?
    var diskReport: DiskReport?
    var diskError: Error?
    var diskClearResult: DiskClearResult?
    var portsReport: PortsReport?
    var portsError: Error?
    var memoryReport: MemoryReport?
    var energyReport: EnergyReport?
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
    func inspectEnergy() async throws -> EnergyReport {
        guard let energyReport else { throw MachogsClientError.invalidResponse }
        return energyReport
    }
    func inspectMemory() async throws -> MemoryReport {
        guard let memoryReport else { throw MachogsClientError.invalidResponse }
        return memoryReport
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
