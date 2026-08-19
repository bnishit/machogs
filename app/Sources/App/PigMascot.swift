import SwiftUI

enum PigMood {
    case curious
    case sniffing
    case pleased
    case concerned
}

struct PigMascot: View {
    let mood: PigMood
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    var body: some View {
        ZStack {
            if mood == .pleased {
                sparkle(x: -0.56, y: -0.30, delay: 0)
                sparkle(x: 0.58, y: -0.43, delay: 0.2)
                sparkle(x: 0.52, y: 0.22, delay: 0.4)
            }

            ear(rotation: -28).offset(x: -size * 0.29, y: -size * 0.30)
            ear(rotation: 28).offset(x: size * 0.29, y: -size * 0.30)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 1, green: 0.72, blue: 0.76), Color(red: 0.94, green: 0.43, blue: 0.52)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().stroke(.white.opacity(0.48), lineWidth: max(1, size * 0.025)))
                .frame(width: size * 0.76, height: size * 0.72)
                .shadow(color: Color.pink.opacity(0.24), radius: size * 0.12, y: size * 0.08)

            eyes
                .offset(y: -size * 0.08)

            Capsule()
                .fill(Color(red: 1, green: 0.66, blue: 0.72))
                .overlay(Capsule().stroke(Color(red: 0.72, green: 0.24, blue: 0.35).opacity(0.35), lineWidth: 1))
                .frame(width: size * 0.43, height: size * 0.28)
                .overlay {
                    HStack(spacing: size * 0.11) {
                        Circle().fill(Color(red: 0.48, green: 0.13, blue: 0.22)).frame(width: size * 0.055)
                        Circle().fill(Color(red: 0.48, green: 0.13, blue: 0.22)).frame(width: size * 0.055)
                    }
                }
                .offset(y: size * 0.17)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(moving && mood == .curious ? -4 : 3))
        .offset(y: moving && mood == .sniffing ? -4 : 0)
        .scaleEffect(moving && mood == .pleased ? 1.035 : 1)
        .onAppear {
            animate(mood)
        }
        .onChange(of: mood) { newMood in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { moving = false }
            DispatchQueue.main.async { animate(newMood) }
        }
        .accessibilityHidden(true)
    }

    private var eyes: some View {
        HStack(spacing: size * 0.19) {
            eye
            eye
        }
    }

    private var eye: some View {
        Capsule()
            .fill(Color(red: 0.22, green: 0.08, blue: 0.12))
            .frame(width: size * 0.075, height: mood == .pleased ? size * 0.035 : size * 0.13)
            .overlay(alignment: .topLeading) {
                if mood != .pleased {
                    Circle().fill(.white.opacity(0.85)).frame(width: size * 0.025).padding(size * 0.013)
                }
            }
    }

    private func ear(rotation: Double) -> some View {
        RoundedRectangle(cornerRadius: size * 0.09)
            .fill(Color(red: 0.91, green: 0.39, blue: 0.49))
            .overlay(RoundedRectangle(cornerRadius: size * 0.09).stroke(.white.opacity(0.35), lineWidth: 1))
            .frame(width: size * 0.30, height: size * 0.38)
            .rotationEffect(.degrees(rotation))
    }

    private func sparkle(x: CGFloat, y: CGFloat, delay: Double) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.16, weight: .bold))
            .foregroundStyle(Color.yellow)
            .offset(x: size * x, y: size * y)
            .scaleEffect(moving ? 1 : 0.55)
            .opacity(moving ? 1 : 0.4)
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.55).delay(delay), value: moving)
    }

    private func animate(_ mood: PigMood) {
        guard !reduceMotion else { return }
        let animation = mood == .sniffing
            ? Animation.spring(response: 0.75, dampingFraction: 0.58)
            : Animation.spring(response: 0.55, dampingFraction: 0.62)
        withAnimation(animation) { moving = true }
    }
}

struct SoftPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.thinMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            }
    }
}
