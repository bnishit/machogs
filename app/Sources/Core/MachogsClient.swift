import Foundation

public protocol MachogsServing: Sendable {
    func scan() async throws -> EngineReport
    func scanAbandoned() async throws -> EngineReport
    func closeAbandoned(targets: [ProcessTarget]) async throws -> EngineReport
    func inspectMemory() async throws -> MemorySnapshot
    func planClose(targets: [ProcessTarget]) async throws -> EngineReport
    func closeReviewed(targets: [ProcessTarget]) async throws -> EngineReport
    func inspectPorts() async throws -> PortsReport
    func inspectPort(_ port: Int) async throws -> PortsReport
    func closePort(_ target: PortTarget) async throws -> PortsReport
    func inspectDisk() async throws -> DiskReport
    func clearDisk(path: String) async throws -> DiskClearResult
    func shareCard() async throws -> String
    func inspectWorktrees() async throws -> WorktreesReport
    func removeWorktree(path: String) async throws -> DiskClearResult
}

public extension MachogsServing {
    func scanAbandoned() async throws -> EngineReport { throw MachogsClientError.invalidResponse }
    func closeAbandoned(targets: [ProcessTarget]) async throws -> EngineReport { throw MachogsClientError.invalidResponse }
    func inspectMemory() async throws -> MemorySnapshot { throw MachogsClientError.invalidResponse }
    func inspectWorktrees() async throws -> WorktreesReport { throw MachogsClientError.invalidResponse }
    func removeWorktree(path: String) async throws -> DiskClearResult { throw MachogsClientError.invalidResponse }
}

public enum MachogsClientError: LocalizedError, Equatable {
    case engineMissing
    case launchFailed(String)
    case commandFailed(status: Int32, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .engineMissing:
            return "Machogs could not find its local scanning engine. Reinstall the app."
        case .launchFailed(let message):
            return "Machogs could not start a scan. \(message)"
        case .commandFailed(_, let message):
            return message.isEmpty ? "The scanning engine could not finish." : message
        case .invalidResponse:
            return "Machogs could not read the scan result. Nothing was closed."
        }
    }
}

public struct MachogsClient: MachogsServing {
    private let scriptURL: URL?

    public init(scriptURL: URL? = MachogsClient.defaultScriptURL()) {
        self.scriptURL = scriptURL
    }

    public static func defaultScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "machogs", withExtension: nil) {
            return bundled
        }
        for path in ["/opt/homebrew/bin/machogs", "/usr/local/bin/machogs"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static func targetArguments(_ targets: [ProcessTarget]) -> [String] {
        Array(Set(targets.filter { $0.pid > 0 && !$0.identity.isEmpty }))
            .sorted { left, right in
                left.pid == right.pid ? left.identity < right.identity : left.pid < right.pid
            }
            .map { "--target=\($0.pid):\($0.identity)" }
    }

    public static func planArguments(for targets: [ProcessTarget]) -> [String] {
        ["plan", "--json", "--sessions"] + targetArguments(targets)
    }

    public static func closeArguments(for targets: [ProcessTarget]) -> [String] {
        ["kill", "--json", "--sessions", "--dupes"] + targetArguments(targets)
    }

    public func inspectMemory() async throws -> MemorySnapshot {
        try await MemoryMonitor.sample()
    }

    public func scanAbandoned() async throws -> EngineReport {
        try await decode(["--json", "--abandoned-only"], as: EngineReport.self)
    }

    public func closeAbandoned(targets: [ProcessTarget]) async throws -> EngineReport {
        guard !Self.targetArguments(targets).isEmpty else { throw MachogsClientError.invalidResponse }
        return try await decode(["kill", "--json", "--abandoned-only"] + Self.targetArguments(targets), as: EngineReport.self)
    }

    public func scan() async throws -> EngineReport {
        try await decode(["--json", "--sessions"], as: EngineReport.self)
    }

    public func planClose(targets: [ProcessTarget]) async throws -> EngineReport {
        guard !Self.targetArguments(targets).isEmpty else { throw MachogsClientError.invalidResponse }
        return try await decode(Self.planArguments(for: targets), as: EngineReport.self)
    }

    public func closeReviewed(targets: [ProcessTarget]) async throws -> EngineReport {
        guard !Self.targetArguments(targets).isEmpty else { throw MachogsClientError.invalidResponse }
        return try await decode(Self.closeArguments(for: targets), as: EngineReport.self)
    }

    public func inspectPorts() async throws -> PortsReport {
        try await decode(["ports", "--json"], as: PortsReport.self)
    }

    public func inspectPort(_ port: Int) async throws -> PortsReport {
        guard (1...65535).contains(port) else { throw MachogsClientError.invalidResponse }
        return try await decode(["port", "\(port)", "--json"], as: PortsReport.self)
    }

    public func closePort(_ target: PortTarget) async throws -> PortsReport {
        guard (1...65535).contains(target.port), target.pid > 0, !target.identity.isEmpty else {
            throw MachogsClientError.invalidResponse
        }
        return try await decode(
            ["port", "\(target.port)", "kill", "--json", "--target=\(target.pid):\(target.identity)"],
            as: PortsReport.self
        )
    }

    public func inspectDisk() async throws -> DiskReport {
        try await decode(["disk", "--json"], as: DiskReport.self)
    }

    public func clearDisk(path: String) async throws -> DiskClearResult {
        guard path.hasPrefix("/") else { throw MachogsClientError.invalidResponse }
        return try await decode(["disk", "clear", path, "--json"], as: DiskClearResult.self)
    }

    public func inspectWorktrees() async throws -> WorktreesReport {
        try await decode(["worktrees", "--json"], as: WorktreesReport.self)
    }

    public func removeWorktree(path: String) async throws -> DiskClearResult {
        guard path.hasPrefix("/") else { throw MachogsClientError.invalidResponse }
        return try await decode(["worktrees", "remove", path, "--json"], as: DiskClearResult.self)
    }

    public func shareCard() async throws -> String {
        let result = try await run(["brag"])
        guard let text = String(data: result.stdout, encoding: .utf8), !text.isEmpty else {
            throw MachogsClientError.invalidResponse
        }
        return text
    }

    private func decode<T: Decodable>(_ arguments: [String], as type: T.Type) async throws -> T {
        let result = try await run(arguments)
        do {
            return try JSONDecoder().decode(T.self, from: result.stdout)
        } catch {
            throw MachogsClientError.invalidResponse
        }
    }

    private func run(_ arguments: [String]) async throws -> CommandResult {
        guard let scriptURL else { throw MachogsClientError.engineMissing }
        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["MACHOGS_ANALYTICS": "0"]) { _, new in new }

            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors

            do {
                try process.run()
            } catch {
                throw MachogsClientError.launchFailed(error.localizedDescription)
            }

            let outputRead = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let errorRead = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
            process.waitUntilExit()
            let stdout = await outputRead.value
            let stderr = await errorRead.value

            guard process.terminationStatus == 0 || process.terminationStatus == 10 else {
                let message = String(data: stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw MachogsClientError.commandFailed(status: process.terminationStatus, message: message)
            }
            return CommandResult(stdout: stdout)
        }.value
    }
}

private struct CommandResult: Sendable {
    let stdout: Data
}
