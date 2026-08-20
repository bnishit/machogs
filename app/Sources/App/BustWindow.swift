// Caught in 4K — the window a watchdog catch opens into.
//
// The notification is the knock; this is the reveal. One catch, its card(s),
// one big button. Camera-flash entrance, confetti on close, then it gets out
// of the way. Opens via `machogs://bust` (island tap, notification click, or
// an agent). If the mess died on its own before the user arrived, it says so
// instead of showing an empty room.

import AppKit
import MachogsCore
import SwiftUI

struct BustView: View {
    @ObservedObject var model: AppModel
    let event: WatchdogEvent?

    @Environment(\.dismiss) private var dismissAction
    @State private var flashed = false
    @State private var appeared = false
    @State private var receipt: String?
    @State private var celebrate = 0

    // SwiftUI's dismiss() can be a no-op on Window scenes (macOS 13);
    // fall back to closing the NSWindow by title.
    private func dismiss() {
        dismissAction()
        NSApp.windows.first { $0.title == "Caught in 4K" }?.close()
    }

    // Live groups this catch is about. A stale catch falls back to everything
    // still closable, so the window never lies about what the button will do.
    private var targets: [FindingGroup] {
        if let event, !event.targets.isEmpty {
            let identities = Set(event.targets.map(\.identity))
            let hit = model.groups.filter { group in
                group.targets.contains { identities.contains($0.identity) }
            }
            if !hit.isEmpty { return hit }
        }
        return model.groups
    }
    private var totalCount: Int { targets.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header.joyReveal(appeared, delay: 0)
            if let receipt {
                receiptCard(receipt)
            } else if targets.isEmpty {
                allClear.joyReveal(appeared, delay: 0.05)
            } else {
                VStack(spacing: 8) {
                    ForEach(targets) { group in
                        BustHogCard(group: group) { close([group]) }
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 6)),
                                removal: .scale(scale: 0.8).combined(with: .opacity)))
                    }
                }
                .joyReveal(appeared, delay: 0.06)
                actions.joyReveal(appeared, delay: 0.12)
            }
        }
        .padding(18)
        .padding(.top, 28)   // clear the floating traffic lights
        .frame(width: 480)
        // Backgrounds go ON the content, not beside it in a ZStack — a bare
        // gradient sibling is greedy and would stretch the window taller than
        // its content. Hotter weather than the popover: this window only
        // opens when something was caught red-handed.
        .background(
            LinearGradient(colors: [Color.orange.opacity(0.16), Color.pink.opacity(0.07), .clear],
                           startPoint: .top, endPoint: .center))
        .overlay(ConfettiBurst(trigger: celebrate))
        // The camera flash: a white sheet that vanishes as the window lands.
        .overlay(
            Color.white
                .opacity(flashed ? 0 : 0.85)
                .allowsHitTesting(false))
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: receipt)
        .onAppear {
            MachogsSound.pop()
            withAnimation(.easeOut(duration: 0.55)) { flashed = true }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("📸")
                .font(.system(size: 40))
                .scaleEffect(appeared ? 1 : 1.45)
                .rotationEffect(.degrees(appeared ? -6 : 8))
                .animation(.spring(response: 0.5, dampingFraction: 0.55), value: appeared)
                .shadow(color: .orange.opacity(0.5), radius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(event?.title ?? "Caught in 4K")
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                Text(event?.body ?? "Here's what's running that shouldn't be.")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                for group in targets { model.snoozeGroup(group.id, minutes: 24 * 60) }
                dismiss()
            } label: {
                Text("Leave it")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(PigPressStyle())
            .help("Snoozes this one for a day")

            Spacer()

            Button { close(targets) } label: {
                Text(totalCount > 1 ? "Close all \(totalCount) 💥" : "Close it 💥")
                    .font(.system(.callout, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(
                        Capsule().fill(LinearGradient(colors: [.orange, .pink],
                                                      startPoint: .top, endPoint: .bottom)))
                    .shadow(color: .orange.opacity(0.5), radius: 6, y: 2)
            }
            .buttonStyle(PigPressStyle())
        }
    }

    private func close(_ groups: [FindingGroup]) {
        let targets = groups.flatMap(\.targets)
        Task {
            await model.closeTargetsNow(targets)
            let text = model.receipt?.message ?? "Done."
            let success = model.receipt?.isSuccess ?? false
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { receipt = text }
            if success { celebrate += 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { dismiss() }
        }
    }

    private func receiptCard(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.green.opacity(0.9), .teal.opacity(0.9)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: .green.opacity(0.35), radius: 6, y: 2)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // The mess closed itself (or someone beat you to it). Say so and go.
    private var allClear: some View {
        HStack(spacing: 10) {
            Text("✨").font(.system(size: 24))
            VStack(alignment: .leading, spacing: 2) {
                Text("Already gone.")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                Text("Whatever was caught has cleaned itself up. Nothing to close.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Nice") { dismiss() }
                .buttonStyle(PigPressStyle())
                .font(.system(.caption, design: .rounded).weight(.semibold))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color.green.opacity(0.12), Color.teal.opacity(0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.green.opacity(0.25), lineWidth: 1))
    }
}

private struct BustHogCard: View {
    let group: FindingGroup
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.owner)
                        .font(.system(.callout, design: .rounded).weight(.bold))
                    if group.count > 1 {
                        Text("×\(group.count)")
                            .font(.system(.caption2, design: .rounded).weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                    }
                    if group.isHot { Text("🔥").font(.system(size: 12)) }
                }
                Text(group.story)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Close it 💥", action: close)
                .buttonStyle(PigActionStyle(tint: .orange))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .hoverLift()
    }
}
