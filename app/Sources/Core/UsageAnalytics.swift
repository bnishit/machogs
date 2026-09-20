import Foundation

/// Explicit foreground usage only. Scans and background polling must not call this.
@MainActor
public final class UsageAnalytics {
    public enum Environment: String, Sendable { case production, test }
    public enum InstallationKind: String, Codable, Sendable {
        case newInstall = "new_install", existingInstall = "existing_install"
    }

    public struct Configuration: Sendable {
        public let captureURL: URL
        public let projectToken: String
        public let appVersion: String
        public let environment: Environment
        public let installationKind: InstallationKind
        public let allowsCollection: Bool

        public init(captureURL: URL, projectToken: String, appVersion: String,
                    environment: Environment = .production,
                    installationKind: InstallationKind = .existingInstall,
                    allowsCollection: Bool = false) {
            self.captureURL = captureURL
            self.projectToken = projectToken
            self.appVersion = appVersion
            self.environment = environment
            self.installationKind = installationKind
            self.allowsCollection = allowsCollection
        }
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> Int
    public private(set) var isEnabled: Bool
    public let isAvailable: Bool
    private let configuration: Configuration?
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let transport: Transport
    private var state: State?
    private var inFlight: Task<Void, Never>?
    private var generation: UInt = 0
    private static let consentKey = "usageAnalytics.enabled"
    private static let stateKey = "usageAnalytics.state"

    public init(configuration: Configuration?, defaults: UserDefaults = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                transport: @escaping Transport = { try await UsageAnalytics.send($0) }) {
        self.configuration = configuration
        self.defaults = defaults
        self.now = now
        self.transport = transport
        isAvailable = configuration.map {
            $0.allowsCollection &&
            $0.captureURL.scheme == "https" && $0.captureURL.host != nil && !$0.projectToken.isEmpty
        } ?? false
        isEnabled = isAvailable && defaults.bool(forKey: Self.consentKey)
        if isEnabled, let data = defaults.data(forKey: Self.stateKey) {
            state = try? JSONDecoder().decode(State.self, from: data)
        }
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled else {
            isEnabled = false
            generation &+= 1
            inFlight?.cancel()
            inFlight = nil
            state = nil
            defaults.removeObject(forKey: Self.consentKey)
            defaults.removeObject(forKey: Self.stateKey)
            return
        }
        guard isAvailable else { return }
        isEnabled = true
        defaults.set(true, forKey: Self.consentKey)
    }

    /// Awaiting this never blocks the main thread. Failures stay silent and are
    /// retried with the same event UUID on a later foreground interaction.
    public func recordActivity() async {
        guard isEnabled, let configuration else { return }
        if let inFlight { await inFlight.value; return }
        if state == nil { state = State(id: UUID().uuidString, installationKind: configuration.installationKind) }
        let currentGeneration = generation
        let task = Task { await captureActivity(generation: currentGeneration, configuration: configuration) }
        inFlight = task
        await task.value
        if generation == currentGeneration { inFlight = nil }
    }

    private func captureActivity(generation expected: UInt, configuration: Configuration) async {
        guard isCurrent(expected), state != nil else { return }
        let date = now()
        if state?.firstSeenSent == false {
            if state?.first == nil { state?.first = Pending(date: date) }
            persist()
            guard let pending = state?.first,
                  await capture("machogs_app_first_seen", pending: pending, configuration: configuration,
                                generation: expected) else { return }
            state?.firstSeenSent = true
            state?.first = nil
            persist()
        }
        guard isCurrent(expected) else { return }
        let week = Self.week(date)
        // ISO week keys sort chronologically, also avoiding duplicates after a
        // local clock moves backwards. Old failed weeks are not replayed later.
        if let sent = state?.lastWeek, sent >= week { return }
        if state?.weekKey != week {
            state?.weekKey = week
            state?.week = Pending(date: date)
        }
        persist()
        guard let pending = state?.week,
              await capture("machogs_app_active_week", pending: pending, configuration: configuration,
                            generation: expected) else { return }
        state?.lastWeek = week
        state?.weekKey = nil
        state?.week = nil
        persist()
    }

    private func capture(_ event: String, pending: Pending, configuration: Configuration,
                         generation expected: UInt) async -> Bool {
        guard isCurrent(expected), let state else { return false }
        let properties: [String: Any] = [
            "distinct_id": state.id, "app_version": configuration.appVersion,
            "platform": "macOS", "environment": configuration.environment.rawValue,
            "installation_kind": state.installationKind.rawValue,
            "$process_person_profile": false, "$geoip_disable": true, "$ip": NSNull()
        ]
        let body: [String: Any] = [
            "api_key": configuration.projectToken, "event": event, "uuid": pending.id,
            "timestamp": ISO8601DateFormatter().string(from: pending.date), "properties": properties
        ]
        var request = URLRequest(url: configuration.captureURL, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard isCurrent(expected) else { return false }
            let status = try await transport(request)
            return isCurrent(expected) && (200..<300).contains(status)
        } catch { return false }
    }

    private func isCurrent(_ expected: UInt) -> Bool {
        isEnabled && generation == expected && !Task.isCancelled
    }

    private func persist() {
        guard isEnabled, let state, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }

    private static func week(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear!, parts.weekOfYear!)
    }

    public nonisolated static func send(_ request: URLRequest) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private struct Pending: Codable {
        var id = UUID().uuidString
        let date: Date
    }

    private struct State: Codable {
        let id: String
        let installationKind: InstallationKind
        var firstSeenSent = false
        var first: Pending?
        var lastWeek: String?
        var weekKey: String?
        var week: Pending?
    }
}
