// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  OnboardingFigures.swift
//  Seal
//
//  THE PICTURES THAT TEACH. Six drawings, all in code, all finite:
//
//    ReleaseTimelineFigure   the days count, the warnings ring, the owner's
//                            one tap stops it, or the keys can be tapped.
//    KeysTurningFigure       N keys, M turn, the envelope opens on the Mth.
//    ShamirCurveFigure       one point and the line could be anything; M
//                            points and the secret falls out at the edge.
//    KeyKeepFigure           a key at rest. The key holder's whole job.
//    TwoPhonesFigure         two phones side by side; a key crosses from
//                            each to the other. The couple path.
//    SpareKeyFigure          the key you use and the spare you put away.
//                            The backup key screen.
//
//  Every figure animates once on appear and then stops. Nothing loops.
//  With Reduce Motion on, each figure shows its finished state at once with
//  the same caption, so a person who turned motion off loses only the
//  movement.
//
//  Every number drawn here comes from OnboardingNumbers, which is filled
//  from ReleasePolicy defaults or from a real estate. Nothing is invented.
//  These views touch no engine and no clock. They are drawings.

// MARK: - The numbers a drawing needs

struct OnboardingNumbers: Hashable {
    var silenceDays: Int = ReleasePolicy.defaultSilenceDays
    var warningDays: Int = ReleasePolicy.defaultWarningDays
    var graceDays: Int = ReleasePolicy.defaultGraceDays
    var threshold: Int = 2
    var custodianCount: Int = 3
    /// True when these came from a real estate rather than the defaults.
    /// Copy says "usually any two of three" when this is false.
    var exact: Bool = false
    /// How often a key holder is asked to tap their key to show they still
    /// have it (ReleasePolicy.custodyConfirmMonths). Read from the real
    /// rule when there is one; the policy default otherwise. Never typed
    /// into copy.
    var custodyConfirmMonths: Int = ReleasePolicy.defaultCustodyConfirmMonths

    static let defaults = OnboardingNumbers()

    init() {}

    init(silenceDays: Int, warningDays: Int, graceDays: Int,
         threshold: Int, custodianCount: Int, exact: Bool,
         custodyConfirmMonths: Int = ReleasePolicy.defaultCustodyConfirmMonths) {
        self.silenceDays = max(1, silenceDays)
        self.warningDays = max(1, warningDays)
        self.graceDays = max(0, graceDays)
        self.threshold = max(1, threshold)
        self.custodianCount = max(self.threshold, custodianCount)
        self.exact = exact
        self.custodyConfirmMonths = max(1, custodyConfirmMonths)
    }

    /// The owner's own rule.
    init(policy: ReleasePolicy, custodianCount: Int) {
        self.init(silenceDays: policy.silenceDays, warningDays: policy.warningDays,
                  graceDays: policy.graceDays, threshold: policy.threshold,
                  custodianCount: custodianCount, exact: true,
                  custodyConfirmMonths: policy.custodyConfirmMonths)
    }

    /// An estate this phone guards. The snapshot carries the policy the
    /// owner published; the epoch carries the threshold and the custodians.
    /// Either may be missing before the owner has sealed.
    init(guarded: GuardedEstate, snapshot: ReleaseSnapshot?) {
        let policy = snapshot?.policy
        let epoch = guarded.epoch
        let threshold = epoch?.threshold ?? policy?.threshold ?? 2
        let count = epoch?.custodianHashes.count ?? 3
        self.init(silenceDays: policy?.silenceDays ?? ReleasePolicy.defaultSilenceDays,
                  warningDays: policy?.warningDays ?? ReleasePolicy.defaultWarningDays,
                  graceDays: policy?.graceDays ?? ReleasePolicy.defaultGraceDays,
                  threshold: threshold,
                  custodianCount: count,
                  exact: epoch != nil,
                  custodyConfirmMonths: policy?.custodyConfirmMonths ?? ReleasePolicy.defaultCustodyConfirmMonths)
    }

    var totalDays: Int { silenceDays + warningDays + graceDays }

    /// "Once a year," or "Every six months," and so on, for the start of a
    /// sentence about the key holder's yearly tap.
    var custodyConfirmLead: String {
        switch custodyConfirmMonths {
        case 12: return "Once a year,"
        case 6: return "Every six months,"
        case 24: return "Every two years,"
        case 1: return "Every month,"
        default: return "Every \(custodyConfirmMonths) months,"
        }
    }

