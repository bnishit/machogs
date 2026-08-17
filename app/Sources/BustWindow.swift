// Caught in 4K — the window a watchdog catch opens into.
//
// The notification is the knock; this is the reveal. One catch, its card(s),
// one big button. Camera-flash entrance, confetti on close, then it gets out
// of the way. Opens via `machogs://bust` (notification click, popover banner,
// or an agent). If the mess died on its own before the user arrived, it says
// so instead of showing an empty room.

import SwiftUI
import AppKit

struct BustView: View {
    @ObservedObject var engine: Engine
    @State private var flashed = false
    @State private var appeared = false
    @State private var receipt: String?

    // SwiftUI's dismiss() is a no-op on Window scenes here (macOS 13);
    // close the NSWindow by its scene identifier instead.
    private func dismiss() {
        NSApp.windows.first {
            $0.identifier?.rawValue.contains("bust") == true || $0.title == "Caught in 4K"
        }?.close()
    }

    // Live groups this catch is about. A stale catch falls back to everything
    // still closable, so the window never lies about what the button will do.
    private var targets: [FindingGroup] {
        if let keys = engine.bust?.keys, !keys.isEmpty {
            let hit = engine.groups.filter { keys.contains($0.key) }
            if !hit.isEmpty { return hit }
        }
        return engine.groups
    }
    private var totalCount: Int { targets.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header.reveal(appeared, delay: 0)
            if let receipt {
                receiptCard(receipt)
            } else if targets.isEmpty {
                allClear.reveal(appeared, delay: 0.05)
            } else {
                VStack(spacing: 8) {
                    ForEach(targets) { group in
                        HogCard(group: group) { close([group]) }
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 6)),
                                removal: .scale(scale: 0.8).combined(with: .opacity)))
                    }
                }
                .reveal(appeared, delay: 0.06)
                actions.reveal(appeared, delay: 0.12)
            }
        }
        .padding(18)
        .padding(.top, 28)   // clear the floating traffic lights
        .frame(width: 400)
        // Backgrounds go ON the content, not beside it in a ZStack — a bare
        // gradient or Color sibling is greedy and would stretch the window
        // taller than its content. Hotter weather than the popover: this
        // window only opens when something was caught red-handed.
        .background(
            LinearGradient(colors: [Color.orange.opacity(0.16), Color.pink.opacity(0.07), .clear],
                           startPoint: .top, endPoint: .center))
        .overlay(ConfettiBurst(trigger: engine.celebrate))
        // The camera flash: a white sheet that vanishes as the window lands.
        .overlay(
            Color.white
                .opacity(flashed ? 0 : 0.85)
                .allowsHitTesting(false))
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: receipt)
        .onAppear {
            Sfx.pop()
            withAnimation(.easeOut(duration: 0.55)) { flashed = true }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
        }
        .onDisappear { engine.bust = nil }
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
                Text(engine.bust?.headline ?? "Caught in 4K")
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                Text(engine.bust?.subline ?? "Here's what's running that shouldn't be.")
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
                if let keys = engine.bust?.keys { engine.watchdog.snooze(keys) }
                dismiss()
            } label: {
                Text("Leave it")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(Squish())
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
            .buttonStyle(Squish())
        }
    }

    private func close(_ groups: [FindingGroup]) {
        guard let text = engine.closeMatching(Set(groups.map(\.key))) else { return }
        engine.bustPending = nil
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { receipt = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { dismiss() }
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
                .buttonStyle(Squish())
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
