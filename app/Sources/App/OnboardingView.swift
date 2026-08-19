import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var shoulderTaps = true
    @State private var startAtLogin = true
    @State private var finishing = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.pink.opacity(0.16), Color.orange.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
            Group {
                switch step {
                case 0: purpose
                case 1: trust
                default: choices
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(34)
            .id(step)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))

            HStack {
                Button("Back") { move(to: step - 1) }
                    .disabled(step == 0 || finishing)
                    .buttonStyle(.borderless)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Capsule()
                            .fill(index == step ? Color.pink : Color.secondary.opacity(0.22))
                            .frame(width: index == step ? 24 : 7, height: 7)
                    }
                }
                    .accessibilityLabel("Onboarding step \(step + 1) of 3")
                Spacer()
                if step < 2 {
                    Button("Next") { move(to: step + 1) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(finishing ? "Opening…" : "Open Machogs") { finish() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(finishing)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            .background(.ultraThinMaterial)
            }
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 480, idealHeight: 520)
        .background(.regularMaterial)
        .background(WindowSizer(width: 680, height: 520))
    }

    private var purpose: some View {
        HStack(spacing: 34) {
            ZStack {
                Circle()
                    .fill(Color.pink.opacity(0.14))
                    .frame(width: 230, height: 230)
                Circle()
                    .stroke(Color.pink.opacity(0.13), lineWidth: 20)
                    .frame(width: 185, height: 185)
                PigMascot(mood: .curious, size: 150)
                Text("sniff…")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.pink)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .rotationEffect(.degrees(-7))
                    .offset(x: 76, y: -82)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("MEET YOUR MAC'S NEW NOSE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.6)
                    .foregroundStyle(.pink)
                Text("Your Mac grew a secret second shift.")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Machogs sniffs out stuck and abandoned work, names the app that left it, and shows what it has cost.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Label("Looking changes nothing", systemImage: "eye")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 340, alignment: .leading)
        }
    }

    private var trust: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Suspicion is healthy.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("So the pig comes with boundaries.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                PigMascot(mood: .concerned, size: 78)
            }
            HStack(alignment: .top, spacing: 12) {
                trustRow("eye", "Looks, never snoops", "Process facts only. No documents or browser history.")
                trustRow("hand.raised.fill", "Asks before acting", "Every close gets a named review and your consent.")
                trustRow("lock.shield.fill", "Protects live work", "The engine checks again. Coding sessions and macOS stay safe.")
            }
            Text("No Full Disk Access  •  No Accessibility access  •  No admin password")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: 610, alignment: .leading)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("How watchful should the pig be?")
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                    Text("Pick a perch. Both choices stay reversible.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                PigMascot(mood: .pleased, size: 82)
            }
            option("Shoulder taps", detail: "Get a calm alert when a real hog persists. macOS asks about notifications only after you open Machogs.", isOn: $shoulderTaps)
            option("Start at Login", detail: "Recommended. The menu-bar pig can notice trouble before you go looking for it.", isOn: $startAtLogin)
            Text(BuildIdentity.current().label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let error = settings.setupError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: 570, alignment: .leading)
    }

    private func trustRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        SoftPanel {
            VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.pink.gradient, in: Circle())
                .accessibilityHidden(true)
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func option(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.2)))
    }

    private func move(to next: Int) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1)) {
            step = min(2, max(0, next))
        }
    }

    private func finish() {
        finishing = true
        Task {
            _ = await settings.completeOnboarding(
                shoulderTaps: shoulderTaps,
                startAtLogin: startAtLogin
            )
            finishing = false
        }
    }
}

private struct WindowSizer: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> SizingView {
        SizingView(size: NSSize(width: width, height: height))
    }
    func updateNSView(_ view: SizingView, context: Context) {
        view.desiredSize = NSSize(width: width, height: height)
        view.apply()
    }

    final class SizingView: NSView {
        var desiredSize: NSSize
        init(size: NSSize) { desiredSize = size; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window,
                      window.contentView?.frame.size != self.desiredSize else { return }
                window.setContentSize(self.desiredSize)
                window.center()
            }
        }
    }
}