    /// TRUE WHEN ONE KEY HOLDER ALONE CAN RELEASE THE ESTATE.
    ///
    /// Every screen in this app promises a key holder that their key opens
    /// nothing on its own. At a threshold of 1 that promise is FALSE, and it
    /// is false in the most dangerous direction: it tells somebody they are
    /// powerless while handing them sole control of the whole vault.
    ///
    /// A threshold of 1 is not a mistake and not always avoidable. With
    /// exactly one key holder it is the only rule there is. So this is not a
    /// thing to prevent, it is a thing every piece of copy has to check
    /// before it reassures anybody.
    var oneIsEnough: Bool { threshold <= 1 }

    /// How many key holders there are besides the one being spoken to.
    var others: Int { max(0, custodianCount - 1) }

    /// "any 2 of 3", or "all 3" when every key is needed, or "the one key
    /// holder" when one is enough, or "usually any 2 of 3" when these are
    /// defaults rather than a real rule. Never "any 1 of 1", which is both
    /// untrue in spirit and not English, and never "any 3 of 3".
    var anyMofN: String {
        if oneIsEnough { return custodianCount <= 1 ? "the one key holder" : "any one key holder" }
        let core = threshold == custodianCount ? "all \(custodianCount)" : "any \(threshold) of \(custodianCount)"
        return exact ? core : "usually " + core
    }
}

// MARK: - Shared bits

/// A caption under a figure. Read aloud, it is the one sentence the
/// drawing is making.
private struct FigureCaption: View {
    let text: String
    var tint: Color = .white.opacity(0.75)

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .animation(nil, value: text)
    }
}

// MARK: - The timeline

/// The countdown that is the product. A track in three parts: the quiet
/// days, the warning days, the quiet days after. A day counter runs along
/// it. Then one of three endings, chosen by the caller.
struct ReleaseTimelineFigure: View {
    enum Outcome: Hashable {
        /// Stop at the end of the silence: "a key holder may start a claim."
        case silenceOnly
        /// Run into the warnings, then the owner taps once and it all resets.
        case ownerStops
        /// Run all the way: "keys can be tapped now."
        case keysCanTap
    }

    let numbers: OnboardingNumbers
    let outcome: Outcome

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var day = 0
    @State private var tapVisible = false
    @State private var stopped = false
    @State private var finished = false
    @State private var bell = false

    /// Segment widths are for reading, not to scale: fourteen days at true
    /// scale is a sliver nobody could label.
    private let fractions: [CGFloat] = [0.46, 0.30, 0.24]

    private var stopDay: Int { numbers.silenceDays + max(1, numbers.warningDays / 2) }

    private var endDay: Int {
        switch outcome {
        case .silenceOnly: numbers.silenceDays
        case .ownerStops: stopDay
        case .keysCanTap: numbers.totalDays
        }
    }

    private var inWarnings: Bool {
        day > numbers.silenceDays && day <= numbers.silenceDays + numbers.warningDays
    }

    /// Fraction of the track filled for the current day.
    private var fill: CGFloat {
        let s = CGFloat(numbers.silenceDays)
        let w = CGFloat(numbers.warningDays)
        let g = CGFloat(max(numbers.graceDays, 1))
        let d = CGFloat(day)
        if d <= s { return fractions[0] * (d / s) }
        if d <= s + w { return fractions[0] + fractions[1] * ((d - s) / w) }
        let rest = min(d - s - w, g)
        return fractions[0] + fractions[1] + fractions[2] * (rest / g)
    }

