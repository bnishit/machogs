import XCTest
@testable import MachogsCore

final class MemoryMonitorTests: XCTestCase {
    func testRollupIncludesColdHelpersAndSeparatesCLIFromTerminal() {
        let processes = """
        10 1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
        11 10 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
        12 11 /opt/homebrew/bin/node
        20 1 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        21 20 /Users/test/.local/bin/claude
        22 21 /opt/homebrew/bin/node
        23 20 /opt/homebrew/bin/codex
        24 23 /opt/homebrew/bin/node
        """
        let metrics = """
        PID MEM CMPRS COMMAND
        10 500M 100M ChatGPT
        11 2G 1500M codex
        12 3G 2500M node
        20 200M 10M Terminal
        21 1G 100M claude
        22 512M 10M node
        23 1G 100M codex
        24 256M 10M node
        """
        let apps = MemoryMonitor.rollup(metrics: metrics, processes: processes)
        XCTAssertEqual(apps.first?.app, "ChatGPT")
        XCTAssertEqual(apps.first?.memoryMB, 5620)
        XCTAssertEqual(apps.first?.compressedMB, 4100)
        XCTAssertEqual(apps.first?.processCount, 3)
        XCTAssertEqual(apps.first { $0.app == "Claude Code" }?.memoryMB, 1536)
        XCTAssertEqual(apps.first { $0.app == "Codex CLI" }?.memoryMB, 1280)
        XCTAssertEqual(MemoryMonitor.megabytes("1.5G+"), 1536)
    }

    func testForceQuitIncidentWarnsImmediatelyWithoutKillTargets() {
        for name in ["ChatGPT", "Codex CLI", "Claude Code", "Claude", "Cursor"] {
            var policy = WatchdogPolicy()
            let event = policy.evaluateMemory(snapshot(name, mb: 32942, count: 200))
            XCTAssertEqual(event?.kind, .memory)
            XCTAssertTrue(event?.targets.isEmpty == true)
            XCTAssertTrue(event?.body.contains(name) == true)
            XCTAssertNil(policy.evaluateMemory(snapshot(name, mb: 32942, count: 200)))
        }
    }

    func testBusyWarmAppIsNotCalledALeak() {
        var policy = WatchdogPolicy()
        XCTAssertNil(policy.evaluateMemory(snapshot("Xcode", mb: 5000, count: 100)))
        XCTAssertNil(policy.evaluateMemory(snapshot("Xcode", mb: 5100, count: 110)))
    }

    func testHelperGrowthTriggersBeforeAppReachesHalfRAM() {
        var policy = WatchdogPolicy()
        XCTAssertNil(policy.evaluateMemory(snapshot("Claude Code", mb: 2000, count: 20)))
        let event = policy.evaluateMemory(snapshot("Claude Code", mb: 2600, count: 36))
        XCTAssertEqual(event?.kind, .memory)
        XCTAssertTrue(event?.body.contains("16 processes") == true)
        XCTAssertTrue(event?.targets.isEmpty == true)
    }

    func testAbsoluteSwapPressureDoesNotDependOnAllocatedSwapPercent() {
        var policy = WatchdogPolicy()
        let event = policy.evaluateMemory(snapshot("ChatGPT", mb: 5000, count: 100, swap: 6000))
        XCTAssertEqual(event?.kind, .memory)
    }

    func testAlreadyLargeCloneGroupCanWarnAfterFurtherGrowth() throws {
        var policy = WatchdogPolicy(cooldown: 0)
        func report(_ count: Int) throws -> EngineReport {
            let findings = (1...count).map { "{\"pid\":\($0),\"identity\":\"id\($0)\",\"section\":\"2b\",\"action\":\"reapable\",\"cpu\":0,\"cpu_seconds\":0,\"age\":\"1:00:00\",\"owner\":\"ChatGPT\",\"what\":\"helper\",\"detail\":\"copies\",\"story\":\"Helpers remain.\"}" }.joined(separator: ",")
            return try JSONDecoder().decode(EngineReport.self, from: Data("{\"mode\":\"report\",\"host\":{\"load\":1,\"cores\":8,\"swap_used_mb\":0,\"swap_total_mb\":0,\"swap_pct\":0,\"uptime_days\":1},\"summary\":{\"reapable\":\(count),\"killed\":0},\"findings\":[\(findings)]}".utf8))
        }
        XCTAssertNil(policy.evaluate(try report(8)))
        XCTAssertEqual(policy.evaluate(try report(8))?.kind, .clones)
        XCTAssertNil(policy.evaluate(try report(9)))
        XCTAssertEqual(policy.evaluate(try report(16))?.kind, .clones)
    }

    func testSnoozeCoversMemoryWarning() {
        var policy = WatchdogPolicy()
        policy.snooze(groupID: "memory|ChatGPT")
        XCTAssertNil(policy.evaluateMemory(snapshot("ChatGPT", mb: 32000, count: 200)))
    }

    func testNativeSamplerReadsRealAppMemory() async throws {
        let sample = try await MemoryMonitor.sample()
        XCTAssertGreaterThan(sample.physicalMB, 0)
        XCTAssertFalse(sample.apps.isEmpty)
        XCTAssertTrue(sample.apps.allSatisfy { $0.processCount > 0 && $0.memoryMB >= 0 })
    }

    func testWorseningMemoryRearmsBeforeOrdinaryCooldown() {
        let clock = MemoryTestClock()
        var policy = WatchdogPolicy(now: { clock.date })
        XCTAssertNotNil(policy.evaluateMemory(snapshot("ChatGPT", mb: 9000, count: 100)))
        clock.date.addTimeInterval(30)
        XCTAssertNil(policy.evaluateMemory(snapshot("ChatGPT", mb: 10500, count: 100)))
        clock.date.addTimeInterval(31)
        XCTAssertNotNil(policy.evaluateMemory(snapshot("ChatGPT", mb: 10500, count: 100)))
    }

    private func snapshot(_ name: String, mb: Int, count: Int, swap: Int = 0) -> MemorySnapshot {
        MemorySnapshot(apps: [AppMemory(app: name, memoryMB: mb, compressedMB: 0, processCount: count)],
                       physicalMB: 16384, swapUsedMB: swap)
    }
}

private final class MemoryTestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 0)
}
