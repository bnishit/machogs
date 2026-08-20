import AppKit
import SwiftUI

@MainActor
enum MachogsSound {
    private static var lastPlayed = Date.distantPast

    static func pop(enabled: Bool = true) {
        play("Pop", enabled: enabled)
    }

    /// The bigger "win" chime — disk space recovered.
    static func win(enabled: Bool = true) {
        play("Glass", enabled: enabled)
    }

    private static func play(_ name: String, enabled: Bool) {
        guard enabled else { return }
        guard Date().timeIntervalSince(lastPlayed) > 0.2 else { return }
        lastPlayed = Date()
        if NSSound(named: NSSound.Name(name))?.play() != true { NSSound.beep() }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

struct PigPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.58),
                value: configuration.isPressed
            )
    }
}

struct PigActionStyle: ButtonStyle {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .shadow(color: tint.opacity(configuration.isPressed ? 0.18 : 0.4), radius: 4, y: 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.58),
                value: configuration.isPressed
            )
    }
}

struct ConfettiBurst: View {
    let trigger: Int

    private struct Particle {
        let emoji: String
        let x: CGFloat
        let velocityX: CGFloat
        let velocityY: CGFloat
        let size: CGFloat
        let delay: Double
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var particles: [Particle] = []
    @State private var start: Date?
    @State private var active = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !active || reduceMotion)) { timeline in
            Canvas { context, size in
                guard let start else { return }
                let elapsed = timeline.date.timeIntervalSince(start)
                for particle in particles {
                    let time = elapsed - particle.delay
                    guard time > 0, time < 1.4 else { continue }
                    let x = size.width * particle.x + particle.velocityX * time
                    let y = size.height * 0.24 + particle.velocityY * time + 520 * time * time
                    context.opacity = max(0, 1.25 - time)
                    context.draw(
                        context.resolve(Text(particle.emoji).font(.system(size: particle.size))),
                        at: CGPoint(x: x, y: y)
                    )
                }
            }
        }
        .overlay {
            if reduceMotion && active {
                HStack(spacing: 32) {
                    Text("✨").font(.system(size: 28))
                    Text("🐷").font(.system(size: 34))
                    Text("✨").font(.system(size: 28))
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { value in fire(value) }
    }

    private func fire(_ value: Int) {
        guard value > 0 else { return }
        let emojis = ["🎉", "✨", "⚡", "💥", "🐷"]
        particles = (0..<30).map { _ in
            Particle(
                emoji: emojis.randomElement() ?? "🎉",
                x: CGFloat.random(in: 0.3...0.7),
                velocityX: CGFloat.random(in: -240...240),
                velocityY: CGFloat.random(in: -460 ... -180),
                size: CGFloat.random(in: 13...26),
                delay: Double.random(in: 0...0.12)
            )
        }
        start = Date()
        withAnimation(.easeOut(duration: 0.12)) { active = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.7 : 1.8)) {
            withAnimation(.easeOut(duration: 0.18)) { active = false }
        }
    }
}

// Cards lift toward the cursor.
struct HoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)
            .shadow(color: .black.opacity(hovering ? 0.16 : 0.05),
                    radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
            .onHover { h in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h }
            }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}

private struct JoyRevealModifier: ViewModifier {
    let appeared: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: reduceMotion || appeared ? 0 : 8)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.14)
                    : .spring(response: 0.48, dampingFraction: 0.82).delay(delay),
                value: appeared
            )
    }
}

extension View {
    func joyReveal(_ appeared: Bool, delay: Double) -> some View {
        modifier(JoyRevealModifier(appeared: appeared, delay: delay))
    }
}