    private var caption: String {
        if !finished { return "Day \(day)" }
        switch outcome {
        case .silenceOnly:
            return "Day \(numbers.silenceDays). A key holder may start a claim now. Not before."
        case .ownerStops:
            return "The owner tapped once. Stopped. Nothing opened."
        case .keysCanTap:
            return "Day \(numbers.totalDays). Keys can be tapped now."
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            // The counter
            HStack(spacing: 8) {
                Image(systemName: "bell.fill")
                    .foregroundStyle(inWarnings ? Color.orange : Color.white.opacity(0.18))
                    .scaleEffect(bell ? 1.18 : 1.0)
                    .animation(.easeInOut(duration: 0.16), value: bell)
                Text(finished ? caption : "Day \(day)")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(stopped ? SealTheme.brass : .white)
                    .contentTransition(.numericText(value: Double(day)))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            // The track
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 3) {
                        segment(width: w * fractions[0] - 2, base: Color.white.opacity(0.12))
                        segment(width: w * fractions[1] - 2, base: Color.orange.opacity(0.30))
                        segment(width: w * fractions[2] - 2, base: Color.white.opacity(0.12))
                    }
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: max(0, w * fill), height: 10)
                        .padding(.vertical, 5)
                    if tapVisible {
                        Image(systemName: "hand.tap.fill")
                            .font(.title2)
                            .foregroundStyle(SealTheme.brass)
                            .offset(x: min(max(0, w * (stopped ? 0 : fill) - 14), w - 28), y: -26)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .frame(height: 20)
            // Always leave room for the hand above the track so the layout
            // does not jump when it appears.
            .padding(.top, outcome == .ownerStops ? 28 : 4)
            .accessibilityHidden(true)

            // The legend, as rows so it survives any text size.
            VStack(alignment: .leading, spacing: 6) {
                legendRow(Color.white.opacity(0.35), "\(numbers.silenceDays) days of quiet from the owner")
                legendRow(Color.orange.opacity(0.85), numbers.warningDays == 1
                          ? "1 day of warnings"
                          : "\(numbers.warningDays) days of daily warnings")
                legendRow(Color.white.opacity(0.35), numbers.graceDays == 0
                          ? "No extra quiet days"
                          : (numbers.graceDays == 1 ? "1 more quiet day" : "\(numbers.graceDays) more quiet days"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: outcome) { await run() }
    }

    private func segment(width: CGFloat, base: Color) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(base)
            .frame(width: max(0, width), height: 20)
    }

    private func legendRow(_ swatch: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(swatch).frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func showFinal() {
        switch outcome {
        case .silenceOnly:
            day = numbers.silenceDays
        case .ownerStops:
            day = 0
            tapVisible = true
            stopped = true
        case .keysCanTap:
            day = numbers.totalDays
        }
        finished = true
    }

    /// Main actor, so the state writes after each sleep land on the main
    /// thread. A plain async method would hop off it.
    @MainActor
    private func run() async {
        day = 0; tapVisible = false; stopped = false; finished = false; bell = false
        if reduceMotion { showFinal(); return }

        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }

        let frames = 140
        for f in 1...frames {
            guard !Task.isCancelled else { return }
            let d = Int((Double(f) / Double(frames) * Double(endDay)).rounded())
            withAnimation(.linear(duration: 0.025)) { day = d }
            if inWarnings, f % 9 == 0 { bell.toggle() }
            try? await Task.sleep(for: .milliseconds(25))
        }
        bell = false
        guard !Task.isCancelled else { return }

        switch outcome {
        case .silenceOnly, .keysCanTap:
            withAnimation(.easeOut(duration: 0.3)) { finished = true }
        case .ownerStops:
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { tapVisible = true }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.6, bounce: 0.12)) {
                day = 0
                stopped = true
                finished = true
            }
        }
    }
}

// MARK: - Keys

/// A key lying flat, head on the left. Coordinate space 100 by 40.
/// Fill with `FillStyle(eoFill: true)` so the hole in the head is a hole.
struct KeyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width / 100
        let h = rect.height / 40
        var p = Path()
        p.addEllipse(in: CGRect(x: rect.minX, y: rect.minY + 4 * h, width: 32 * w, height: 32 * h))
        p.addEllipse(in: CGRect(x: rect.minX + 10 * w, y: rect.minY + 14 * h, width: 12 * w, height: 12 * h))
        p.addRoundedRect(in: CGRect(x: rect.minX + 30 * w, y: rect.minY + 16 * h, width: 66 * w, height: 8 * h),
                         cornerSize: CGSize(width: 3 * w, height: 3 * h))
        p.addRect(CGRect(x: rect.minX + 74 * w, y: rect.minY + 24 * h, width: 6 * w, height: 9 * h))
        p.addRect(CGRect(x: rect.minX + 86 * w, y: rect.minY + 24 * h, width: 6 * w, height: 12 * h))
        return p
    }
}

