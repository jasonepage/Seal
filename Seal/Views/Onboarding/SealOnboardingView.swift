// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  SealOnboardingView.swift
//  Seal
//
//  THE FIRST MINUTE. Two shared screens, then a fork by who is holding the
//  phone:
//
//    just me        one person writing envelopes for their family   eleven
//    my partner     a couple, two phones, a key for each other       twelve
//    the key holder was handed a key and does nothing for years     four
//    the recipient  was written an envelope                          three
//
//  Every screen has one figure and teaches one thing the previous screen
//  did not. The figures live in OnboardingFigures.swift and run once each.
//  The two sealer paths are one script (sealerScreens) with a prefix on
//  the ids, so the copy is written once; the couple path swaps in two
//  screens of its own and its own checklist.
//
//  Three ways in:
//    1. First launch, before registration (RegistrationView), as
//       WelcomeCarousel, which is a thin wrapper around this view.
//    2. You, then Help, then "How Seal works" (ProfileView), same wrapper.
//    3. "See how it opens" and "Watch it happen" on the home screen and
//       the key holder cards, which pass that estate's real numbers and
//       start on that path.
//
//  It is skippable at every screen and re-openable, and the Chapters menu
//  at the top jumps straight to any screen of any path.
//
//  This view touches no engine, no clock, no network and no keychain. It
//  is a drawing. The one exception is reading SealPurchase.displayPrice
//  from the environment for the price line, and the sentence reads right
//  when the price has not loaded. The DEBUG Time Travel screen is not a
//  substitute for it: that one moves the real clock.
//
//  House rules kept here: no em dashes, plain words, never the word
//  "will", "key holder" in every string a person reads, brass only on the
//  trust moment (the finished mark, the owner's tap, the keys that open,
//  the handover). Nothing here promises the owner is dead: Seal knows
//  they went quiet, and the copy says so. OnboardingCopyTests checks the
//  script at thresholds of 1, 2 and 3 and at 1, 2 and 3 key holders.

// MARK: - Roles and screens

enum OnboardingRole: String, CaseIterable, Identifiable {
    case sealer
    case couple
    case keyHolder
    case recipient

    var id: String { rawValue }

    /// The chapter heading in the menu.
    var menuTitle: String {
        switch self {
        case .sealer: "Just me"
        case .couple: "Me and my partner"
        case .keyHolder: "I was handed a key"
        case .recipient: "Someone wrote me an envelope"
        }
    }

    /// The big line on the "Which one are you?" button.
    var chooserTitle: String {
        switch self {
        case .sealer: "Just me"
        case .couple: "Me and my partner"
        case .keyHolder: "I was handed a key"
        case .recipient: "Someone wrote me an envelope"
        }
    }

    /// The small line under it.
    var chooserSub: String {
        switch self {
        case .sealer: "I am setting this up for my family."
        case .couple: "Two phones. Each of us holds a key for the other."
        case .keyHolder: "Someone asked me to hold a small security key."
        case .recipient: "I was told an envelope is waiting for me."
        }
    }

    /// The last button on the path.
    var doneLabel: String {
        switch self {
        case .sealer, .couple: "Get started"
        case .keyHolder, .recipient: "Got it"
        }
    }

    /// The two paths that write envelopes.
    var isSealer: Bool { self == .sealer || self == .couple }
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
        case phones
        case spare
        /// The small pewter mark, for a screen whose point is a sentence
        /// and not a drawing (the price, the envelopes that wait).
        case quiet

        var isSteps: Bool { if case .steps = self { return true }; return false }
        var isKeep: Bool { if case .keep = self { return true }; return false }

