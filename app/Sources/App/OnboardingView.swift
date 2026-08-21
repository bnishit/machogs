import AppKit
import MachogsCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene = 0
    @State private var keepWatch = true
    @State private var allowAlerts = false
    @State private var startAtLogin = true
    @State private var finishing = false
    @State private var showSightDetails = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.pink.opacity(0.18), Color.orange.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            Group {
                switch scene {
                case 0: welcome
                case 1: reveal
                default: watchChoice
                }
            }
            .padding(42).id(scene)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
            .joyReveal(appeared, delay: 0)
        }
        .overlay(alignment: .top) { sceneIndicator.padding(.top, 22) }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 540, idealHeight: 580)
        .background(.regularMaterial)
        .background(WindowSizer(width: 760, height: 580))
        .onAppear {
            MachogsSound.pop(enabled: settings.soundOn)
            appeared = true
        }
    }

    private var welcome: some View {
        HStack(spacing: 46) {
            PigStage(mood: .curious, caption: "Apps leave messes.\nThe pig finds them.", showsSniffBubble: true).frame(width: 280)
            VStack(alignment: .leading, spacing: 20) {
                Text("YOUR MAC, UNMASKED").font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.pink)
                Text("Your apps don’t always go home when you do.")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Text("Browsers, AI tools, and other apps can leave little bits of work running after you’re finished. Machogs names the app and shows whether it matters.")
                    .font(.title3).foregroundStyle(.secondary)
                Button { showSightDetails.toggle() } label: { Label("What can the pig see?", systemImage: "eye") }
                    .buttonStyle(.link)
                    .popover(isPresented: $showSightDetails) {
                        Text("Only facts about running programs that macOS already shows. Not your files, messages, passwords, tabs, or browser history.")
                            .font(.callout).padding(18).frame(width: 340)
                    }
                Button { sniff() } label: {
                    Label("Sniff my Mac", systemImage: "sparkles")
                }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                Label("This first check only looks. Nothing can close.", systemImage: "hand.raised.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }.frame(maxWidth: 390, alignment: .leading)
        }
    }

    private var sceneIndicator: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index <= scene ? Color.pink : Color.secondary.opacity(0.22))
                    .frame(width: 30, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(scene + 1) of 3")
    }

    private var reveal: some View {
        VStack(spacing: 26) {
            if model.isScanning || (model.report == nil && model.scanError == nil) {
                PigMascot(mood: .sniffing, size: 148)
                Text("Checking who forgot to clock out…").font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Looking only. Nothing will close.").font(.title3).foregroundStyle(.secondary)
                ProgressView().controlSize(.large)
            } else {
                HStack(spacing: 34) {
                    PigMascot(mood: revealMood, size: 150)
                    VStack(alignment: .leading, spacing: 14) {
                        Text(revealTitle).font(.system(size: 36, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(revealBody).font(.title3).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Label("This check changed nothing", systemImage: "checkmark.shield.fill")
                            .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    }.frame(maxWidth: 430, alignment: .leading)
                }
                if model.scanError != nil {
                    Button("Try again") { sniff(stayHere: true) }.buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button { move(to: 2) } label: {
                        Label("Continue", systemImage: "arrow.right.circle.fill")
                    }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }
        }.frame(maxWidth: 650)
    }

    private var watchChoice: some View {
        HStack(spacing: 38) {
            PigStage(mood: .pleased, caption: "One last thing.\nThen I’ll get to work.").frame(width: 230)
            VStack(alignment: .leading, spacing: 18) {
                Text("Should the pig keep watch?").font(.system(size: 34, weight: .bold, design: .rounded))
                Text("You stay in control either way.").font(.title3).foregroundStyle(.secondary)
                ChoiceCard(title: "Keep watch for me", detail: "Checks every 2 minutes and opens Machogs when it catches something. It never closes anything alone.", selected: keepWatch) { keepWatch = true }
                ChoiceCard(title: "Only when I open Machogs", detail: "No background checks. Run one whenever your Mac feels wrong.", selected: !keepWatch) {
                    keepWatch = false; allowAlerts = false; startAtLogin = false
                }
                if keepWatch {
                    Toggle("Tell me when the pig catches something", isOn: $allowAlerts)
                    Toggle("Start Machogs after I log in", isOn: $startAtLogin)
                }
                if let error = settings.setupError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Button("Back") { move(to: 1) }.buttonStyle(.borderless)
                    Spacer()
                    Button { finish() } label: {
                        Label(finishing ? "Opening…" : finishLabel, systemImage: "sparkles")
                    }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(finishing)
                }
            }.frame(maxWidth: 450, alignment: .leading)
        }
    }

    private var revealTitle: String {
        if model.scanError != nil { return "The pig couldn’t get a clear scent." }
        if model.hasSwapPressure { return "Your Mac needs a restart." }
        guard let first = model.groups.first else { return "No freeloaders today." }
        if first.isHot { return "\(owner(first)) is making your Mac work hard." }
        return "\(owner(first)) left \(first.count) thing\(first.count == 1 ? "" : "s") running."
    }

    private var revealBody: String {
        if let error = model.scanError { return "Nothing changed. Try the read-only check again. \(error)" }
        if model.hasSwapPressure {
            return "Your Mac is using its disk as emergency working memory. That can make everything feel slow. Closing forgotten work will not undo it—save your work, then restart from the Apple menu."
        }
        guard let first = model.groups.first else { return "Your apps cleaned up after themselves. If your Mac still feels slow, Machogs did not find the cause." }
        let impact = first.isHot ? "This can cause heat, fan noise, and shorter battery life." : "It is idle, so it is not heating your Mac. It is still holding memory."
        let more = model.groups.count > 1 ? " There are \(model.groups.count - 1) more app groups you can inspect." : ""
        return "\(first.story) \(impact)\(more)"
    }

    private var revealMood: PigMood {
        if model.scanError != nil || model.hasSwapPressure || model.hasHotFinding { return .concerned }
        return model.groups.isEmpty ? .pleased : .curious
    }

    private var finishLabel: String {
        guard let first = model.groups.first else { return "Open Machogs" }
        return "Show me what \(owner(first)) left"
    }

    private func owner(_ group: FindingGroup) -> String { group.owner.isEmpty ? "An app" : group.owner }
    private func sniff(stayHere: Bool = false) { if !stayHere { move(to: 1) }; Task { await model.scan() } }
    private func move(to next: Int) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 1)) { scene = min(2, max(0, next)) }
    }
    private func finish() {
        finishing = true
        Task {
            _ = await settings.completeOnboarding(shoulderTaps: keepWatch && allowAlerts, startAtLogin: keepWatch && startAtLogin)
            finishing = false
        }
    }
}

