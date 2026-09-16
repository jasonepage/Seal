import SwiftUI

//  SealOnboardingView.swift
//  Seal
//
//  THE FIRST MINUTE. Two shared screens, then a fork by who is holding the
//  phone:
//
//    the sealer     writes envelopes and hands out keys       six screens
//    the key holder was handed a key and does nothing for years   four
//    the recipient  was written an envelope                        three
//
//  Every screen has one figure and teaches one thing the previous screen
//  did not. The figures live in OnboardingFigures.swift and run once each.
//
//  Three ways in:
//    1. First launch, before registration (RegistrationView), as
//       WelcomeCarousel, which is now a thin wrapper around this view.
//    2. You, then Help, then "How Seal works" (ProfileView), same wrapper.
//    3. "See how it opens" on a key holder's or recipient's home card,
//       which passes that estate's real numbers and starts on that path.
//
//  It is skippable at every screen and re-openable, and the Chapters menu
//  at the top jumps straight to any screen of any path.
//
//  This view touches no engine and no clock. It is a drawing. The DEBUG
//  Time Travel screen is not a substitute for it: that one moves the real
//  clock.
//
//  House rules kept here: no em dashes, plain words, never the word
//  "will", brass only on the trust moment (the finished mark, the owner's
//  tap, the keys that open).

// MARK: - Roles and screens

enum OnboardingRole: String, CaseIterable, Identifiable {
    case sealer
    case keyHolder
    case recipient

    var id: String { rawValue }

    /// The chapter heading in the menu.
    var menuTitle: String {
        switch self {
        case .sealer: "Setting it up for myself"
        case .keyHolder: "I was handed a key"
        case .recipient: "Someone wrote me an envelope"
        }
    }

    /// The last button on the path.
    var doneLabel: String {
        switch self {
        case .sealer: "Get started"
        case .keyHolder, .recipient: "Got it"
        }
    }
}

struct OnboardingScreen: Identifiable {
    enum Figure {
        case mark
        case ask
        case envelope
        case timeline(ReleaseTimelineFigure.Outcome)
        case keys
        case curve
        case keep
        case steps
    }

    let id: String
    let title: String
    let body: String
    let figure: Figure
    var steps: [String] = []
}

/// The script, in one place, so it can be read aloud and checked.
enum OnboardingScript {
    static let sharedCount = 2

    static func shared() -> [OnboardingScreen] {
        [
            OnboardingScreen(
                id: "why",
                title: "For the things only you know.",
                body: "The passwords. Where the safe deposit key is. The seed phrase. A letter to each of them. You seal them in envelopes now, for the people you leave behind. They stay closed until you are gone. Nobody can open one early. Not Apple, not us.",
                figure: .mark),
            OnboardingScreen(
                id: "ask",
                title: "Which one are you?",
                body: "Seal looks different for each of these. Pick the one that fits and we show you only what you need.",
                figure: .ask),
        ]
    }

