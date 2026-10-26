import Foundation

/// One evening notification in place of opening the app: what Machogs did
/// today, and the one thing still worth doing.
public struct DailyRecap: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Where a click should land: storage when there is room to make.
    public let page: String

    /// Reads today's lines from the close log (tab-separated, date first).
    /// Returns nil on a day with nothing to say.
    public static func make(log: String, now: Date, freeGB: Int?, removableCopiesMB: Int,
                            calendar: Calendar = .current) -> DailyRecap? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var closed = 0, automatic = 0, cpuSeconds = 0, clearedMB = 0
        for line in log.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, let date = formatter.date(from: fields[0]),
                  calendar.isDate(date, inSameDayAs: now) else { continue }
            if fields[1] == "closed", fields.count >= 7 {
                closed += 1
                if fields[4].hasPrefix("automatic cleanup:") { automatic += 1 }
                cpuSeconds += Int(Double(fields[6]) ?? 0)
            } else if fields[1] == "cleared" {
                clearedMB += Int(fields[4]) ?? 0
            }
        }
        let lowDisk = (freeGB ?? .max) < 30
        let copies = removableCopiesMB >= 1024
        guard closed > 0 || clearedMB > 0 || lowDisk || copies else { return nil }

        var parts: [String] = []
        if closed > 0 {
            let byYou = closed - automatic
            parts.append(automatic == 0 ? "You closed all of them."
                : byYou == 0 ? "All closed on their own."
                : "\(automatic) closed on their own, \(byYou) by you.")
            if cpuSeconds >= 60 { parts.append("They had used \(cpuSeconds / 60) min of CPU.") }
        }
        if clearedMB > 0 { parts.append("Cleared \(gb(clearedMB)) of storage.") }
        if copies { parts.append("\(gb(removableCopiesMB)) of old coding copies can go.") }
        if let freeGB { parts.append("\(freeGB) GB free\(lowDisk ? ", which is getting tight" : "").") }

        let title = closed > 0 ? "Today: \(closed) leftover\(closed == 1 ? "" : "s") closed"
            : lowDisk ? "Your Mac is low on space" : "Room to make on your Mac"
        return DailyRecap(title: title, body: parts.joined(separator: " "),
                          page: copies || lowDisk ? "storage" : "receipts")
    }

    private static func gb(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
}
