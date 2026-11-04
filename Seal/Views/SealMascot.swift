// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

// MARK: - Harbor

/// Harbor is the warm side of Seal. He appears on writing, onboarding and
/// empty-state surfaces, never where a person is deciding whether to trust a
/// key or authorize a release.
enum HarborState: Equatable {
    case idle
    case listening
    case waiting
    case receiving
    case protecting
    case releasing
    case edgePeek
    case still
}

private struct HarborBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: p(0.08, 0.80))
        path.addCurve(to: p(0.19, 0.40), control1: p(0.08, 0.61), control2: p(0.11, 0.47))
        path.addCurve(to: p(0.50, 0.25), control1: p(0.27, 0.30), control2: p(0.39, 0.25))
        path.addCurve(to: p(0.81, 0.40), control1: p(0.61, 0.25), control2: p(0.74, 0.30))
        path.addCurve(to: p(0.92, 0.80), control1: p(0.89, 0.48), control2: p(0.92, 0.62))
        path.addCurve(to: p(0.50, 0.93), control1: p(0.83, 0.91), control2: p(0.68, 0.93))
        path.addCurve(to: p(0.08, 0.80), control1: p(0.31, 0.93), control2: p(0.17, 0.91))
        path.closeSubpath()
        return path
    }
}

private struct HarborFlipperShape: Shape {
    var mirrored = false

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let unitX = mirrored ? 1 - x : x
            return CGPoint(x: rect.minX + rect.width * unitX, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.12, 0.18))
        path.addCurve(to: point(0.90, 0.83), control1: point(0.36, 0.24), control2: point(0.62, 0.61))
        path.addCurve(to: point(0.45, 0.95), control1: point(0.80, 0.97), control2: point(0.59, 1.0))
        path.addCurve(to: point(0.12, 0.18), control1: point(0.20, 0.76), control2: point(0.04, 0.39))
        path.closeSubpath()
        return path
    }
}

private struct HarborWhiskers: Shape {
    var mirrored = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for row in 0..<3 {
            let y = rect.minY + rect.height * (0.28 + CGFloat(row) * 0.22)
            let startX = mirrored ? rect.maxX : rect.minX
            let endX = mirrored ? rect.minX : rect.maxX
            let bend = CGFloat(row - 1) * rect.height * 0.08
            path.move(to: CGPoint(x: startX, y: y))
            path.addQuadCurve(
                to: CGPoint(x: endX, y: y + bend),
                control: CGPoint(x: rect.midX, y: y - rect.height * 0.08)
            )
        }
        return path
    }
}

private struct HarborMouth: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.height * 0.42))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.height * 0.50),
            control: CGPoint(x: rect.width * 0.34, y: rect.height * 0.72)
        )
        path.move(to: CGPoint(x: rect.midX, y: rect.height * 0.42))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.50),
            control: CGPoint(x: rect.width * 0.66, y: rect.height * 0.72)
        )
        return path
    }
}

private struct HarborEnvelope: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.06, style: .continuous)
                    .fill(Color(red: 0.90, green: 0.86, blue: 0.77))
                    .overlay {
                        RoundedRectangle(cornerRadius: w * 0.06, style: .continuous)
                            .stroke(Color.black.opacity(0.18), lineWidth: max(1, w * 0.015))
                    }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: w / 2, y: h * 0.58))
                    path.addLine(to: CGPoint(x: w, y: 0))
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.57))
                    path.move(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.57))
                }
                .stroke(Color.black.opacity(0.20), style: StrokeStyle(lineWidth: max(1, w * 0.014), lineCap: .round))
                Circle()
                    .fill(SealTheme.brass)
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: max(1, w * 0.012)))
                    .frame(width: w * 0.22)
                    .position(x: w / 2, y: h * 0.58)
            }
        }
        .aspectRatio(1.45, contentMode: .fit)
    }
}

/// The native Harbor rig. Each visible part stays separate so animation does
/// not need a bitmap, a package, or a second drawing system.
struct HarborFigure: View {
    var state: HarborState = .idle
    var animated = true
    var tint: Color = Color(white: 0.20)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breath: CGFloat = 0
    @State private var blink: CGFloat = 1
    @State private var action: CGFloat = 0