private struct PigStage: View {
    let mood: PigMood
    let caption: String
    var showsSniffBubble = false
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.pink.opacity(0.13)).frame(width: 245, height: 245)
                Circle().stroke(Color.pink.opacity(0.10), lineWidth: 22).frame(width: 196, height: 196)
                PigMascot(mood: mood, size: 160)
                if showsSniffBubble { SniffBubble().offset(x: 82, y: -82) }
            }
            Text(caption).font(.title3.weight(.bold)).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

private struct SniffBubble: View {
    var body: some View {
        Text("sniff…")
            .font(.callout.weight(.semibold)).italic()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.pink.opacity(0.24)))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .accessibilityHidden(true)
    }
}

private struct ChoiceCard: View {
    let title: String, detail: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(selected ? Color.pink : Color.secondary)
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) }
                Spacer()
            }.padding(14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.pink.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.pink.opacity(0.45) : Color.secondary.opacity(0.15)))
    }
}

private struct WindowSizer: NSViewRepresentable {
    let width: CGFloat, height: CGFloat
    func makeNSView(context: Context) -> SizingView { SizingView(size: NSSize(width: width, height: height)) }
    func updateNSView(_ view: SizingView, context: Context) { view.desiredSize = NSSize(width: width, height: height); view.apply() }
    final class SizingView: NSView {
        var desiredSize: NSSize
        init(size: NSSize) { desiredSize = size; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.contentView?.frame.size != self.desiredSize else { return }
                window.setContentSize(self.desiredSize); window.center()
            }
        }
    }
}