/// An envelope whose flap opens. Closed, a pewter wax dot holds the flap.
struct EnvelopeOpenFigure: View {
    var open: Bool
    var trust: Bool = false
    /// The small wax dot on the flap tip. Off when a full SealMark sits on
    /// top instead (SealedEnvelopeFigure).
    var waxDot: Bool = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let bodyRect = CGRect(x: 0, y: h * 0.32, width: w, height: h * 0.68)
            ZStack(alignment: .top) {
                // Body
                RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(width: bodyRect.width, height: bodyRect.height)
                    .offset(y: bodyRect.minY)
                RoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                    .frame(width: bodyRect.width, height: bodyRect.height)
                    .offset(y: bodyRect.minY)
                // The pocket lines
                Path { p in
                    p.move(to: CGPoint(x: 0, y: bodyRect.maxY))
                    p.addLine(to: CGPoint(x: w / 2, y: bodyRect.minY + bodyRect.height * 0.55))
                    p.addLine(to: CGPoint(x: w, y: bodyRect.maxY))
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                // The flap, hinged at the top edge of the body
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 0))
                        p.addLine(to: CGPoint(x: w, y: 0))
                        p.addLine(to: CGPoint(x: w / 2, y: h * 0.42))
                        p.closeSubpath()
                    }
                    .fill(open ? Color.white.opacity(0.06) : Color.white.opacity(0.16))
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 0))
                        p.addLine(to: CGPoint(x: w, y: 0))
                        p.addLine(to: CGPoint(x: w / 2, y: h * 0.42))
                        p.closeSubpath()
                    }
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                    if waxDot {
                        Circle()
                            .fill(trust ? SealTheme.brass : Color(white: 0.62))
                            .frame(width: w * 0.13, height: w * 0.13)
                            .offset(y: h * 0.42 - w * 0.065)
                            .opacity(open ? 0 : 1)
                    }
                }
                .frame(width: w, height: h * 0.42, alignment: .top)
                .rotation3DEffect(.degrees(open ? 180 : 0), axis: (x: 1, y: 0, z: 0),
                                  anchor: .top, perspective: 0.4)
                .offset(y: bodyRect.minY)
            }
        }
        .aspectRatio(1.7, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// N keys in a row. M of them turn, one after another. The envelope below
/// stays shut until the Mth, then opens. The rest never turn.
struct KeysTurningFigure: View {
    let numbers: OnboardingNumbers

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turned = 0
    @State private var open = false

    private var count: Int { numbers.custodianCount }
    private var threshold: Int { numbers.threshold }

    private var caption: String {
        if turned == 0 {
            return count == 1 ? "One key was handed out." : "\(count) keys were handed out."
        }
        if turned < threshold {
            return "\(turned) \(turned == 1 ? "key" : "keys") turned. Still closed."
        }
        let spare = count - threshold
        let base = threshold == 1 ? "One key turned. Open." : "\(threshold) keys turned. Open."
        if spare == 0 { return base }
        return base + (spare == 1 ? " The other key was not needed." : " The other \(spare) keys were not needed.")
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                ForEach(0..<count, id: \.self) { i in
                    VStack(spacing: 6) {
                        KeyShape()
                            .fill(i < turned ? SealTheme.brass : Color.white.opacity(0.35),
                                  style: FillStyle(eoFill: true))
                            .aspectRatio(100.0 / 40.0, contentMode: .fit)
                            .frame(maxWidth: 84)
                            .rotationEffect(.degrees(i < turned ? 90 : 0))
                            .frame(height: 84)
                        Text("Key \(i + 1)")
                            .font(.caption2)
                            .foregroundStyle(i < turned ? SealTheme.brass : .white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            // Room above for the flap, which swings up past the top edge
            // when it opens.
            EnvelopeOpenFigure(open: open, trust: open)
                .frame(maxWidth: 150)
                .padding(.top, 40)

            FigureCaption(text: caption, tint: open ? SealTheme.brass : .white.opacity(0.75))
        }
        .task(id: numbers) { await run() }
    }

    /// Main actor, so the state writes after each sleep land on the main
    /// thread. A plain async method would hop off it.
    @MainActor
    private func run() async {
        turned = 0; open = false
        if reduceMotion {
            turned = threshold; open = true
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
        for k in 1...threshold {
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.5, bounce: 0.2)) { turned = k }
            try? await Task.sleep(for: .milliseconds(k == threshold ? 500 : 950))
        }
        guard !Task.isCancelled else { return }
        withAnimation(.spring(duration: 0.8, bounce: 0.15)) { open = true }
    }
}

// MARK: - The curve

/// The polynomial through a set of points, drawn across the unit square.
/// Points are in unit space: x left to right, y bottom to top.
struct LagrangeCurveShape: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard !points.isEmpty else { return p }
        let n = 72
        for i in 0...n {
            let x = Double(i) / Double(n)
            let y = Self.value(points, at: x)
            let pt = CGPoint(x: rect.minX + CGFloat(x) * rect.width,
                             y: rect.maxY - CGFloat(y) * rect.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    /// Lagrange form. Any M distinct points fix a polynomial of degree M-1.
    static func value(_ pts: [CGPoint], at x: Double) -> Double {
        var sum = 0.0
        for (i, pi) in pts.enumerated() {
            var term = Double(pi.y)
            for (j, pj) in pts.enumerated() where j != i {
                let denominator = Double(pi.x) - Double(pj.x)
                guard denominator != 0 else { continue }
                term *= (x - Double(pj.x)) / denominator
            }
            sum += term
        }
        return sum
    }
}

/// Shamir's scheme as a picture. The secret is where the curve meets the
/// left edge. Each key holder holds one other point. With fewer than M
/// points the curve could be any of a fan of curves. With M points it is
/// one curve and the secret falls out.
///
/// With a threshold of 2 the "curve" is a straight line, because that is
/// what a degree one polynomial is, and the caption says "line".
struct ShamirCurveFigure: View {
    let numbers: OnboardingNumbers

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = 0
    @State private var ghostsVisible = false
    @State private var trueTrim: CGFloat = 0
    @State private var secretOn = false
    @State private var finished = false

    private var threshold: Int { numbers.threshold }
    private var count: Int { max(numbers.custodianCount, threshold) }
    /// A degree of 0 is correct and reachable: one key holder, threshold 1,
    /// one point, a flat line. Flooring this at 1 drew a sloped line that
    /// one point cannot fix, so the brass secret dot floated off the line it
    /// was supposed to sit on.
    private var degree: Int { max(0, threshold - 1) }
    private var shapeWord: String { degree <= 1 ? "line" : "curve" }

    /// The x of each key holder's point, spread across the width.
    private var xs: [Double] {
        (0..<count).map { i in
            count == 1 ? 0.5 : 0.22 + 0.68 * Double(i) / Double(count - 1)
        }
    }

    /// The true polynomial. Fixed coefficients so the picture is the same
    /// every time; the secret is the constant term.
    private func trueY(_ x: Double) -> Double {
        let coefficients: [Double] = [0.58, -0.55, 0.40]
        var y = 0.0
        var power = 1.0
        for k in 0...degree {
            let c = k < coefficients.count ? coefficients[k] : 0
            y += c * power
            power *= x
        }
        return y
    }

    private var truePoints: [CGPoint] {
        xs.map { CGPoint(x: $0, y: trueY($0)) }
    }

    /// One ghost: the revealed true points plus made-up points at the
    /// missing positions. Seeded so it does not flicker on re-render.
    private func ghostPoints(index: Int) -> [CGPoint] {
        var seed = UInt64(index &* 7919 &+ revealed &* 104729 &+ 17)
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) % 10_000) / 10_000.0
        }
        var pts: [CGPoint] = Array(truePoints.prefix(revealed))
        var needed = threshold - revealed
        var k = revealed
        while needed > 0 {
            let x = k < xs.count ? xs[k] : 0.9 - 0.1 * Double(k - xs.count)
            pts.append(CGPoint(x: x, y: 0.08 + 0.84 * next()))
            needed -= 1
            k += 1
        }
        return pts
    }

    private var caption: String {
        if revealed == 0 { return "Each key holder holds one point on a hidden \(shapeWord)." }
        if revealed < threshold {
            let have = revealed == 1 ? "One point" : "\(revealed) points"
            return "\(have). The \(shapeWord) could be any of these. Nothing is learned."
        }
        if threshold == 1 {
            return "One point fixes this \(shapeWord), because the rule needs only one key holder."
        }
        return "\(threshold) points fix the \(shapeWord). Where it meets the edge is the secret."
    }

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { geo in
                let size = geo.size
                let plot = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                ZStack(alignment: .topLeading) {
                    // The edge
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 1.5, height: size.height)

                    // Ghost curves
                    ForEach(0..<9, id: \.self) { g in
                        LagrangeCurveShape(points: ghostPoints(index: g))
                            .stroke(Color.white.opacity(0.16), lineWidth: 1.2)
                    }
                    .opacity(ghostsVisible ? 1 : 0)

                    // The true curve
                    LagrangeCurveShape(points: Array(truePoints.prefix(threshold)))
                        .trim(from: 0, to: trueTrim)
                        .stroke(Color.white.opacity(0.85),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))

                    // Key holders' points
                    ForEach(0..<count, id: \.self) { i in
                        let p = truePoints[i]
                        let shown = i < revealed
                        let spare = finished && i >= threshold
                        Circle()
                            .fill(spare ? Color.white.opacity(0.25) : SealTheme.silver)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(SealTheme.ink, lineWidth: 1.5))
                            .position(x: plot.minX + p.x * plot.width,
                                      y: plot.maxY - p.y * plot.height)
                            .opacity(shown || spare ? 1 : 0)
                            .scaleEffect(shown || spare ? 1 : 0.4)
                    }

                    // The secret
                    let s = CGPoint(x: 0, y: trueY(0))
                    Circle()
                        .fill(SealTheme.brass)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(SealTheme.brass.opacity(0.5), lineWidth: 6).opacity(0.6))
                        .position(x: plot.minX, y: plot.maxY - s.y * plot.height)
                        .opacity(secretOn ? 1 : 0)
                        .scaleEffect(secretOn ? 1 : 0.3)
                }
                .clipped()
            }
            .frame(height: 150)
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(SealTheme.brass).frame(width: 10, height: 10)
                    .opacity(secretOn ? 1 : 0.25)
                    .accessibilityHidden(true)
                Text(secretOn ? "The secret. It opens everything." : "The secret sits on the edge. Nobody can see it yet.")
                    .font(.footnote)
                    .foregroundStyle(secretOn ? SealTheme.brass : .white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FigureCaption(text: caption)
        }
        .task(id: numbers) { await run() }
    }

    private func showFinal() {
        revealed = threshold
        ghostsVisible = false
        trueTrim = 1
        secretOn = true
        finished = true
    }

    /// Main actor, so the state writes after each sleep land on the main
    /// thread. A plain async method would hop off it.
    @MainActor
    private func run() async {
        revealed = 0; ghostsVisible = false; trueTrim = 0; secretOn = false; finished = false
        if reduceMotion { showFinal(); return }

        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        // Points appear one at a time, short of the threshold, with the fan.
        for k in 1..<max(2, threshold) where k < threshold {
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) { revealed = k }
            withAnimation(.easeInOut(duration: 0.6)) { ghostsVisible = true }
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
        }

        // The last point. The fan collapses to one curve.
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { revealed = threshold }
        withAnimation(.easeOut(duration: 0.5)) { ghostsVisible = false }
        withAnimation(.easeInOut(duration: 1.0)) { trueTrim = 1 }
        try? await Task.sleep(for: .milliseconds(1100))
        guard !Task.isCancelled else { return }

        withAnimation(.spring(duration: 0.5, bounce: 0.3)) {
            secretOn = true
            finished = true
        }
    }
}

