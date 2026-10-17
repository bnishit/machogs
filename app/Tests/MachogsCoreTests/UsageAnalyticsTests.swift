import XCTest
@testable import MachogsCore

@MainActor
final class UsageAnalyticsTests: XCTestCase {
    func testDefaultOffUnavailableBuildAndOldConsentNeverSend() async {
        let (defaults, suite) = storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "usageAnalytics.enabled")
        let recorder = Recorder()
        let usage = UsageAnalytics(defaults: defaults, transport: { try await recorder.send($0) })
        usage.track("app.opened")
        await usage.waitForPending()
        XCTAssertFalse(usage.isEnabled)
        XCTAssertNil(defaults.string(forKey: "anonymousUsageInstallID"))
        let unavailable = UsageAnalytics(defaults: defaults, allowsCollection: false, transport: { try await recorder.send($0) })
        unavailable.setEnabled(true)
        unavailable.track("scan.completed")
        await unavailable.waitForPending()
        XCTAssertFalse(unavailable.isEnabled)
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOptInPayloadThrottleBoundsAndReset() async throws {
        let (defaults, suite) = storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder()
        let usage = UsageAnalytics(defaults: defaults, version: "1.4.2", transport: { try await recorder.send($0) })
        usage.setEnabled(true)
        usage.track("app.opened")
        usage.track("scan.completed", feature: .process, count: 999999, durationMS: .infinity)
        usage.track("scan.completed", feature: .process)
        usage.track("private process name")
        await usage.waitForPending()
        var requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        let payloads = try requests.map(body)
        for (request, payload) in zip(requests, payloads) {
            XCTAssertEqual(Set(payload.keys), ["id", "install_id", "consent", "event", "version", "feature", "outcome", "count", "duration_ms"])
            XCTAssertEqual(payload["consent"] as? Bool, true)
            XCTAssertEqual(payload["version"] as? String, "1.4.2")
            XCTAssertEqual(request.url?.absoluteString, "https://native-analytics-production.up.railway.app/v1/relay/machogs")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.timeoutInterval, 2)
        }
        let scan = try XCTUnwrap(payloads.first { $0["event"] as? String == "scan.completed" })
        XCTAssertEqual(scan["count"] as? Int, 100000)
        XCTAssertEqual(scan["duration_ms"] as? Double, 0)
        let firstID = payloads[0]["install_id"] as? String
        usage.setEnabled(false)
        XCTAssertNil(defaults.object(forKey: "anonymousUsageInstallID"))
        usage.track("app.opened")
        await usage.waitForPending()
        usage.setEnabled(true)
        await usage.waitForPending()
        requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotEqual(firstID, try body(requests[2])["install_id"] as? String)
    }

    func testOptOutCancelsInFlightAndLateSuccessDoesNotRestoreIdentity() async throws {
        let (defaults, suite) = storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder(suspend: true)
        let usage = UsageAnalytics(defaults: defaults, transport: { try await recorder.send($0) })
        usage.setEnabled(true)
        await recorder.waitUntilSuspended()
        let firstID = defaults.string(forKey: "anonymousUsageInstallID")
        usage.setEnabled(false)
        await recorder.finish()
        XCTAssertFalse(usage.isEnabled)
        XCTAssertNil(defaults.object(forKey: "anonymousUsageInstallID"))
        usage.setEnabled(true)
        await usage.waitForPending()
        XCTAssertNotEqual(firstID, defaults.string(forKey: "anonymousUsageInstallID"))
        let cancelled = await recorder.cancelled
        XCTAssertTrue(cancelled)
    }

    private func storage() -> (UserDefaults, String) {
        let suite = "UsageAnalyticsTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
}

private actor Recorder {
    private(set) var requests: [URLRequest] = []
    private(set) var cancelled = false
    var suspend: Bool
    var pending: CheckedContinuation<Int, Never>?
    var waiting: CheckedContinuation<Void, Never>?
    var finished: CheckedContinuation<Void, Never>?
    init(suspend: Bool = false) { self.suspend = suspend }
    func send(_ request: URLRequest) async throws -> Int {
        requests.append(request)
        if suspend {
            let status = await withCheckedContinuation { continuation in
                pending = continuation
                waiting?.resume()
                waiting = nil
            }
            cancelled = Task.isCancelled
            finished?.resume()
            finished = nil
            return status
        }
        return 200
    }
    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finish() async {
        suspend = false
        pending?.resume(returning: 200)
        pending = nil
        await withCheckedContinuation { finished = $0 }
    }
}
