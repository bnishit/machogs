import XCTest
@testable import MachogsCore

@MainActor
final class UsageAnalyticsTests: XCTestCase {
    func testOffByDefaultAndUnavailableBuildsNeverCreateIdentityOrSend() async {
        let (defaults, suite) = storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder()
        let normal = UsageAnalytics(configuration: config(), defaults: defaults, transport: { try await recorder.send($0) })
        XCTAssertFalse(normal.isEnabled)
        await normal.recordActivity()
        for configuration in [nil, config(allowed: false), config(allowed: false, environment: .test)] {
            let analytics = UsageAnalytics(configuration: configuration, defaults: defaults, transport: { try await recorder.send($0) })
            analytics.setEnabled(true)
            XCTAssertFalse(analytics.isEnabled)
            await analytics.recordActivity()
        }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(defaults.object(forKey: "usageAnalytics.state"))
    }

    func testExplicitlyAllowedTestEnvironmentIsTaggedSeparately() async throws {
        let (defaults, suite) = storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder()
        let analytics = UsageAnalytics(configuration: config(environment: .test), defaults: defaults, transport: { try await recorder.send($0) })
        analytics.setEnabled(true)
        await analytics.recordActivity()
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try properties(requests[0])["environment"] as? String, "test")
    }

    func testOptedInUseSendsOnlyAllowlistedFieldsOnceAcrossRelaunch() async throws {
        let (defaults, suite) = storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder()
        let analytics = UsageAnalytics(configuration: config(), defaults: defaults, transport: { try await recorder.send($0) })
        analytics.setEnabled(true)
        await analytics.recordActivity()
        await analytics.recordActivity()
        let reopened = UsageAnalytics(configuration: config(), defaults: defaults, transport: { try await recorder.send($0) })
        await reopened.recordActivity()
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        let events = try requests.map(body)
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["machogs_app_first_seen", "machogs_app_active_week"])
        for (request, event) in zip(requests, events) {
            XCTAssertEqual(Set(event.keys), ["api_key", "event", "uuid", "timestamp", "properties"])
            let properties = try XCTUnwrap(event["properties"] as? [String: Any])
            XCTAssertEqual(Set(properties.keys), ["distinct_id", "app_version", "platform", "environment",
                "installation_kind", "$process_person_profile", "$geoip_disable", "$ip"])
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(properties["distinct_id"] as? String)))
            XCTAssertEqual(properties["platform"] as? String, "macOS")
            XCTAssertEqual(properties["installation_kind"] as? String, "existing_install")
            XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
            XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
            XCTAssertTrue(properties["$ip"] is NSNull)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.timeoutInterval, 5)
        }
        XCTAssertEqual((events[0]["properties"] as? [String: Any])?["distinct_id"] as? String,
                       (events[1]["properties"] as? [String: Any])?["distinct_id"] as? String)
    }

    func testWeeksUseISOUTCBoundariesAndIgnoreClockRollback() async {
        let (defaults, suite) = storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock("2020-12-31T23:59:00Z")
        let recorder = Recorder()
        let analytics = UsageAnalytics(configuration: config(), defaults: defaults,
                                       now: { clock.now() }, transport: { try await recorder.send($0) })
        analytics.setEnabled(true)
        await analytics.recordActivity()
        clock.set("2021-01-01T00:01:00Z")
        await analytics.recordActivity()
        var count = await recorder.requests.count
        XCTAssertEqual(count, 2, "Calendar year changed but ISO week did not")
        clock.set("2021-01-04T00:00:00Z")
        await analytics.recordActivity()
        count = await recorder.requests.count
        XCTAssertEqual(count, 3)
        clock.set("2020-12-31T23:59:00Z")
        await analytics.recordActivity()
        count = await recorder.requests.count
        XCTAssertEqual(count, 3)
    }

    func testFailedDeliveryRetriesSameUUIDAndTimestampAfterRelaunch() async throws {
        let (defaults, suite) = storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder(statuses: [503, 200, 200])
        let analytics = UsageAnalytics(configuration: config(), defaults: defaults, transport: { try await recorder.send($0) })
        analytics.setEnabled(true)
        await analytics.recordActivity()
        let reopened = UsageAnalytics(configuration: config(), defaults: defaults, transport: { try await recorder.send($0) })
        await reopened.recordActivity()
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        let first = try body(requests[0]), retry = try body(requests[1])
        XCTAssertEqual(first["uuid"] as? String, retry["uuid"] as? String)
        XCTAssertEqual(first["timestamp"] as? String, retry["timestamp"] as? String)
        XCTAssertEqual(try body(requests[2])["event"] as? String, "machogs_app_active_week")
    }

    func testOptOutDuringRequestClearsStateAndLateSuccessCannotRestoreIt() async throws {
        let (defaults, suite) = storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder(suspend: true)
        let analytics = UsageAnalytics(configuration: config(), defaults: defaults, transport: { try await recorder.send($0) })
        analytics.setEnabled(true)
        let pending = Task { await analytics.recordActivity() }
        await recorder.waitUntilSuspended()
        analytics.setEnabled(false)
        XCTAssertNil(defaults.object(forKey: "usageAnalytics.state"))
        XCTAssertFalse(analytics.isEnabled)
        // A quick opt-in must not let the cancelled generation write markers.
        analytics.setEnabled(true)
        await recorder.finish()
        await pending.value
        XCTAssertNil(defaults.object(forKey: "usageAnalytics.state"))
        var requests = await recorder.requests
        XCTAssertEqual(requests.count, 1, "Opt-out must stop the subsequent weekly event")
        let oldID = try properties(requests[0])["distinct_id"] as? String
        await analytics.recordActivity()
        requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotEqual(oldID, try properties(requests[1])["distinct_id"] as? String)
    }

    func testConcurrentForegroundSignalsShareOneDelivery() async {
        let (defaults, suite) = storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder(suspend: true)
        let analytics = UsageAnalytics(configuration: config(), defaults: defaults, transport: { try await recorder.send($0) })
        analytics.setEnabled(true)
        let first = Task { await analytics.recordActivity() }
        await recorder.waitUntilSuspended()
        let second = Task { await analytics.recordActivity() }
        await recorder.finish()
        await first.value
        await second.value
        let count = await recorder.requests.count
        XCTAssertEqual(count, 2)
    }

    private func config(allowed: Bool = true, environment: UsageAnalytics.Environment = .production) -> UsageAnalytics.Configuration {
        .init(captureURL: URL(string: "https://example.invalid/capture/")!, projectToken: "public-project-token",
              appVersion: "1.2.3", environment: environment, allowsCollection: allowed)
    }
    private func storage() -> (UserDefaults, String) {
        let suite = "UsageAnalyticsTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func properties(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(body(request)["properties"] as? [String: Any])
    }
}

private actor Recorder {
    private(set) var requests: [URLRequest] = []
    var statuses: [Int]
    var suspend: Bool
    var pending: CheckedContinuation<Int, Never>?
    var waiting: CheckedContinuation<Void, Never>?
    init(statuses: [Int] = [], suspend: Bool = false) { self.statuses = statuses; self.suspend = suspend }
    func send(_ request: URLRequest) async throws -> Int {
        requests.append(request)
        if suspend {
            return await withCheckedContinuation {
                pending = $0
                waiting?.resume()
                waiting = nil
            }
        }
        return statuses.isEmpty ? 200 : statuses.removeFirst()
    }
    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finish() { suspend = false; pending?.resume(returning: 200); pending = nil }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ value: String) { date = ISO8601DateFormatter().date(from: value)! }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        date = ISO8601DateFormatter().date(from: value)!
    }
}