// MARK: - A key at rest

/// The key holder's whole job, as a picture: a key, lying still, with the
/// years going by. One slow settle on appear and then nothing.
struct KeyKeepFigure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                KeyShape()
                    .fill(SealTheme.silver, style: FillStyle(eoFill: true))
                    .aspectRatio(100.0 / 40.0, contentMode: .fit)
                    .frame(width: 150)
                    .rotationEffect(.degrees(settled || reduceMotion ? -8 : -20))
                    .offset(y: settled || reduceMotion ? 0 : -14)
                    .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 4)
            }
            .frame(height: 130)
            .accessibilityHidden(true)

            HStack(spacing: 6) {
                ForEach(0..<10, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            FigureCaption(text: "Ten years, give or take. The key does nothing until then, and that is the job.")
        }
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.9, bounce: 0.25)) { settled = true }
        }
    }
}

// MARK: - A sealed envelope

/// A closed envelope with the mark pressed on the flap. For "what an
/// envelope is" and "someone wrote you one".
struct SealedEnvelopeFigure: View {
    var trust: Bool = false

    var body: some View {
        ZStack {
            EnvelopeOpenFigure(open: false, trust: false, waxDot: false)
                .frame(maxWidth: 190)
            SealMark(size: 44, trust: trust, pressOnAppear: true)
                .offset(y: 12)
        }
        .frame(height: 130)
        .accessibilityHidden(true)
    }
}

