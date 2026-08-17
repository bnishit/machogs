// The watchdog — machogs' tap on the shoulder.
//
// The popover answers "why is my Mac slow?" when you ask. The watchdog asks
// FOR you, at the moment it matters. It watches the engine's report (already
// polled every 60s) for three moments worth interrupting someone:
//
//   🔥 hot   — one group has been burning 60%+ of a core for two polls in a
//              row. That is the fan the user is about to hear.
//   🧹 sweep — a Claude Code session just ended and new closable leftovers
//              appeared that were not there while it lived.
//   👯 clones — one app crossed 8+ idle copies of the same helper.
//
// It never closes anything on its own. Every catch is an offer: a system
// notification with a "Close it 💥" button, and the Caught-in-4K window for
// the full picture. Cooldowns keep it from nagging: one ping per story per
// hours, a global gap between pings, and "Leave it" snoozes a story for a day.

import Foundation
import AppKit
import UserNotifications

// One catch, however it gets shown (notification, popover banner, window).
struct BustEvent: Identifiable {
    enum Kind { case hot, sweep, clones }
    let id = UUID().uuidString
    let kind: Kind
    let headline: String
    let subline: String
    let keys: Set<String>   // FindingGroup ids (stories) this catch is about
}

@MainActor
final class Watchdog: NSObject {
    // Tuning. All thresholds live here.
    private static let hotCPU = 60.0          // group total %CPU that counts as "cooking"
    private static let clonesAt = 8           // copies of one helper before we speak up
    private static let sweepWindow = 120.0    // seconds after session end to blame new mess on it
    private static let pingGap = 300.0        // global minimum seconds between pings
    private static let hotCooldownH = 4.0
    private static let clonesCooldownH = 6.0
    private static let sweepCooldownH = 0.5
    private static let snoozeH = 24.0         // "Leave it"

    private weak var engine: Engine?
    private var primed = false                // first poll only takes a baseline
    private var prevHotKeys: Set<String> = []
    private var prevGroupKeys: Set<String> = []
    private var prevCounts: [String: Int] = [:]
    private var prevSessions: [Int: String] = [:]   // pid → project name
    private var sweepBaseline: Set<String>?         // group keys while the session lived
    private var sweepProject = ""
    private var sweepDeadline = Date.distantPast
    private var lastPing = Date.distantPast
    private var pending: [String: BustEvent] = [:]  // notification id → catch

    // Story → don't-ping-again-before date, persisted so restarts don't re-nag.
    private var cooldowns: [String: Date] = {
        let raw = UserDefaults.standard.dictionary(forKey: "watchdogCooldowns") as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }()

    static var on: Bool {
        UserDefaults.standard.object(forKey: "watchdogOn") == nil
            || UserDefaults.standard.bool(forKey: "watchdogOn")
    }

    // Notifications need a real .app bundle; `swift run` from the package has none.
    private var bundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func attach(_ engine: Engine) {
        self.engine = engine
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let close = UNNotificationAction(identifier: "CLOSE", title: "Close it 💥", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "MACHOGS_CATCH", actions: [close],
                                   intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Called by the engine after every successful refresh. Everything here is
    // keyed by FindingGroup.key — the stable identity — never by story text.
    func evaluate(report: Report, groups: [FindingGroup]) {
        let keys = Set(groups.map(\.key))
        let counts = Dictionary(groups.map { ($0.key, $0.count) }, uniquingKeysWith: max)
        let hotKeys = Set(groups.filter { $0.totalCPU >= Self.hotCPU }.map(\.key))
        let sessions = liveSessions(in: report)
        defer {
            prevHotKeys = hotKeys
            prevGroupKeys = keys
            prevCounts = counts
            prevSessions = sessions
            engine?.pruneBustPending()
        }
        guard primed else { primed = true; return }   // launch poll = baseline, never a ping
        guard Self.on else { return }

        // 🧹 A session vanished → remember what the mess looked like while it
        // lived, poke the engine again soon (orphans surface on the next poll),
        // and for the next two minutes blame any NEW closable group on it.
        let ended = prevSessions.filter { sessions[$0.key] == nil }
        if let (_, project) = ended.first {
            sweepBaseline = prevGroupKeys
            sweepProject = project
            sweepDeadline = Date().addingTimeInterval(Self.sweepWindow)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak engine] in engine?.refresh() }
        }
        if let baseline = sweepBaseline {
            if Date() > sweepDeadline {
                sweepBaseline = nil
            } else {
                let fresh = keys.subtracting(baseline)
                if !fresh.isEmpty {
                    sweepBaseline = nil
                    let n = fresh.reduce(0) { $0 + (counts[$1] ?? 0) }
                    fire(.sweep, keys: fresh, cooldownH: Self.sweepCooldownH,
                         headline: "Session over, mess left",
                         subline: "Claude Code finished in \(sweepProject) and left \(n) helper\(n == 1 ? "" : "s") running.",
                         title: "🧹 Claude Code left without cleaning up",
                         body: "Your session in \(sweepProject) ended but left \(n) helper\(n == 1 ? "" : "s") running. Want them gone?")
                    return
                }
            }
        }

        // 🔥 Hot two polls in a row — that's a stuck loop, not a compile.
        if let key = hotKeys.intersection(prevHotKeys).first(where: allowed),
           let group = groups.first(where: { $0.key == key }) {
            fire(.hot, keys: [key], cooldownH: Self.hotCooldownH,
                 headline: "Caught the hog",
                 subline: "This is why your fan is loud and your battery is draining.",
                 title: "🔥 Found what's cooking your CPU",
                 body: group.story + " That's the fan you're hearing.")
            return
        }

        // 👯 One helper crossed the clone-army line.
        if let group = groups.first(where: {
            $0.count >= Self.clonesAt && (prevCounts[$0.key] ?? 0) < Self.clonesAt && allowed($0.key)
        }) {
            let owner = group.members.first?.owner ?? "An app"
            fire(.clones, keys: [group.key], cooldownH: Self.clonesCooldownH,
                 headline: "Clone army forming",
                 subline: "\(owner) is up to \(group.count) copies of the same helper, all idle.",
                 title: "👯 Clone army in the background",
                 body: "\(owner) has \(group.count) copies of the same helper running. One would do.")
        }
    }

