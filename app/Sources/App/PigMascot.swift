import SwiftUI

enum PigMood {
    case curious
    case sniffing
    case pleased
    case concerned
}

// The drawn pig, alive: it blinks on a lazy clock, perks its ears and blushes
// when you hover, oinks (snout pop + sound) when you tap it, and wears a
// flame badge when something is cooking the CPU. Every measurement is
// proportional so the same face stays crisp from 38pt to 160pt.
struct PigMascot: View {
    let mood: PigMood
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false
    @State private var blink = false
    @State private var hovering = false
    @State private var oink = false

    var body: some View {
        ZStack {
            if mood == .pleased {
                sparkle(x: -0.56, y: -0.30, delay: 0)
                sparkle(x: 0.58, y: -0.43, delay: 0.2)
                sparkle(x: 0.52, y: 0.22, delay: 0.4)
            }

            PigFace(blink: blink, hovering: hovering, oink: oink,
                    hot: mood == .concerned, squint: mood == .pleased)
                .frame(width: size, height: size)
                .shadow(color: (mood == .concerned ? Color.orange : Color.pink).opacity(0.24),
                        radius: size * 0.12, y: size * 0.06)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(moving && mood == .curious ? -4 : 3))
        .offset(y: moving && mood == .sniffing ? -4 : 0)
        .scaleEffect(moving && mood == .pleased ? 1.035 : 1)
        .onAppear { animate(mood) }
        .onChange(of: mood) { newMood in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { moving = false }
            DispatchQueue.main.async { animate(newMood) }
        }
        .task {
            // Blink on a lazy, slightly irregular clock — alive, not metronomic.
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000_000...5_000_000_000))
                guard !Task.isCancelled else { break }
                withAnimation(.spring(response: 0.11, dampingFraction: 0.92)) { blink = true }
                try? await Task.sleep(nanoseconds: 115_000_000)
                withAnimation(.spring(response: 0.18, dampingFraction: 0.72)) { blink = false }
            }
        }
        .onHover { h in
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.55)) {
                hovering = h
            }
        }
        .onTapGesture { doOink() }
        .accessibilityHidden(true)
    }

    private func doOink() {
        MachogsSound.pop()
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.35)) { oink = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { oink = false }
        }
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

// Compact rounded-triangle ear, designed to tuck into the top of the head.
private struct PigEarShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.width * 0.08, y: r.height * 0.92))
        p.addCurve(to: CGPoint(x: r.width * 0.37, y: r.height * 0.08),
                   control1: CGPoint(x: r.width * 0.10, y: r.height * 0.56),
                   control2: CGPoint(x: r.width * 0.16, y: r.height * 0.13))
        p.addCurve(to: CGPoint(x: r.width * 0.94, y: r.height * 0.88),
                   control1: CGPoint(x: r.width * 0.59, y: -r.height * 0.02),
                   control2: CGPoint(x: r.width * 0.91, y: r.height * 0.50))
        p.addCurve(to: CGPoint(x: r.width * 0.08, y: r.height * 0.92),
                   control1: CGPoint(x: r.width * 0.76, y: r.height),
                   control2: CGPoint(x: r.width * 0.28, y: r.height))
        return p
    }
}

// Small, high-set almond eyes rather than cartoon circles.
private struct PigEyeShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.midY),
                   control1: CGPoint(x: r.minX + r.width * 0.28, y: r.minY),
                   control2: CGPoint(x: r.maxX - r.width * 0.28, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.midY),
                   control1: CGPoint(x: r.maxX - r.width * 0.28, y: r.maxY),
                   control2: CGPoint(x: r.minX + r.width * 0.28, y: r.maxY))
        return p
    }
}

private struct PigSmileShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.height * 0.18))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.height * 0.18),
                   control1: CGPoint(x: r.width * 0.24, y: r.height * 0.92),
                   control2: CGPoint(x: r.width * 0.76, y: r.height * 0.92))
        return p
    }
}

