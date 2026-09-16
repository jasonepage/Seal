// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  SealMark.swift
//  Seal
//
//  THE MARK. A wax seal drawn in code: an uneven wax edge, a pressed rim,
//  and a closed envelope in the middle. It replaces the stock
//  Image(systemName: "seal.fill") on the registration screen and the home
//  screen.
//
//  Colour rule (docs/GOTCHAS.md, house rules): pewter by default. Brass only
//  when `trust` is true, and the caller sets `trust` at a trust moment and
//  nowhere else. This is not the animal in SealMascot.swift. That one is for
//  social surfaces and never for a security surface.
//
//  Motion: one press on appear (the mark drops in and settles) and, when
//  asked, one pulse ring for a heartbeat. Both run once and then stop.
//  Nothing loops. With Reduce Motion on, the finished mark is shown at once
//  and the pulse ring is skipped.

// MARK: - Shapes

/// A circle with a slightly uneven edge, the way pressed wax spreads.
/// Deterministic, so the same mark is drawn every time.
struct WaxEdgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        let steps = 144
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * Double.pi
            let wobble = 1.0
                + 0.035 * sin(7 * t + 0.4)
                + 0.018 * sin(11 * t + 2.1)
                + 0.012 * sin(3 * t + 1.0)
            let r = radius * CGFloat(wobble)
            let point = CGPoint(x: center.x + r * CGFloat(cos(t)),
                                y: center.y + r * CGFloat(sin(t)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// A closed envelope: the outline and the V of the flap. Stroke it.
struct EnvelopeGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02)
        let corner = r.width * 0.06
        path.addRoundedRect(in: r, cornerSize: CGSize(width: corner, height: corner))
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.58))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return path
    }
}

// MARK: - The mark

struct SealMark: View {
    /// Diameter in points.
    var size: CGFloat = 96
    /// Brass when true. Only at a trust moment.
    var trust: Bool = false
    /// Drop in and settle once on appear.
    var pressOnAppear: Bool = true
    /// One ring that grows and fades once on appear: the heartbeat.
    var pulseOnAppear: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    @State private var pulsed = false

    private var animates: Bool { pressOnAppear && !reduceMotion }
    private var showsPulse: Bool { pulseOnAppear && !reduceMotion }

    private var wax: Color {
        trust ? SealTheme.brass : Color(white: 0.62)
    }
    private var waxShadow: Color {
        trust ? Color(red: 0.55, green: 0.39, blue: 0.12) : Color(white: 0.36)
    }
    private var waxLight: Color {
        trust ? Color(red: 0.96, green: 0.80, blue: 0.48) : Color(white: 0.78)
    }

    var body: some View {
        ZStack {
            if showsPulse {
                Circle()
                    .strokeBorder(wax.opacity(0.75), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(pulsed ? 1.9 : 1.0)
                    .opacity(pulsed ? 0 : 0.8)
            }

            ZStack {
                // The wax, lit from the upper left.
                WaxEdgeShape()
                    .fill(RadialGradient(colors: [waxLight, wax, waxShadow],
                                         center: UnitPoint(x: 0.38, y: 0.32),
                                         startRadius: 0,
                                         endRadius: size * 0.62))
                WaxEdgeShape()
                    .stroke(waxShadow.opacity(0.7), lineWidth: 1)

                // The pressed rim: a shallow groove.
                Circle()
                    .stroke(SealTheme.ink.opacity(0.32), lineWidth: max(1.5, size * 0.022))
                    .frame(width: size * 0.74, height: size * 0.74)
                Circle()
                    .stroke(waxLight.opacity(0.45), lineWidth: 1)
                    .frame(width: size * 0.69, height: size * 0.69)

                // The envelope pressed into the wax.
                EnvelopeGlyphShape()
                    .stroke(SealTheme.ink.opacity(0.78),
                            style: StrokeStyle(lineWidth: max(1.5, size * 0.036),
                                               lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.40, height: size * 0.28)
                    .offset(y: size * 0.01)
            }
            .frame(width: size, height: size)
            .scaleEffect(animates && !settled ? 1.14 : 1.0)
            .opacity(animates && !settled ? 0 : 1)
            .shadow(color: .black.opacity(0.45), radius: size * 0.06, x: 0, y: size * 0.03)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.4), value: trust)
        .accessibilityHidden(true)
        .task {
            guard animates || showsPulse else { return }
            if animates {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.55, bounce: 0.22)) { settled = true }
            }
            if showsPulse {
                try? await Task.sleep(for: .milliseconds(animates ? 520 : 200))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 1.4)) { pulsed = true }
            }
        }
    }
}

#Preview("Marks") {
    ZStack {
        SealTheme.ink.ignoresSafeArea()
        HStack(spacing: 32) {
            SealMark(size: 96, trust: false)
            SealMark(size: 96, trust: true, pulseOnAppear: true)
        }
    }
}