    private var silver: Color { Color(red: 0.61, green: 0.59, blue: 0.55) }
    private var paper: Color { Color(red: 0.90, green: 0.86, blue: 0.77) }

    private var eyesClosed: Bool { state == .waiting || state == .protecting }

    private var envelopeVisible: Bool {
        switch state {
        case .waiting, .receiving, .protecting, .releasing: true
        default: false
        }
    }

    private var envelopeOffset: CGSize {
        switch state {
        case .receiving:
            CGSize(width: (1 - action) * 88, height: (1 - action) * 10)
        case .releasing:
            CGSize(width: action * 120, height: -action * 10)
        default:
            .zero
        }
    }

    private var envelopeOpacity: Double {
        state == .releasing ? Double(1 - action * 0.65) : 1
    }

    private var headRotation: Double { state == .listening ? -3.5 : 0 }
    private var figureOffset: CGFloat { state == .edgePeek ? 0.32 : 0 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.24))
                    .frame(width: w * 0.82, height: h * 0.08)
                    .position(x: w * 0.50, y: h * 0.90)

                HarborBodyShape()
                    .fill(tint)
                    .overlay {
                        HarborBodyShape()
                            .fill(LinearGradient(colors: [.white.opacity(0.06), .clear, .black.opacity(0.10)],
                                                 startPoint: .top, endPoint: .bottom))
                    }

                Group {
                    Ellipse().frame(width: w * 0.10, height: h * 0.055).rotationEffect(.degrees(-18))
                        .position(x: w * 0.25, y: h * 0.48)
                    Ellipse().frame(width: w * 0.065, height: h * 0.042).rotationEffect(.degrees(16))
                        .position(x: w * 0.19, y: h * 0.58)
                    Ellipse().frame(width: w * 0.045, height: h * 0.030).rotationEffect(.degrees(-8))
                        .position(x: w * 0.31, y: h * 0.62)
                }
                .foregroundStyle(silver.opacity(0.70))

                ZStack {
                    Circle()
                        .fill(tint)
                        .frame(width: w * 0.47, height: w * 0.47)

                    Ellipse()
                        .fill(silver.opacity(0.88))
                    .frame(width: w * 0.29, height: h * 0.13)
                    .offset(y: h * 0.055)

                    HStack(spacing: w * 0.09) {
                        Capsule().fill(silver.opacity(0.90)).frame(width: w * 0.105, height: h * 0.025)
                        Capsule().fill(silver.opacity(0.90)).frame(width: w * 0.105, height: h * 0.025)
                    }
                    .offset(y: -h * 0.075)

                    HStack(spacing: w * 0.115) {
                        eye(width: w, height: h)
                        eye(width: w, height: h)
                    }
                    .offset(y: -h * 0.025)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.black.opacity(0.88))
                        .frame(width: w * 0.060, height: h * 0.035)
                        .offset(y: h * 0.035)

                    HarborMouth()
                    .stroke(Color.black.opacity(0.72), style: StrokeStyle(lineWidth: max(1, w * 0.008), lineCap: .round))
                    .frame(width: w * 0.10, height: h * 0.055)
                    .offset(y: h * 0.067)

                    HStack(spacing: w * 0.245) {
                        HarborWhiskers(mirrored: true)
                        HarborWhiskers()
                    }
                    .foregroundStyle(paper.opacity(0.85))
                    .frame(width: w * 0.61, height: h * 0.12)
                    .offset(y: h * 0.07)
                }
                .frame(width: w * 0.47, height: w * 0.47)
                .rotationEffect(.degrees(headRotation), anchor: .bottom)
                .position(x: w * 0.50, y: h * (0.31 + breath * 0.004))

                if envelopeVisible {
                    HarborEnvelope()
                        .frame(width: w * 0.23)
                        .offset(envelopeOffset)
                        .opacity(envelopeOpacity)
                        .position(x: w * 0.50, y: h * 0.73)
                        .zIndex(2)
                }

                HarborFlipperShape()
                    .fill(tint.opacity(0.98))
                    .frame(width: w * 0.30, height: h * 0.42)
                    .rotationEffect(.degrees(state == .receiving ? -8 + action * 7 : 0), anchor: .top)
                    .position(x: w * 0.36, y: h * 0.69)
                    .zIndex(3)
                HarborFlipperShape(mirrored: true)
                    .fill(tint.opacity(0.98))
                    .frame(width: w * 0.30, height: h * 0.42)
                    .rotationEffect(.degrees(state == .releasing ? action * -8 : 0), anchor: .top)
                    .position(x: w * 0.64, y: h * 0.69)
                    .zIndex(3)

                VStack(spacing: 0) {
                    Capsule().fill(SealTheme.brass.opacity(0.88)).frame(width: w * 0.012, height: h * 0.12)
                    ZStack {
                        Circle().fill(SealTheme.brass)
                        Image(systemName: "envelope")
                            .font(.system(size: max(7, w * 0.038), weight: .semibold))
                            .foregroundStyle(SealTheme.ink.opacity(0.75))
                    }
                    .frame(width: w * 0.10, height: w * 0.10)
                }
                .position(x: w * 0.50, y: h * 0.52)
                .zIndex(4)
            }
            .scaleEffect(y: 1 + breath * 0.012, anchor: .bottom)
            .offset(x: w * figureOffset)
        }
        .aspectRatio(1.18, contentMode: .fit)
        .accessibilityHidden(true)
        .task(id: state) { await animate() }
    }

    private func eye(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Capsule().fill(Color(red: 0.77, green: 0.68, blue: 0.54))
            Circle()
                .fill(Color.black.opacity(0.88))
                .padding(max(0.8, width * 0.009))
        }
        .frame(width: width * 0.075, height: height * 0.032)
        .scaleEffect(y: eyesClosed ? 0.08 : blink)
    }

    @MainActor
    private func animate() async {
        breath = 0
        blink = eyesClosed ? 0.08 : 1
        action = 0
        guard animated, !reduceMotion else {
            if state == .receiving || state == .releasing { action = 1 }
            return
        }

        switch state {
        case .receiving:
            withAnimation(.easeInOut(duration: 1.1)) { action = 1 }
        case .releasing:
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 1.4)) { action = 1 }
        case .idle, .listening, .waiting:
            for cycle in 0..<3 {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 1.8)) { breath = 1 }
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 1.8)) { breath = 0 }
                try? await Task.sleep(for: .seconds(cycle == 1 ? 0.7 : 1.3))
                guard !Task.isCancelled, !eyesClosed else { continue }
                withAnimation(.easeOut(duration: 0.09)) { blink = 0.08 }
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.easeIn(duration: 0.12)) { blink = 1 }
            }
        case .protecting, .edgePeek, .still:
            break
        }
    }
}