        /// What the drawing shows, in words, for VoiceOver.
        func accessibilityLabel(_ n: OnboardingNumbers) -> String {
            switch self {
            case .mark, .ask, .steps, .quiet:
                return "The Seal mark: a wax seal with an envelope pressed into it."
            case .envelope:
                return "A closed envelope with a wax seal on the flap."
            case .timeline(let outcome):
                let track = "A countdown along a track: \(OnboardingScript.days(n.silenceDays)) of quiet, \(OnboardingScript.days(n.warningDays)) of warnings, then \(n.graceDays == 0 ? "no extra quiet days" : OnboardingScript.days(n.graceDays) + " more of quiet")."
                switch outcome {
                case .silenceOnly:
                    return track + " It stops at day \(n.silenceDays), when a key holder may start a claim."
                case .ownerStops:
                    return track + " Partway through the warnings the owner taps once, and the count goes back to zero."
                case .keysCanTap:
                    return track + " At day \(n.totalDays) the keys can be tapped."
                }
            case .keys:
                let turn = n.threshold == 1 ? "One turns" : "\(OnboardingScript.word(n.threshold, capital: true)) turn"
                return "\(n.custodianCount == 1 ? "One key" : "\(OnboardingScript.word(n.custodianCount, capital: true)) keys") in a row. \(turn), and the envelope below opens on the last one."
            case .curve:
                if n.threshold == 1 {
                    return "A flat line with one point on it. One point fixes it, because the rule needs only one key holder. The secret is where the line meets the left edge."
                }
                let shape = n.threshold <= 2 ? "line" : "curve"
                return "A hidden \(shape) with one point per key holder. With fewer than \(OnboardingScript.word(n.threshold)) points it could be any \(shape). With \(OnboardingScript.word(n.threshold)) points it is one \(shape), and the secret is where it meets the left edge."
            case .keep:
                return "A key lying still in a drawer, with the years going by."
            case .phones:
                return "Two phones side by side, each with its own envelope. A key crosses from each phone to the other."
            case .spare:
                return "Two keys in a drawer: the one you use in front, and a spare put away behind it."
            }
        }
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

    // MARK: Small words

    /// "1 day" or "21 days". Never "1 days".
    static func days(_ n: Int) -> String {
        n == 1 ? "1 day" : "\(n) days"
    }

