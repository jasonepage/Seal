import SwiftUI

// MARK: - The Seal, drawn properly

/// Side-profile silhouette of a hauled-out seal: chest up, head raised,
/// tail resting. Coordinate space 220×140, scaled to fit.
struct SealBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width / 220.0
        let h = rect.height / 140.0
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var p = Path()
        p.move(to: P(10, 55))                                                       // tail tip (raised)
        p.addCurve(to: P(120, 30), control1: P(50, 38), control2: P(85, 28))        // back
        p.addCurve(to: P(162, 16), control1: P(140, 28), control2: P(150, 16))      // neck rise
        p.addCurve(to: P(200, 38), control1: P(180, 16), control2: P(196, 24))      // crown
        p.addCurve(to: P(196, 52), control1: P(204, 44), control2: P(202, 50))      // snout
        p.addCurve(to: P(160, 64), control1: P(188, 60), control2: P(174, 64))      // chin
        p.addCurve(to: P(140, 96), control1: P(150, 72), control2: P(146, 84))      // chest
        p.addCurve(to: P(60, 104), control1: P(120, 106), control2: P(88, 108))     // belly
        p.addCurve(to: P(14, 70), control1: P(40, 100), control2: P(22, 84))        // rear
        p.addCurve(to: P(10, 55), control1: P(6, 64), control2: P(5, 58))           // tail underside
        p.closeSubpath()
        return p
    }
}

/// The drawn seal. `detailed` adds eye/nose/flipper/belly; false gives a
/// flat silhouette for tiny contexts (badges, colony bar).
struct SealFigure: View {
    var detailed = true
    var animated = false
    var tint: Color = Color(white: 0.72)

    @State private var breathing = false
    @State private var eyeOpen = true

    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            ZStack {
                if detailed {
                    // Body with soft top-light gradient
                    SealBodyShape()
                        .fill(LinearGradient(
                            colors: [Color(white: 0.82), Color(white: 0.55)],
                            startPoint: .top, endPoint: .bottom))
                    // Belly highlight
                    Ellipse()
                        .fill(Color(white: 0.9).opacity(0.35))
                        .frame(width: s.width * 0.38, height: s.height * 0.22)
                        .position(x: s.width * 0.5, y: s.height * 0.68)
                        .mask(SealBodyShape())
                    // Front flipper — resting on the body, not hanging off it
                    Ellipse()
                        .fill(Color(white: 0.45))
                        .frame(width: s.width * 0.15, height: s.height * 0.09)
                        .rotationEffect(.degrees(24))
                        .position(x: s.width * 0.54, y: s.height * 0.62)
                    // Eye (blinks)
                    Circle()
                        .fill(SealTheme.ink)
                        .frame(width: s.width * 0.045, height: s.width * 0.045)
                        .scaleEffect(y: eyeOpen ? 1 : 0.08)
                        .position(x: s.width * 0.78, y: s.height * 0.25)
                    // Eye glint — the one brass touch
                    Circle()
                        .fill(SealTheme.brass)
                        .frame(width: s.width * 0.014, height: s.width * 0.014)
                        .opacity(eyeOpen ? 1 : 0)
                        .position(x: s.width * 0.787, y: s.height * 0.235)
                    // Nose
                    Ellipse()
                        .fill(SealTheme.ink.opacity(0.85))
                        .frame(width: s.width * 0.035, height: s.width * 0.028)
                        .position(x: s.width * 0.905, y: s.height * 0.305)
                } else {
                    SealBodyShape().fill(tint)
                }
            }
            .scaleEffect(y: breathing ? 1.025 : 1.0, anchor: .bottom)
        }
        .aspectRatio(220.0 / 140.0, contentMode: .fit)
        .task {
            guard animated else { return }
            // Breathing: slow, anchored at the ground — like a resting animal.
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
            // Blink loop: irregular intervals so it reads as alive, not metronomic.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.4...4.8)))
                withAnimation(.easeOut(duration: 0.07)) { eyeOpen = false }
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.easeIn(duration: 0.10)) { eyeOpen = true }
            }
        }
    }
}

// MARK: - Mascot block (empty states, onboarding)

struct SealMascot: View {
    var size: CGFloat = 56          // height of the figure
    var line: String? = nil
    var sub: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            SealFigure(detailed: true, animated: true)
                .frame(height: size * 1.4)
            if let line {
                Text(line)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            if let sub {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
        }
    }
}

#Preview {
    ZStack {
        SealTheme.ink.ignoresSafeArea()
        SealMascot(size: 72, line: "No envelopes yet.", sub: "Write the first one.")
    }
}