    // "Leave it" — this story stays quiet for a day.
    func snooze(_ keys: Set<String>) {
        for k in keys { cooldowns[k] = Date().addingTimeInterval(Self.snoozeH * 3600) }
        saveCooldowns()
    }

    // MARK: - internals

    private func liveSessions(in report: Report) -> [Int: String] {
        var out: [Int: String] = [:]
        for f in report.findings where f.action == "never-killed" && f.detail.hasPrefix("Claude Code session in ") {
            let name = f.detail.dropFirst("Claude Code session in ".count)
                .split(separator: ",").first.map(String.init) ?? "a project"
            out[f.pid] = name
        }
        return out
    }

    private func allowed(_ key: String) -> Bool { (cooldowns[key] ?? .distantPast) < Date() }

    private func fire(_ kind: BustEvent.Kind, keys: Set<String>, cooldownH: Double,
                      headline: String, subline: String, title: String, body: String) {
        // Sweeps are time-critical (the moment passes); the others wait their turn.
        guard kind == .sweep || Date().timeIntervalSince(lastPing) > Self.pingGap else { return }
        lastPing = Date()
        for k in keys { cooldowns[k] = Date().addingTimeInterval(cooldownH * 3600) }
        saveCooldowns()

        let event = BustEvent(kind: kind, headline: headline, subline: subline, keys: keys)
        pending[event.id] = event
        engine?.bustPending = event   // 📸 in the menu bar + banner in the popover
        if let engine { Island.shared.show(event, engine: engine) }   // the live pill

        guard bundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = Sfx.on ? .default : nil
        content.categoryIdentifier = "MACHOGS_CATCH"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
    }

    private func saveCooldowns() {
        cooldowns = cooldowns.filter { $0.value > Date() }   // drop expired
        UserDefaults.standard.set(cooldowns.mapValues { $0.timeIntervalSince1970 },
                                  forKey: "watchdogCooldowns")
    }

    private func postReceipt(_ text: String) {
        guard bundled else { return }
        let content = UNMutableNotificationContent()
        content.title = text
        content.body = "Receipt logged. The Receipts window keeps score."
        content.sound = nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Notification plumbing

extension Watchdog: UNUserNotificationCenterDelegate {
    // The delegate is called off the main thread; hop back before touching state.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            self.handle(id: id, action: action)
            completionHandler()
        }
    }

    private func handle(id: String, action: String) {
        guard let engine else { return }
        let event = pending.removeValue(forKey: id)
        if action == "CLOSE", let event {
            if let receipt = engine.closeMatching(event.keys) { postReceipt(receipt) }
            engine.bustPending = nil
        } else {
            // Body click (or a catch from a previous run): show the window.
            engine.bust = event
            engine.bustPending = nil
            NSWorkspace.shared.open(URL(string: "machogs://bust")!)
        }
    }

    // The island is the visible moment; the notification just lands quietly
    // in Notification Center so the catch survives being missed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
