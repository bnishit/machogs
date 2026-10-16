import Foundation

/// Opt-in, fixed-schema usage only. No producer key or inspected Mac data leaves the app.
@MainActor
public final class UsageAnalytics {
    public static let shared = UsageAnalytics()
    public enum Feature: String, Codable { case app, process, ports, disk, memory, energy, settings }
    public enum Outcome: String, Codable { case started, success, failure, cancelled }
    public struct Envelope: Codable {
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
    public private(set) var enabled: Bool
    private let defaults: UserDefaults
    private let send: (Envelope) -> Void
    private var lastScan: [Feature: Date] = [:]

    public init(defaults: UserDefaults = .standard, send: ((Envelope) -> Void)? = nil) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "anonymousUsageEnabled")
        self.send = send ?? { envelope in
            guard let url = URL(string: "https://native-analytics-production.up.railway.app/v1/relay/machogs"),
                  let data = try? JSONEncoder().encode(envelope) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 2
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            Task { _ = try? await URLSession.shared.data(for: request) }
        }
    }

    public func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "anonymousUsageEnabled")
        if value { track("app.opened") }
        else { defaults.removeObject(forKey: "anonymousUsageInstallID"); lastScan.removeAll() }
    }

    public func track(_ event: String, feature: Feature = .app, outcome: Outcome = .success,
                      count: Int = 0, durationMS: Double = 0) {
        guard enabled, ["app.opened", "scan.completed", "action.completed", "screen.opened", "onboarding.completed"].contains(event) else { return }
        if event == "scan.completed" {
            if let last = lastScan[feature], Date().timeIntervalSince(last) < 60 { return }
            lastScan[feature] = Date()
        }
        let id: UUID
        if let value = defaults.string(forKey: "anonymousUsageInstallID"), let existing = UUID(uuidString: value) { id = existing }
        else { id = UUID(); defaults.set(id.uuidString, forKey: "anonymousUsageInstallID") }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        send(Envelope(id: UUID(), install_id: id, consent: true, event: event, version: version,
                      feature: feature, outcome: outcome, count: min(100000, max(0, count)),
                      duration_ms: durationMS.isFinite ? min(3600000, max(0, durationMS)) : 0))
    }
}