    static func screens(for role: OnboardingRole, numbers n: OnboardingNumbers) -> [OnboardingScreen] {
        let shapeWord = n.threshold <= 2 ? "line" : "curve"
        switch role {
        case .sealer:
            return [
                OnboardingScreen(
                    id: "s.envelope",
                    title: "One envelope for each person.",
                    body: "An envelope holds a letter, a few photos, a voice message, and the secrets: passwords, where the documents are, the combination. You write one for each person. Only that person can ever read it.",
                    figure: .envelope),
                OnboardingScreen(
                    id: "s.checkin",
                    title: "Opening the app is your check-in.",
                    body: "Each time you open Seal, your phone quietly notes that you are here. Nobody else sees a thing. If you go quiet for \(n.silenceDays) days, one of your key holders can start a claim. Not before.",
                    figure: .timeline(.silenceOnly)),
                OnboardingScreen(
                    id: "s.warnings",
                    title: "\(n.warningDays) days of warnings, and one tap stops everything.",
                    body: "Once a claim starts, Seal warns you every day for \(n.warningDays) days, then waits \(n.graceDays) more quiet days. At any moment, one tap from you stops it cold. You do not need your key for that. A long stay in the hospital looks like silence from the outside, and the warnings are there for exactly that.",
                    figure: .timeline(.ownerStops)),
                OnboardingScreen(
                    id: "s.keys",
                    title: n.oneIsEnough
                        ? "Your key holder opens the envelopes."
                        : "Any \(n.threshold) of your \(n.custodianCount) keys open the envelopes.",
                    body: n.oneIsEnough
                        ? "You choose \(n.custodianCount == 1 ? "one person" : "people") you trust, in person. After all the warnings pass, \(n.anyMofN) taps. Then, and only then, the envelopes open on the phones of the people you wrote them for. Your rule needs only one person right now, so that person can act alone. You can change that on the rule screen."
                        : "You choose \(n.custodianCount) people you trust, in person. After all the warnings pass, any \(n.threshold) of them tap. Their phones combine the pieces. Then, and only then, the envelopes open on the phones of the people you wrote them for.",
                    figure: .keys),
                OnboardingScreen(
                    id: "s.curve",
                    title: "One key alone sees nothing.",
                    body: "Each key holds one point on a hidden \(shapeWord). One point alone could sit on any \(shapeWord) at all, so one key holder learns nothing, not even a hint. \(n.threshold) points fix the \(shapeWord), and where it meets the edge is the secret that opens everything. This is not a rule we made up. It is arithmetic, and it holds against us too.",
                    figure: .curve),
                OnboardingScreen(
                    id: "s.now",
                    title: "What you do now.",
                    body: "It takes an evening. After that, opening the app now and then is the whole job.",
                    figure: .steps,
                    steps: [
                        "Set up Seal with Face ID or a security key.",
                        "Meet each person face to face and add them.",
                        "Write an envelope for each of them.",
                        "Hand a key to \(n.custodianCount) people and set your rule.",
                        "Tap Seal.",
                    ]),
            ]
        case .keyHolder:
            return [
                OnboardingScreen(
                    id: "k.nothing",
                    title: n.oneIsEnough
                        ? "Nothing opens until the countdown ends."
                        : "You cannot open anything. Nobody can.",
                    body: n.oneIsEnough
                        ? "Until the person who asked you has gone quiet for a long time and every warning has run, nothing opens for anybody, including you. One tap from them stops it at any point. After all of that, their rule lets you act on your own."
                        : "Your key holds one piece of a puzzle. One piece alone is no clue at all, not even a hint. That is arithmetic, not a promise. It is why the person who trusted you could ask you without a second thought.",
                    figure: .curve),
                OnboardingScreen(
                    id: "k.several",
                    title: n.oneIsEnough ? "You are the only one." : "You are one of several.",
                    // At a threshold of 1 this screen must not say "your key
                    // alone does nothing". It does everything.
                    body: n.oneIsEnough
                        ? "The rule they chose needs only one person, and that person is you. Once they have gone quiet and every warning has run, your tap alone opens the envelopes for the people they were written for. Nothing opens before that, and one tap from them stops all of it at any point."
                        : (n.exact
                           ? "They asked \(n.others) other \(n.others == 1 ? "person" : "people") too. It takes \(n.threshold) of the \(n.custodianCount), acting together, to open anything. Your key alone does nothing, and that is the point."
                           : "They asked a few other people too. It takes more than one key to open anything, \(n.anyMofN). Your key alone does nothing, and that is the point."),
                    figure: .keys),
                OnboardingScreen(
                    id: "k.quiet",
                    title: "What happens if they go quiet.",
                    body: "If they stop opening Seal for \(n.silenceDays) days, you may start a claim, and the other key holders are told. They get a warning every day for \(n.warningDays) days, then \(n.graceDays) more quiet days. If they are alive and open the app, it all stops. Only after all of that can keys be tapped.",
                    figure: .timeline(.keysCanTap)),
                OnboardingScreen(
                    id: "k.keep",
                    title: "Your job is to still be findable.",
                    body: "Put the key somewhere you can find in ten years. A drawer you never clean out. A safe. With your passport. Keep Seal on your phone, and if you get a new phone, sign in again. That is the whole job. It may be years before anyone needs you, and that is good news.",
                    figure: .keep),
            ]
        case .recipient:
            return [
                OnboardingScreen(
                    id: "r.sealed",
                    title: "Someone wrote you an envelope.",
                    body: "It is sealed. Nobody can open it early on your phone. Not Apple, not us, and not anyone holding a key. It opens here, and only after the person who wrote it is gone.",
                    figure: .envelope),
                OnboardingScreen(
                    id: "r.opens",
                    title: "How it opens.",
                    body: "The person who wrote it opens Seal now and then. If they go quiet for \(n.silenceDays) days, their key holders may start a claim. They are warned for \(n.warningDays) days, then \(n.graceDays) quiet days pass, and if they are alive one tap stops it. After all of that, \(n.anyMofN) taps, and the envelope opens here.",
                    figure: .timeline(.keysCanTap)),
                OnboardingScreen(
                    id: "r.job",
                    title: "Your job is simple.",
                    body: "Keep Seal on your phone. If you get a new phone, sign in on it. You do not need a key, and you do not need to do anything else. When the time comes, the envelope opens on its own, and this app tells you. Until then, nobody, not even the key holders, can see what is inside.",
                    figure: .keep),
            ]
        }
    }
}

// MARK: - The view

struct SealOnboardingView: View {
    var numbers: OnboardingNumbers = .defaults
    var initialRole: OnboardingRole? = nil
    var onDone: () -> Void

    @State private var role: OnboardingRole?
    @State private var index: Int
    @AppStorage("seal.onboardingRole") private var storedRole = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(numbers: OnboardingNumbers = .defaults,
         initialRole: OnboardingRole? = nil,
         onDone: @escaping () -> Void) {
        self.numbers = numbers
        self.initialRole = initialRole
        self.onDone = onDone
        _role = State(initialValue: initialRole)
        _index = State(initialValue: initialRole == nil ? 0 : OnboardingScript.sharedCount)
    }

    private var screens: [OnboardingScreen] {
        OnboardingScript.shared() + (role.map { OnboardingScript.screens(for: $0, numbers: numbers) } ?? [])
    }