// MARK: - Two phones

/// The couple path in one picture. Two phones side by side, each with
/// its own envelope. A key crosses from each phone to the other, so each
/// holds a key for the other. The crossing is the handover, a two sided
/// receipt, so the keys turn brass when they land. One crossing on
/// appear and then nothing.
struct TwoPhonesFigure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var crossed = false

    private var caption: String {
        crossed
            ? "Each phone holds a key for the other."
            : "Two phones. Each writes its own envelopes."
    }

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let phoneW = min(92, w * 0.30)
                let phoneH = min(h, phoneW * 1.75)
                let leftX = w * 0.25
                let rightX = w * 0.75
                ZStack {
                    phone(width: phoneW, height: phoneH)
                        .position(x: leftX, y: h / 2)
                    phone(width: phoneW, height: phoneH)
                        .position(x: rightX, y: h / 2)

                    // Two keys. The upper one goes left to right, the
                    // lower one right to left. Each lands on the other
                    // phone's screen.
                    key(landed: crossed)
                        .position(x: crossed ? rightX : leftX, y: h * 0.40)
                    key(landed: crossed)
                        .rotationEffect(.degrees(180))
                        .position(x: crossed ? leftX : rightX, y: h * 0.62)
                }
            }
            .frame(height: 170)
            .accessibilityHidden(true)

            FigureCaption(text: caption, tint: crossed ? SealTheme.brass : .white.opacity(0.75))
        }
        .task { await run() }
    }

    private func phone(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: width * 0.18, style: .continuous)
                .fill(Color.white.opacity(0.06))
            RoundedRectangle(cornerRadius: width * 0.18, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
            // The envelope this phone writes, small, at the bottom of the
            // screen. Stroked, like the glyph in the mark.
            EnvelopeGlyphShape()
                .stroke(Color.white.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: width * 0.42, height: width * 0.30)
                .padding(.bottom, height * 0.12)
        }
        .frame(width: width, height: height)
    }

    private func key(landed: Bool) -> some View {
        KeyShape()
            .fill(landed ? SealTheme.brass : SealTheme.silver, style: FillStyle(eoFill: true))
            .aspectRatio(100.0 / 40.0, contentMode: .fit)
            .frame(width: 58)
            .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 3)
    }

    /// Main actor, so the state writes after each sleep land on the main
    /// thread. A plain async method would hop off it.
    @MainActor
    private func run() async {
        crossed = false
        if reduceMotion { crossed = true; return }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(duration: 0.9, bounce: 0.15)) { crossed = true }
    }
}