// MARK: - Compatibility and empty states

/// Kept for the existing call sites. New surfaces should name the Harbor
/// state they need through `HarborFigure`.
struct SealFigure: View {
    var detailed = true
    var animated = false
    var tint: Color = Color(white: 0.20)

    var body: some View {
        HarborFigure(state: detailed ? .idle : .still, animated: animated, tint: tint)
    }
}

struct SealMascot: View {
    var size: CGFloat = 72
    var state: HarborState = .idle
    var line: String? = nil
    var sub: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            HarborFigure(state: state, animated: true)
                .frame(width: size * 1.5, height: size * 1.27)
            if let line {
                Text(line)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .multilineTextAlignment(.center)
            }
            if let sub {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.50))
                    .multilineTextAlignment(.center)
            }
        }
    }
}

#Preview("Harbor states") {
    ZStack {
        SealTheme.ink.ignoresSafeArea()
        ScrollView(.horizontal) {
            HStack(spacing: 28) {
                SealMascot(state: .idle, line: "I can wait.")
                SealMascot(state: .listening, line: "Take your time.")
                SealMascot(state: .protecting, line: "Kept safe.")
                SealMascot(state: .releasing, line: "When it is time.")
            }
            .padding(28)
        }
    }
}

/// Security surfaces get words and no animal.
struct PlainEmptyState: View {
    let line: String
    var sub: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Text(line)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            if let sub {
                Text(sub)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
    }
}