    /// Small counts as words, so a sentence reads the way it is said.
    static func word(_ n: Int, capital: Bool = false) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let w = (0..<words.count).contains(n) ? words[n] : "\(n)"
        return capital ? w.prefix(1).uppercased() + String(w.dropFirst()) : w
    }

    /// The one sentence about money. The price comes from the store and
    /// nowhere else. Reads right before the store has answered.
    static func priceSentence(_ price: String?) -> String {
        if let price, !price.isEmpty {
            return "Seal is one purchase, once, for life: \(price)."
        }
        return "Seal is one purchase, once, for life. The price is shown before you pay."
    }

    // MARK: Shared

    static func shared() -> [OnboardingScreen] {
        [
            OnboardingScreen(
                id: "why",
                title: "For the things only you know.",
                body: "The passwords. The seed phrase. Where the papers are. A letter to each of them. You seal them in envelopes now, for the people you leave behind. They stay closed while you are here. Nobody can open one early. Not Apple, not us.",
                figure: .mark),
            OnboardingScreen(
                id: "ask",
                title: "Which one are you?",
                body: "Seal looks different for each of these. Pick the one that fits, and we show you only what you need.",
                figure: .ask),
        ]
    }

    static func screens(for role: OnboardingRole, numbers n: OnboardingNumbers, price: String? = nil) -> [OnboardingScreen] {
        switch role {
        case .sealer: return sealerScreens(prefix: "s", couple: false, n: n, price: price)
        case .couple: return sealerScreens(prefix: "c", couple: true, n: n, price: price)
        case .keyHolder: return keyHolderScreens(n)
        case .recipient: return recipientScreens(n)
        }
    }

    // MARK: The two sealer paths

    /// ", then waits 14 days more, quietly" or nothing at a grace of 0.
    private static func graceClause(_ n: OnboardingNumbers) -> String {
        n.graceDays == 0 ? "" : ", then waits \(days(n.graceDays)) more, quietly"
    }

    private static func sealerScreens(prefix p: String, couple: Bool, n: OnboardingNumbers, price: String?) -> [OnboardingScreen] {
        var out: [OnboardingScreen] = []

        out.append(OnboardingScreen(
            id: "\(p).envelope",
            title: "One envelope for each person.",
            body: "An envelope holds a letter, a few photos, a voice message, a short video, and the secrets: passwords, where the papers are, the combination. It also holds \"what to do first\": the steps to take, in order. You write one for each person. Only that person can ever read it. If you type a seed phrase into the letter, Seal notices and offers to move it somewhere safer.",
            figure: .envelope))

        if couple {
            out.append(OnboardingScreen(
                id: "\(p).two",
                title: "Two phones. Each of you holds a key for the other.",
                body: "Each of you sets up Seal on your own phone. Each of you writes your own envelopes. Each of you hands the other a security key. After you sign up, tap \"Set up with my partner\" and Seal walks you both through it, one step at a time, on both phones.",
                figure: .phones))
        }

        out.append(OnboardingScreen(
            id: "\(p).checkin",
            title: "Opening the app is your check-in.",
            body: "Each time you open Seal, your phone quietly notes that you are here. Nobody else sees a thing. Say \"Check in with Seal\" to Siri, or tap the Seal widget, and it is one tap. If you go quiet for \(days(n.silenceDays)), one of your key holders can start a claim. Not before.",
            figure: .timeline(.silenceOnly)))

        out.append(OnboardingScreen(
            id: "\(p).warnings",
            title: "\(days(n.warningDays)) of warnings, and one tap stops everything.",
            body: "Once a claim starts, Seal warns you every day for \(days(n.warningDays))\(graceClause(n)). At any moment, one tap from you stops it. You do not need your key for that. A long stay in the hospital looks like silence from the outside. The warnings are there for exactly that.",
            figure: .timeline(.ownerStops)))

        if couple {
            out.append(OnboardingScreen(
                id: "\(p).keys",
                title: "One more key holder each.",
                body: "If it is only the two of you, your partner's one key opens everything after the silence. And if something happens to you both at once, nobody is left to act. So each of you also hands a key to one more person you trust, someone who is still there if something happens to you both. Seal recommends it and never forces it.",
                figure: .keys))
        } else {
            out.append(keysScreen(prefix: p, n))
        }

        out.append(curveScreen(prefix: p, n))

        out.append(OnboardingScreen(
            id: "\(p).holders",
            title: "Key holders are met in person.",
            body: "You meet each key holder face to face and hand them a small security key. A YubiKey is one kind. \(n.custodyConfirmLead) Seal asks them to tap it once, to confirm they still have it. A printed page goes in the drawer with the key, so anyone who finds it knows what it is for.",
            figure: .keep))

        out.append(OnboardingScreen(
            id: "\(p).backup",
            title: "A backup key, for yourself.",
            body: "Right after you sign up, Seal asks you to add a backup key. Do it then. There is no email reset, on purpose: nobody can take your identity by resetting it, not even us. So if you lose your only key, your identity is gone with it. A second security key, or a passkey on a phone you trust, brings it back.",
            figure: .spare))

        out.append(OnboardingScreen(
            id: "\(p).urgent",
            title: "A second rule, for what cannot wait.",
            body: "Some things cannot wait, like the bills and the medical papers. Give those envelopes their own rule, with shorter numbers and its own key holders. Opening them opens none of the letters. Up to three rules, each its own set of keys.",
            figure: .envelope))

        out.append(OnboardingScreen(
            id: "\(p).waiting",
            title: "Envelopes that wait.",
            body: "You can write to someone who is not on Seal yet. Type their name tonight, and the envelope waits until you meet. For someone far away, you can register a spare security key in their name and send it to them. An envelope can also be held for a date, like a birthday: the reader's phone waits until that day to show it. And if you ever delete your account, Seal asks whether to keep your envelopes for your family or cancel them.",
            figure: .quiet))

        out.append(OnboardingScreen(
            id: "\(p).price",
            title: "What it costs.",
            body: "\(priceSentence(price)) Nothing is charged until the first time you tap Seal. Writing envelopes and adding people are free. Security keys are bought separately; a YubiKey is one kind. Face ID works for everything, so a key is recommended, never required. The other choices are a sticky note in a drawer, or passwords written into legal papers that anyone can read once a court makes them public.",
            figure: .quiet))

        if couple {
            out.append(OnboardingScreen(
                id: "\(p).now",
                title: "What you do tonight, on both phones.",
                body: "One evening, both phones out. Each step below happens on each phone.",
                figure: .steps,
                steps: [
                    "On each phone: set up Seal, and add a backup key when it asks.",
                    "Phones side by side: add each other under People.",
                    "On each phone: tap \"Set up with my partner\" and follow the list.",
                    "On each phone: make your partner a key holder and hand over a key. Then one more key holder each.",
                    "On each phone: write your envelopes, then tap Seal. That is when each of you pays, once.",
                ]))
        } else {
            let hand: String
            switch n.custodianCount {
            case 1: hand = "Hand a key to the person you trust most, and set your rule."
            default: hand = "Hand a key to \(word(n.custodianCount)) people you trust, and set your rule."
            }
            out.append(OnboardingScreen(
                id: "\(p).now",
                title: "What you do tonight.",
                body: "It takes an evening. After that, opening the app now and then is the whole job.",
                figure: .steps,
                steps: [
                    "Set up Seal with Face ID or a security key. Add a backup key when it asks.",
                    "Meet each person face to face and add them under People.",
                    "Write an envelope for each of them.",
                    hand,
                    "Tap Seal. That is when you pay, once.",
                ]))
        }
        return out
    }

    /// Who opens what. Four shapes of rule, each read aloud at the
    /// numbers it is shown with. Never "any 1 of 1", never "any 2 of 2".
    private static func keysScreen(prefix p: String, _ n: OnboardingNumbers) -> OnboardingScreen {
        let opens = "Then, and only then, the envelopes open on the phones of the people you wrote them for."
        if n.oneIsEnough && n.custodianCount == 1 {
            return OnboardingScreen(
                id: "\(p).keys",
                title: "Your one key holder opens the envelopes.",
                body: "You choose one person you trust and meet them in person. After all the warnings pass, that person taps their key. \(opens) Your rule needs only one person, so that person can act alone. You can change that on the rule screen.",
                figure: .keys)
        }
        if n.oneIsEnough {
            return OnboardingScreen(
                id: "\(p).keys",
                title: "Any one of your \(word(n.custodianCount)) keys opens the envelopes.",
                body: "You choose \(word(n.custodianCount)) people you trust, in person. After all the warnings pass, any one of them taps their key. \(opens) Your rule needs only one person right now, so any one of them can act alone. You can change that on the rule screen.",
                figure: .keys)
        }
        if n.threshold == n.custodianCount {
            return OnboardingScreen(
                id: "\(p).keys",
                title: "All \(word(n.custodianCount)) of your keys together open the envelopes.",
                body: "You choose \(word(n.custodianCount)) people you trust, in person. After all the warnings pass, all of them tap. Their phones combine the pieces. \(opens)",
                figure: .keys)
        }
        return OnboardingScreen(
            id: "\(p).keys",
            title: "Any \(word(n.threshold)) of your \(word(n.custodianCount)) keys open the envelopes.",
            body: "You choose \(word(n.custodianCount)) people you trust, in person. After all the warnings pass, any \(word(n.threshold)) of them tap. Their phones combine the pieces. \(opens)",
            figure: .keys)
    }

    /// The arithmetic. At a threshold of 1 the usual title is false, so
    /// the screen says what the rule is and what the picture shows for a
    /// rule of two or more.
    private static func curveScreen(prefix p: String, _ n: OnboardingNumbers) -> OnboardingScreen {
        if n.oneIsEnough {
            return OnboardingScreen(
                id: "\(p).curve",
                title: "With two keys or more, one key alone sees nothing.",
                body: "Your rule right now needs only one key, so one key holder can act alone after the warnings. If you ask for two keys or more, each key holds one point on a hidden line. One point alone could sit on any line at all, so one key holder learns nothing. Two points fix the line, and where it meets the edge is the secret. That is arithmetic, and it holds against us too.",
                figure: .curve)
        }
        let shape = n.threshold <= 2 ? "line" : "curve"
        return OnboardingScreen(
            id: "\(p).curve",
            title: "One key alone sees nothing.",
            body: "Each key holds one point on a hidden \(shape). One point alone could sit on any \(shape) at all, so one key holder learns nothing, not even a hint. \(word(n.threshold, capital: true)) points fix the \(shape), and where it meets the edge is the secret that opens everything. This is not a rule we made up. It is arithmetic, and it holds against us too.",
            figure: .curve)
    }

    // MARK: The key holder

    private static func keyHolderScreens(_ n: OnboardingNumbers) -> [OnboardingScreen] {
        let others = n.others
        let otherPeople = others == 1 ? "one other person" : "\(word(others)) other people"

        let nothing: OnboardingScreen
        if n.oneIsEnough {
            nothing = OnboardingScreen(
                id: "k.nothing",
                title: "Nothing opens until the countdown ends.",
                body: "Until the person who asked you has gone quiet for a long time and every warning has run, nothing opens for anybody, including you. One tap from them stops it at any point. After all of that, their rule lets you act on your own.",
                figure: .curve)
        } else {
            nothing = OnboardingScreen(
                id: "k.nothing",
                title: "You cannot open anything. Nobody can.",
                body: "Your key holds one piece of a puzzle. One piece alone is no clue at all, not even a hint. That is arithmetic, not a promise. It is why the person who trusted you could ask you without a second thought.",
                figure: .curve)
        }

        // At a threshold of 1 this screen must not say "your key alone
        // does nothing". It does everything.
        let several: OnboardingScreen
        if n.oneIsEnough && n.custodianCount == 1 {
            several = OnboardingScreen(
                id: "k.several",
                title: "You are the only one.",
                body: "The rule they chose needs only one person, and that person is you. Once they have gone quiet and every warning has run, your tap alone opens the envelopes for the people they were written for. Nothing opens before that, and one tap from them stops all of it at any point.",
                figure: .keys)
        } else if n.oneIsEnough {
            several = OnboardingScreen(
                id: "k.several",
                title: "Any one of you can act.",
                body: "They asked \(otherPeople) too. Their rule needs only one key, so once they have gone quiet and every warning has run, your tap alone opens the envelopes. So does any other key holder's. Nothing opens before that, and one tap from them stops all of it.",
                figure: .keys)
        } else if n.exact {
            let together: String
            if n.threshold == n.custodianCount {
                together = n.custodianCount == 2 ? "both of you" : "all \(word(n.custodianCount)) of you"
            } else {
                together = "\(word(n.threshold)) of the \(word(n.custodianCount))"
            }
            several = OnboardingScreen(
                id: "k.several",
                title: "You are one of \(word(n.custodianCount)).",
                body: "They asked \(otherPeople) too. It takes \(together), acting together, to open anything. Your key alone does nothing, and that is the point.",
                figure: .keys)
        } else {
            several = OnboardingScreen(
                id: "k.several",
                title: "You are one of several.",
                body: "They asked a few other people too. It takes more than one key to open anything, \(n.anyMofN). Your key alone does nothing, and that is the point.",
                figure: .keys)
        }

        let told = others == 0 ? "" : ", and the other key holders are told"
        let pass = n.graceDays == 0 ? "" : ", then \(days(n.graceDays)) of quiet \(n.graceDays == 1 ? "passes" : "pass")"
        let quiet = OnboardingScreen(
            id: "k.quiet",
            title: "What happens if they go quiet.",
            body: "If they stop opening Seal for \(days(n.silenceDays)), you may start a claim\(told). They get a warning every day for \(days(n.warningDays))\(pass). If they are alive and open the app, it all stops. Only after all of that can keys be tapped.",
            figure: .timeline(.keysCanTap))

        let keep = OnboardingScreen(
            id: "k.keep",
            title: "Your job is to still be findable.",
            body: "Put the key somewhere you can find in ten years. A drawer you never clean out. A safe. With your passport. Keep the printed page with it. \(n.custodyConfirmLead) Seal asks you to tap the key once, to show you still have it. Keep Seal on your phone, and if you get a new phone, sign in again. That is the whole job.",
            figure: .keep)

        return [nothing, several, quiet, keep]
    }

    // MARK: The recipient

    private static func recipientScreens(_ n: OnboardingNumbers) -> [OnboardingScreen] {
        let taps = n.oneIsEnough ? "\(n.anyMofN) taps" : "\(n.anyMofN) key holders tap"
        let grace = n.graceDays == 0 ? "" : ", then \(days(n.graceDays)) of quiet \(n.graceDays == 1 ? "passes" : "pass")"
        return [
            OnboardingScreen(
                id: "r.sealed",
                title: "Someone wrote you an envelope.",
                body: "It is sealed. Nobody can open it early. Not Apple, not us, and not anyone holding a key. It opens here, on your phone, only after a long silence from the person who wrote it, and only after their key holders act.",
                figure: .envelope),
            OnboardingScreen(
                id: "r.opens",
                title: "How it opens.",
                body: "The person who wrote it opens Seal now and then. If they go quiet for \(days(n.silenceDays)), their key holders may start a claim. They are warned for \(days(n.warningDays))\(grace), and if they are alive one tap stops it. After all of that, \(taps), and the envelope opens here. If they held it for a date, like a birthday, your phone waits until that day to show it.",
                figure: .timeline(.keysCanTap)),
            OnboardingScreen(
                id: "r.job",
                title: "Your job is simple.",
                body: "Keep Seal on your phone. If you get a new phone, sign in on it. You do not need a key, and you do not need to do anything else. When the time comes, the envelope opens on its own, and this app tells you. Until then, nobody, not even the key holders, can see what is inside.",
                figure: .keep),
        ]
    }
}