// MARK: - A spare key

/// The backup key screen. The key you use sits in front. A second key
/// slides in from the side and settles behind it, put away. Silver, both
/// of them: nothing here is a trust moment, it is a drawer.
struct SpareKeyFigure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)

                // The spare, behind and a little lower. It arrives from
                // the right and stops.
                KeyShape()
                    .fill(SealTheme.silver.opacity(0.55), style: FillStyle(eoFill: true))
                    .aspectRatio(100.0 / 40.0, contentMode: .fit)
                    .frame(width: 130)
                    .rotationEffect(.degrees(settled || reduceMotion ? 6 : 14))
                    .offset(x: settled || reduceMotion ? 22 : 160, y: 22)
                    .opacity(settled || reduceMotion ? 1 : 0)

                // The key in use, in front.
                KeyShape()
                    .fill(SealTheme.silver, style: FillStyle(eoFill: true))
                    .aspectRatio(100.0 / 40.0, contentMode: .fit)
                    .frame(width: 150)
                    .rotationEffect(.degrees(-8))
                    .offset(x: -16, y: -10)
                    .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 4)
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityHidden(true)

            FigureCaption(text: "One key you use. One spare, put away somewhere safe.")
        }
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.9, bounce: 0.2)) { settled = true }
        }
    }
}

#Preview("Figures") {
    ZStack {
        SealTheme.ink.ignoresSafeArea()
        ScrollView {
            VStack(spacing: 40) {
                ReleaseTimelineFigure(numbers: .defaults, outcome: .ownerStops)
                KeysTurningFigure(numbers: .defaults)
                ShamirCurveFigure(numbers: .defaults)
                KeyKeepFigure()
                SealedEnvelopeFigure()
                TwoPhonesFigure()
                SpareKeyFigure()
            }
            .padding(24)
        }
    }
}
