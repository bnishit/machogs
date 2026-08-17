// The island — machogs' live-activity moment.
//
// macOS has no Live Activities, so this is an NSPanel doing the impression:
// when the watchdog catches something, a black pill slides out from behind
// the notch (or the top edge on notchless Macs), says one line, offers one
// button, and leaves. Non-activating — it never steals focus, never asks the
// user to manage a window. Click the pill for the full Caught-in-4K reveal;
// click Close to fix it right there and watch the pill turn into a receipt.

import SwiftUI
import AppKit

@MainActor
final class Island {
    static let shared = Island()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    static let width: CGFloat = 540
    static let height: CGFloat = 120   // room for the pill plus its shadow

    func show(_ event: BustEvent, engine: Engine) {
        dismiss()
        let host = NSHostingView(rootView: IslandView(event: event, engine: engine))
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)

        let p = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false                       // the pill draws its own
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host

        // Prefer the screen that actually has a notch; fall back to main.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        if let f = screen?.frame {
            p.setFrameOrigin(NSPoint(x: f.midX - Self.width / 2, y: f.maxY - Self.height))
        }
        p.orderFrontRegardless()
        panel = p
        Sfx.play("Tink")

        scheduleHide(after: 8)
    }

    func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func holdOpen() { hideWork?.cancel() }   // don't vanish mid-decision

    func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct IslandView: View {
    let event: BustEvent
    @ObservedObject var engine: Engine
    @State private var landed = false            // slid out from the notch yet?
    @State private var leaving = false
    @State private var receipt: String?

    private var emoji: String {
        switch event.kind {
        case .hot: return "🔥"
        case .sweep: return "🧹"
        case .clones: return "👯"
        }
    }

    var body: some View {
        VStack {
            pillBody
                // Entrance: emerge from behind the notch with a little bounce
                // (follow-through); exit: accelerate back up underneath it.
                .offset(y: leaving ? -Island.height : (landed ? 6 : -Island.height))
                .animation(leaving
                           ? .easeIn(duration: 0.22)
                           : .spring(response: 0.5, dampingFraction: 0.68),
                           value: landed)
                .animation(.easeIn(duration: 0.22), value: leaving)
            Spacer(minLength: 0)
        }
        .frame(width: Island.width, height: Island.height, alignment: .top)
        .onAppear { landed = true }
        .onHover { hovering in
            // Reading it? It waits. Look away and it finishes its exit later.
            if hovering { Island.shared.holdOpen() }
            else if receipt == nil { Island.shared.scheduleHide(after: 4) }
        }
    }

    private var pillBody: some View {
        HStack(spacing: 10) {
            Text(receipt == nil ? emoji : "🎉")
                .font(.system(size: 22))
                .scaleEffect(landed ? 1 : 0.4)
                .animation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.08), value: landed)

            if let receipt {
                Text(receipt)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.headline)
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                    Text(event.subline)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 6)

            if receipt == nil {
                Button {
                    if let text = engine.closeMatching(event.keys) {
                        engine.bustPending = nil
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { receipt = text }
                        Island.shared.scheduleHide(after: 2.8)
                    } else {
                        leave()
                    }
                } label: {
                    Text("Close it 💥")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(LinearGradient(colors: [.orange, .pink],
                                                                  startPoint: .top, endPoint: .bottom)))
                }
                .buttonStyle(Squish())

                Button { leave() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(7)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(Squish())
            }
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .frame(width: Island.width - 24)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 28))
        .onTapGesture {
            // The pill is the teaser; the tap is the full story.
            engine.bust = event
            engine.bustPending = nil
            NSWorkspace.shared.open(URL(string: "machogs://bust")!)
            leave()
        }
    }

    private func leave() {
        leaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Island.shared.dismiss() }
    }
}