private struct PigFlameShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX + r.width * 0.12, y: r.height * 0.58),
                   control1: CGPoint(x: r.width * 0.22, y: r.maxY),
                   control2: CGPoint(x: r.minX, y: r.height * 0.78))
        p.addCurve(to: CGPoint(x: r.width * 0.46, y: r.minY),
                   control1: CGPoint(x: r.width * 0.26, y: r.height * 0.38),
                   control2: CGPoint(x: r.width * 0.42, y: r.height * 0.24))
        p.addCurve(to: CGPoint(x: r.maxX - r.width * 0.08, y: r.height * 0.54),
                   control1: CGPoint(x: r.width * 0.74, y: r.height * 0.20),
                   control2: CGPoint(x: r.maxX, y: r.height * 0.34))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY),
                   control1: CGPoint(x: r.maxX, y: r.height * 0.78),
                   control2: CGPoint(x: r.width * 0.78, y: r.maxY))
        return p
    }
}

struct PigFace: View {
    let blink: Bool
    let hovering: Bool
    let oink: Bool
    let hot: Bool
    var squint = false

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                ear(s: s)
                    .rotationEffect(.degrees(hovering ? -3 : -12), anchor: .bottomTrailing)
                    .offset(x: -s * 0.205, y: -s * 0.305)
                ear(s: s)
                    .scaleEffect(x: -1)
                    .rotationEffect(.degrees(hovering ? 3 : 12), anchor: .bottomLeading)
                    .offset(x: s * 0.205, y: -s * 0.305)

