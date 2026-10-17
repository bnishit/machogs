import Foundation

/// Opt-in, fixed-schema usage only. No producer key or inspected Mac data leaves the app.
@MainActor
public final class UsageAnalytics {
    public enum Feature: String, Codable, Sendable { case app, process, ports, disk, memory, energy, settings }
    public enum Outcome: String, Codable, Sendable { case started, success, failure, cancelled }
    public struct Envelope: Codable, Sendable {
        public let id: UUID
        public let install_id: UUID
        public let consent: Bool
        public let event: String
        public let version: String
        public let feature: Feature
        public let outcome: Outcome
        public let count: Int
        public let duration_ms: Double
    }
    public private(set) var isEnabled: Bool
    private let defaults: UserDefaults
    public let isAvailable: Bool
    public typealias Transport = @Sendable (URLRequest) async throws -> Int
    private let transport: Transport
    private let version: String
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var lastScan: [Feature: Date] = [:]

    public init(defaults: UserDefaults = .standard, allowsCollection: Bool = true,
                version: String = "development",
                transport: @escaping Transport = { try await UsageAnalytics.send($0) }) {
        self.defaults = defaults
        self.isAvailable = allowsCollection
        self.version = version
        self.transport = transport
        isEnabled = allowsCollection && defaults.bool(forKey: "anonymousUsageEnabled")
    }

    public nonisolated static func send(_ request: URLRequest) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    public func waitForPending() async {
        for task in pending.values { await task.value }
    }

    public func recordActivity() async { track("app.opened") }

    public func setEnabled(_ value: Bool) {
        isEnabled = value && isAvailable
        defaults.set(isEnabled, forKey: "anonymousUsageEnabled")
        if isEnabled { track("app.opened") }
        else {
            for task in pending.values { task.cancel() }
            pending.removeAll()
            defaults.removeObject(forKey: "anonymousUsageInstallID")
            lastScan.removeAll()
        }
        // Retire the old provider's consent and identity; expanded sharing requires a new choice.
        defaults.removeObject(forKey: "usageAnalytics.enabled")
        defaults.removeObject(forKey: "usageAnalytics.state")
    }

    public func track(_ event: String, feature: Feature = .app, outcome: Outcome = .success,
                      count: Int = 0, durationMS: Double = 0) {
        guard isEnabled, pending.count < 32, ["app.opened", "scan.completed", "action.completed", "screen.opened", "onboarding.completed"].contains(event) else { return }
        if event == "scan.completed" || event == "app.opened" {
            if let last = lastScan[feature], Date().timeIntervalSince(last) < 60 { return }
            lastScan[feature] = Date()
        }
        let id: UUID
        if let value = defaults.string(forKey: "anonymousUsageInstallID"), let existing = UUID(uuidString: value) { id = existing }
        else { id = UUID(); defaults.set(id.uuidString, forKey: "anonymousUsageInstallID") }
        let envelope = Envelope(id: UUID(), install_id: id, consent: true, event: event, version: version,
                      feature: feature, outcome: outcome, count: min(100000, max(0, count)),
                      duration_ms: durationMS.isFinite ? min(3600000, max(0, durationMS)) : 0)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        var request = URLRequest(url: URL(string: "https://native-analytics-production.up.railway.app/v1/relay/machogs")!, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let transport = self.transport
        pending[envelope.id] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            _ = try? await transport(request)
            self?.pending.removeValue(forKey: envelope.id)
        }
    }
}
