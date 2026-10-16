import XCTest
@testable import MachogsCore

final class UsageAnalyticsTests: XCTestCase {
    @MainActor func testDefaultOffDoesNotCreateIdentityOrSend() {
        let name = "analytics-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var events: [UsageAnalytics.Envelope] = []
        let usage = UsageAnalytics(defaults: defaults, send: { events.append($0) })
        usage.track("app.opened")
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(defaults.string(forKey: "anonymousUsageInstallID"))
    }
    @MainActor func testOptInFixedPayloadThrottleAndOptOutReset() throws {
        let name = "analytics-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var events: [UsageAnalytics.Envelope] = []
        let usage = UsageAnalytics(defaults: defaults, send: { events.append($0) })
        usage.setEnabled(true)
        let first = events[0].install_id
        usage.track("scan.completed", feature: .process, count: 5)
        usage.track("scan.completed", feature: .process, count: 6)
        usage.track("private process name")
        XCTAssertEqual(events.count, 2)
        let payload = String(data: try JSONEncoder().encode(events[1]), encoding: .utf8)!
        XCTAssertFalse(payload.contains("pid")); XCTAssertFalse(payload.contains("path"))
        usage.setEnabled(false); usage.track("app.opened")
        XCTAssertEqual(events.count, 2)
        usage.setEnabled(true)
        XCTAssertNotEqual(events.last!.install_id, first)
    }
}