                Ellipse()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.969, green: 0.780, blue: 0.745),
                                 Color(red: 0.937, green: 0.659, blue: 0.627)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.92, height: s * 0.84)
                    .overlay(
                        Ellipse()
                            .fill(LinearGradient(colors: [.clear,
                                                          Color(red: 0.68, green: 0.30, blue: 0.28).opacity(0.16)],
                                                 startPoint: .center, endPoint: .bottom))
                            .frame(width: s * 0.92, height: s * 0.84)
                    )
                    .overlay(
                        Ellipse()
                            .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.96, blue: 0.87).opacity(0.55),
                                                          .white.opacity(0)],
                                                 center: UnitPoint(x: 0.38, y: 0.12),
                                                 startRadius: 0, endRadius: s * 0.37))
                            .frame(width: s * 0.78, height: s * 0.56)
                            .offset(x: -s * 0.045, y: -s * 0.095)
                    )
                    .shadow(color: Color(red: 0.46, green: 0.20, blue: 0.18).opacity(0.20),
                            radius: s * 0.05, y: s * 0.038)
                    .offset(y: s * 0.06)

                Group {
                    blush(s: s).offset(x: -s * 0.315, y: s * 0.115)
                    blush(s: s).offset(x: s * 0.315, y: s * 0.115)
                }
                .opacity(hovering ? 0.78 : 0)
                .scaleEffect(hovering ? 1 : 0.2)

                Group {
                    eye(s: s).offset(x: -s * 0.125, y: -s * 0.035)
                    eye(s: s).offset(x: s * 0.125, y: -s * 0.035)
                }

                PigSmileShape()
                    .stroke(Color(red: 0.48, green: 0.20, blue: 0.19).opacity(0.60),
                            style: StrokeStyle(lineWidth: max(0.7, s * 0.018), lineCap: .round))
                    .frame(width: s * 0.18, height: s * 0.075)
                    .offset(y: s * 0.355)

                // This soft shadow is the contact point that makes the snout
                // read as a raised muzzle rather than a sticker.
                Capsule()
                    .fill(Color(red: 0.45, green: 0.18, blue: 0.19).opacity(0.17))
                    .frame(width: s * 0.44, height: s * 0.27)
                    .blur(radius: s * 0.035)
                    .offset(y: s * 0.225)
                    .scaleEffect(oink ? 1.25 : (hovering ? 1.06 : 1))

                snout(s: s)
                    .offset(y: s * 0.19)
                    .scaleEffect(oink ? 1.27 : (hovering ? 1.055 : 1))

                if hot {
                    flameBadge(s: s)
                        .offset(x: s * 0.34, y: -s * 0.31)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .frame(width: s, height: s)
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.spring(response: 0.30, dampingFraction: 0.64), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.48), value: oink)
            .animation(.spring(response: 0.36, dampingFraction: 0.78), value: hot)
            .compositingGroup()
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func ear(s: CGFloat) -> some View {
        ZStack {
            PigEarShape()
                .fill(LinearGradient(colors: [Color(red: 0.97, green: 0.75, blue: 0.72),
                                               Color(red: 0.88, green: 0.51, blue: 0.51)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            PigEarShape()
                .fill(Color(red: 0.70, green: 0.29, blue: 0.34).opacity(0.62))
                .scaleEffect(x: 0.54, y: 0.59, anchor: UnitPoint.bottom)
                .offset(y: s * 0.012)
        }
        .frame(width: s * 0.25, height: s * 0.30)
        .shadow(color: Color.black.opacity(0.12), radius: s * 0.022, y: s * 0.015)
    }

    private func eye(s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            PigEyeShape()
                .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.16, blue: 0.13),
                                               Color(red: 0.12, green: 0.055, blue: 0.045)],
                                     startPoint: .top, endPoint: .bottom))
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: s * 0.024, height: s * 0.024)
                .offset(x: s * 0.016, y: s * 0.014)
        }
        .frame(width: s * (hovering ? 0.098 : 0.092),
               height: s * (hovering ? 0.155 : 0.145))
        // A happy squint (pleased) and a blink share the same lid.
        .scaleEffect(y: blink ? 0.08 : (squint ? 0.22 : 1), anchor: .center)
    }

    private func blush(s: CGFloat) -> some View {
        Ellipse()
            .fill(RadialGradient(colors: [Color(red: 0.88, green: 0.32, blue: 0.38).opacity(0.58),
                                          Color(red: 0.88, green: 0.32, blue: 0.38).opacity(0)],
                                 center: .center, startRadius: 0, endRadius: s * 0.10))
            .frame(width: s * 0.20, height: s * 0.115)
    }

    private func snout(s: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 0.99, green: 0.72, blue: 0.72),
                                               Color(red: 0.91, green: 0.49, blue: 0.53)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    Capsule()
                        .stroke(LinearGradient(colors: [Color(red: 1.0, green: 0.94, blue: 0.87).opacity(0.70),
                                                        .white.opacity(0.04)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: max(0.6, s * 0.016))
                )
                .shadow(color: Color(red: 0.50, green: 0.16, blue: 0.18).opacity(0.22),
                        radius: s * 0.025, y: s * 0.018)
            HStack(spacing: s * 0.115) {
                nostril(s: s)
                nostril(s: s)
            }
        }
        .frame(width: s * 0.44, height: s * 0.27)
    }

    private func nostril(s: CGFloat) -> some View {
        Ellipse()
            .fill(LinearGradient(colors: [Color(red: 0.38, green: 0.15, blue: 0.16),
                                          Color(red: 0.56, green: 0.22, blue: 0.24)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: s * 0.068, height: s * 0.112)
            .overlay(Ellipse().stroke(Color.white.opacity(0.10), lineWidth: s * 0.008))
    }

    private func flameBadge(s: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.white, Color(red: 1.0, green: 0.82, blue: 0.67)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Color.orange.opacity(0.42), radius: s * 0.045, y: s * 0.018)
            PigFlameShape()
                .fill(LinearGradient(colors: [.yellow, .orange, .red],
                                     startPoint: .bottom, endPoint: .top))
                .padding(s * 0.055)
        }
        .frame(width: s * 0.29, height: s * 0.29)
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