    private var screen: OnboardingScreen {
        screens[min(max(0, index), screens.count - 1)]
    }

    private var isAsk: Bool {
        if case .ask = screen.figure { return true }
        return false
    }

    private var isLast: Bool { role != nil && index == screens.count - 1 }

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar

                // The ZStack lets the outgoing and incoming screens overlap
                // during the transition instead of pushing each other.
                ZStack {
                ScrollView {
                    VStack(spacing: 22) {
                        figureView(screen.figure)
                            .padding(.top, 8)

                        Text(screen.title)
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(screen.body)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        if !screen.steps.isEmpty {
                            stepsList(screen.steps)
                        }

                        if isAsk {
                            roleButtons
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
                .id(screen.id)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity))
                }

                progressDots
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            Menu {
                Section("Start") {
                    ForEach(Array(OnboardingScript.shared().enumerated()), id: \.element.id) { i, s in
                        Button(s.title) { go(role: role, index: i) }
                    }
                }
                ForEach(OnboardingRole.allCases) { r in
                    Section(r.menuTitle) {
                        ForEach(Array(OnboardingScript.screens(for: r, numbers: numbers).enumerated()), id: \.element.id) { i, s in
                            Button(s.title) { go(role: r, index: OnboardingScript.sharedCount + i) }
                        }
                    }
                }
            } label: {
                Label("Chapters", systemImage: "list.bullet")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding()
            }
            .accessibilityLabel("Chapters. Jump to any part.")

            Spacer()

            Button("Skip") { onDone() }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .padding()
        }
    }

    @ViewBuilder
    private func figureView(_ figure: OnboardingScreen.Figure) -> some View {
        switch figure {
        case .mark:
            SealMark(size: 120, trust: true, pressOnAppear: true)
                .padding(.vertical, 12)
        case .ask:
            SealMark(size: 64, trust: false, pressOnAppear: false)
                .padding(.vertical, 4)
        case .envelope:
            SealedEnvelopeFigure()
        case .timeline(let outcome):
            ReleaseTimelineFigure(numbers: numbers, outcome: outcome)
        case .keys:
            KeysTurningFigure(numbers: numbers)
        case .curve:
            ShamirCurveFigure(numbers: numbers)
        case .keep:
            KeyKeepFigure()
        case .steps:
            SealMark(size: 72, trust: false, pressOnAppear: true)
                .padding(.vertical, 4)
        }
    }

    private func stepsList(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(i + 1)")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(SealTheme.ink)
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.85), in: Circle())
                    Text(step)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var roleButtons: some View {
        VStack(spacing: 12) {
            roleButton(.sealer,
                       title: "I am setting this up for myself",
                       sub: "I want to write envelopes and hide passwords.")
            roleButton(.keyHolder,
                       title: "Someone handed me a key",
                       sub: "They asked me to hold a small security key.")
            roleButton(.recipient,
                       title: "Someone wrote me an envelope",
                       sub: "I was told an envelope is waiting for me.")
        }
        .padding(.top, 4)
    }

    private func roleButton(_ r: OnboardingRole, title: String, sub: String) -> some View {
        Button {
            storedRole = r.rawValue
            go(role: r, index: OnboardingScript.sharedCount)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(sub)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .parentTapTarget()
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(screens.enumerated()), id: \.element.id) { i, _ in
                Circle()
                    .fill(Color.white.opacity(i == index ? 0.9 : 0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 10)
        .accessibilityLabel("Screen \(index + 1) of \(screens.count)")
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if index > 0 {
                Button("Back") { go(role: role, index: index - 1) }
                    .buttonStyle(SealSecondaryButtonStyle())
                    .frame(maxWidth: 140)
            }
            if !isAsk {
                Button {
                    if isLast { onDone() } else { go(role: role, index: index + 1) }
                } label: {
                    Text(isLast ? (role?.doneLabel ?? "Done") : "Next")
                }
                .buttonStyle(SealPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private func go(role newRole: OnboardingRole?, index newIndex: Int) {
        let change = {
            role = newRole
            let count = OnboardingScript.sharedCount
                + (newRole.map { OnboardingScript.screens(for: $0, numbers: numbers).count } ?? 0)
            index = min(max(0, newIndex), count - 1)
        }
        if reduceMotion { change() } else { withAnimation(.easeInOut(duration: 0.3), change) }
    }
}

// MARK: - The old name

/// Kept so RegistrationView and ProfileView compile unchanged. On first
/// launch nobody has said who they are yet, so it starts at the front.
struct WelcomeCarousel: View {
    var onDone: () -> Void

    var body: some View {
        SealOnboardingView(onDone: onDone)
    }
}

#Preview("Onboarding") {
    SealOnboardingView(onDone: {})
}

#Preview("Key holder, real numbers") {
    SealOnboardingView(
        numbers: OnboardingNumbers(silenceDays: 90, warningDays: 21, graceDays: 14,
                                   threshold: 2, custodianCount: 3, exact: true),
        initialRole: .keyHolder,
        onDone: {})
}
