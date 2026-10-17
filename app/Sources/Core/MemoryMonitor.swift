import Foundation

public struct AppMemory: Equatable, Sendable, Identifiable {
    public let app: String
    public let memoryMB: Int
    public let compressedMB: Int
    public let processCount: Int
    public var id: String { app }
    public var memoryText: String { String(format: "%.1f GB", Double(memoryMB) / 1024) }
}

public struct MemorySnapshot: Equatable, Sendable {
    public let apps: [AppMemory]
    public let physicalMB: Int
    public let swapUsedMB: Int
}

public enum MemoryMonitor {
    public static func sample() async throws -> MemorySnapshot {
        try await Task.detached(priority: .utility) {
            let metrics = try output("/usr/bin/top", ["-l", "1", "-n", "2000", "-stats", "pid,mem,cmprs,command"])
            let processes = try output("/bin/ps", ["-U", "\(getuid())", "-o", "pid=,ppid=,comm="])
            let swap = try output("/usr/sbin/sysctl", ["-n", "vm.swapusage"])
            let words = swap.split(whereSeparator: \.isWhitespace)
            let used = words.firstIndex(of: "used").flatMap { i in
                words.indices.contains(i + 2) ? Double(words[i + 2].dropLast()) : nil
            } ?? 0
            let apps = rollup(metrics: metrics, processes: processes)
            guard !apps.isEmpty else { throw MachogsClientError.invalidResponse }
            return MemorySnapshot(apps: apps,
                                  physicalMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                                  swapUsedMB: Int(used))
        }.value
    }

    private static func output(_ path: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw MachogsClientError.invalidResponse
        }
        return text
    }

    static func megabytes(_ value: Substring) -> Int {
        let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        let amount = Double(clean.dropLast()) ?? 0
        switch clean.last {
        case "G": return Int(amount * 1024)
        case "M": return Int(amount)
        case "K": return Int(amount / 1024)
        case "T": return Int(amount * 1_048_576)
        default: return 0
        }
    }

    static func rollup(metrics: String, processes: String) -> [AppMemory] {
        var parents: [Int: Int] = [:]
        var commands: [Int: String] = [:]
        for line in processes.split(separator: "\n") {
            let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count == 3, let pid = Int(parts[0]), let parent = Int(parts[1]) else { continue }
            parents[pid] = parent
            commands[pid] = String(parts[2])
        }
        func owner(_ pid: Int) -> String? {
            var current = pid
            var seen: Set<Int> = []
            var app: String?
            while let command = commands[current], seen.insert(current).inserted {
                let name = URL(fileURLWithPath: command).lastPathComponent
                if !command.contains(".app/"), name == "claude" || name == "codex" {
                    return name == "claude" ? "Claude Code" : "Codex CLI"
                }
                if let range = command.range(of: ".app/Contents/") {
                    app = URL(fileURLWithPath: String(command[..<range.lowerBound])).lastPathComponent
                }
                guard let parent = parents[current], parent > 1 else { break }
                current = parent
            }
            return app
        }
        var totals: [String: (memory: Int, compressed: Int, count: Int)] = [:]
        for line in metrics.split(separator: "\n") {
            let parts = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard parts.count == 4, let pid = Int(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "*"))), let app = owner(pid) else { continue }
            var total = totals[app] ?? (0, 0, 0)
            total.memory += megabytes(parts[1])
            total.compressed += megabytes(parts[2])
            total.count += 1
            totals[app] = total
        }
        return totals.map { AppMemory(app: $0.key, memoryMB: $0.value.memory,
                                      compressedMB: $0.value.compressed, processCount: $0.value.count) }
            .sorted { $0.memoryMB > $1.memoryMB }
    }
}