// MARK: - The view

struct SealOnboardingView: View {
    var numbers: OnboardingNumbers = .defaults
    var initialRole: OnboardingRole? = nil
    var onDone: () -> Void

    @State private var role: OnboardingRole?
    @State private var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Optional on purpose: a preview, or a tree with no store above it,
    /// must draw the price screen with the "shown before you pay" line
    /// rather than crash. On the phone SealApp puts the store in the
    /// environment above ContentView, and every cover inherits it.
    @Environment(SealPurchase.self) private var purchase: SealPurchase?

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
        OnboardingScript.shared()
            + (role.map { OnboardingScript.screens(for: $0, numbers: numbers, price: purchase?.displayPrice) } ?? [])
    }

    private var screen: OnboardingScreen {
        screens[min(max(0, index), screens.count - 1)]
    }

    private var isAsk: Bool {
        if case .ask = screen.figure { return true }
        return false
    }

    private var isLast: Bool { role != nil && index == screens.count - 1 }

    /// iPad, or a phone on its side. Everything sits in one centred column
    /// instead of stretching across the screen.
    private var wide: Bool { horizontalSizeClass == .regular }

    /// The column the words, the figure and the buttons all share.
    private var columnWidth: CGFloat { wide ? 560 : 460 }

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar

                // The ZStack lets the outgoing and incoming screens overlap
                // during the transition instead of pushing each other.
                // On a wide screen (iPad, or a phone on its side) the
                // column is centred top to bottom as well, so the words do
                // not sit in the top corner above a thousand points of ink.
                GeometryReader { geo in
                ZStack {
                ScrollView {
                    VStack(spacing: wide ? 28 : 22) {
                        figureView(screen.figure)
                            .padding(.top, 8)
                            .scaleEffect(wide ? 1.25 : 1)
                            .padding(.vertical, wide ? 16 : 0)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(screen.figure.accessibilityLabel(numbers))

                        Text(screen.title)
                            .font(.system(wide ? .largeTitle : .title, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(screen.body)
                            .font(wide ? .body : .callout)
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
                    .frame(maxWidth: columnWidth)
                    .frame(maxWidth: .infinity)
                    // GOTCHAS "Layout": a vertical ScrollView does not
                    // constrain its content's width.
                    .containerRelativeFrame(.horizontal)
                    // Shorter content is centred in the space; taller
                    // content scrolls as before.
                    .frame(minHeight: geo.size.height, alignment: wide ? .center : .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .id(screen.id)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity))
                }
                }

                progressDots
                bottomBar
                    .frame(maxWidth: columnWidth)
                    .padding(.bottom, wide ? 24 : 0)
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
                        ForEach(Array(OnboardingScript.screens(for: r, numbers: numbers, price: purchase?.displayPrice).enumerated()), id: \.element.id) { i, s in
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
                .parentTapTarget()
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
        case .steps, .quiet:
            // Pewter. Paying is not a trust moment, and neither is a list.
            SealMark(size: 72, trust: false, pressOnAppear: true)
                .padding(.vertical, 4)
        case .phones:
            TwoPhonesFigure()
        case .spare:
            SpareKeyFigure()
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
            ForEach(OnboardingRole.allCases) { r in
                roleButton(r)
            }
        }
        .padding(.top, 4)
    }

    private func roleButton(_ r: OnboardingRole) -> some View {
        Button {
            go(role: r, index: OnboardingScript.sharedCount)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(r.chooserTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(r.chooserSub)
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
                    .parentTapTarget()
            }
            if !isAsk {
                Button {
                    if isLast { onDone() } else { go(role: role, index: index + 1) }
                } label: {
                    Text(isLast ? (role?.doneLabel ?? "Done") : "Next")
                }
                .buttonStyle(SealPrimaryButtonStyle())
                .parentTapTarget()
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

#Preview("Couple") {
    SealOnboardingView(initialRole: .couple, onDone: {})
}

#Preview("Key holder, real numbers") {
    SealOnboardingView(
        numbers: OnboardingNumbers(silenceDays: 90, warningDays: 21, graceDays: 14,
                                   threshold: 2, custodianCount: 3, exact: true),
        initialRole: .keyHolder,
        onDone: {})
}

#Preview("One key holder, threshold 1") {
    SealOnboardingView(
        numbers: OnboardingNumbers(silenceDays: 30, warningDays: 7, graceDays: 0,
                                   threshold: 1, custodianCount: 1, exact: true),
        initialRole: .sealer,
        onDone: {})
}
