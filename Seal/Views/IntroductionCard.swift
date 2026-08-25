import SwiftUI

//  IntroductionCard.swift
//  Seal
//
//  The inbound introduction, as a card in the chat with whoever made it.
//
//  Everything this view renders is already decided: `ChatEngine` ran every
//  cryptographic check when the message landed and stored the verdict on the
//  message, and the flow's state lives in `IntroductionStore`. The card is a
//  pure function of the two — no async work, no "checking…" that never
//  resolves because a body ran at the wrong moment.
//
//  COLOUR RULE. Nothing here is brass. Brass means a key was physically
//  tapped in front of somebody (UI.md §1), and the entire point of an
//  introduction is that it wasn't. Silver + the `link` glyph, everywhere,
//  including the fingerprint phrase — which is brass on every other surface in
//  the app precisely because those surfaces are about people you met.

struct IntroductionBubble: View {
    let message: ChatEngine.ChatMessage
    let offer: IntroductionOffer
    let chat: ChatEngine.Chat
    let myRoot: RootIdentity
    @Bindable var engine: ChatEngine
    var friendStore: FriendStore?

    @Environment(\.parentMode) private var parentMode
    @State private var busy = false
    @State private var failure: String?
    @State private var resent = false
    @State private var showPhrase = false

    private var statement: IntroductionStatement { offer.statement }
    private var myHash: String { myRoot.credentialIDHash }
    private var iAmIntroducer: Bool { statement.introducerHash == myHash }
    private var entry: IntroductionStore.Entry? {
        engine.introductions.entry(statement.commitmentHex)
    }
    private var counterpartHash: String? { statement.counterpartHash(for: myHash) }

    private func name(_ hash: String?) -> String {
        guard let hash else { return "someone" }
        if hash == myHash { return myRoot.displayName }
        if let friend = friendStore?.friends.first(where: { $0.id == hash }) {
            return friend.identity.displayName
        }
        if hash == offer.counterpart?.credentialIDHash,
           let counterpart = offer.counterpart { return counterpart.displayName }
        return engine.cachedIdentity(for: hash)?.displayName ?? "someone"
    }

    private var counterpartName: String { name(counterpartHash) }
    private var introducerName: String { name(statement.introducerHash) }

    /// Check (b) as the card sees it. The engine runs the same check again
    /// inside `acceptIntroduction` — this one only decides what to draw.
    private var eligibilityReason: String? {
        guard let friendStore else { return nil }
        return Introduction.introducerEligibility(statement, friendStore: friendStore)
    }

    private enum Stage: Equatable {
        case refused(String)        // a check failed — dead end, plain language
        case checking(String)       // a check couldn't run yet — retried automatically
        case notEligible(String)    // introduction doesn't chain (or we never met them)
        case pending                // Accept / Not now
        case accepted               // we said yes, the other side hasn't
        case linked                 // both said yes, friendship exists
        case dismissed              // we said "not now" — nobody was told
        case stopped(String)        // the engine gave up — say so, don't pretend
        case sentWaiting            // we are the introducer, not both answered
        case sentLinked             // we are the introducer, both answered
    }

    /// TERMINAL STATES FIRST. A friendship that already exists is a fact, and
    /// nothing that happens later — the introducer being un-forged, a re-check
    /// going stale — may turn its card back into an orange "this can't be
    /// accepted" sitting under a friend who is right there in the list.
    private var stage: Stage {
        if iAmIntroducer {
            // `abandonedAt` before `bothAccepted`: an introduction the engine
            // gave up on still has both acceptances, and reading "they're
            // linked now" when no confirmation was ever delivered is the one
            // wrong thing this card could say.
            if let entry, entry.abandonedAt != nil {
                return .stopped("Seal stopped this introduction — one of them isn't in your Circle any more. Forge with them again and you can introduce them again.")
            }
            return entry?.bothAccepted == true ? .sentLinked : .sentWaiting
        }
        if let entry, entry.completedAt != nil { return .linked }
        if let entry, entry.declinedAt != nil { return .dismissed }
        if let entry, entry.abandonedAt != nil {
            return .stopped("Seal couldn't finish this introduction, so nothing was added. Ask \(introducerName) to make it again.")
        }
        if let refusal = offer.refusal { return .refused(refusal) }
        if let unchecked = offer.unchecked { return .checking(unchecked) }
        if let reason = eligibilityReason { return .notEligible(reason) }
        if entry?.myAcceptance(myHash) != nil { return .accepted }
        return .pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            // Introductions are NOT exempt from disappearing messages
            // (docs/INTRODUCTIONS.md §5), so say so on the card rather than
            // letting an unanswered offer vanish unexplained. The flow itself
            // survives: the state is in the store, and the introducer's card
            // offers "Send again".
            if message.expiresAt != nil, stage == .pending || stage == .accepted {
                Label("This card disappears with the rest of this chat. The introduction itself doesn't — they can send it again.",
                      systemImage: "hourglass")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, lineWidth: 1))
        .sheet(isPresented: $showPhrase) {
            IntroductionPhraseSheet(
                counterpartName: counterpartName,
                counterpartPublicKey: counterpartHash.flatMap { statement.publicKey(for: $0) } ?? Data(),
                introducerName: introducerName,
                alreadyLinked: stage == .linked)
                .presentationDetents([.medium, .large])
        }
    }

    private var borderColor: Color {
        switch stage {
        case .refused, .notEligible, .stopped: .orange.opacity(0.5)
        default: SealTheme.silver.opacity(0.35)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: headerGlyph)
                .font(.system(size: 12, weight: .semibold))
            Text(headerText)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .tracking(0.6)
            Spacer()
        }
        .foregroundStyle(headerTint)
    }

    private var headerGlyph: String {
        switch stage {
        case .refused, .notEligible, .stopped: "exclamationmark.triangle.fill"
        case .checking: "clock"
        default: "link"
        }
    }

    private var headerTint: Color {
        switch stage {
        case .refused, .notEligible, .stopped: .orange.opacity(0.9)
        case .checking: .white.opacity(0.5)
        default: SealTheme.silver
        }
    }

    private var headerText: String {
        switch stage {
        case .refused: "INTRODUCTION REFUSED"
        case .stopped: "INTRODUCTION STOPPED"
        case .notEligible: "INTRODUCTION"
        case .checking: "INTRODUCTION"
        case .linked, .sentLinked: "LINKED"
        default: "INTRODUCTION"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .refused(let reason), .notEligible(let reason), .stopped(let reason):
            // Plain language and no actions. A refusal that offered a button
            // would be inviting somebody to try again at the thing that just
            // failed a signature check.
            Text(reason)
                .font(parentMode ? .body : .callout)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

        case .checking(let reason):
            HStack(spacing: 8) {
                ProgressView().tint(SealTheme.silver)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .pending:
            title("\(introducerName) wants to introduce you to \(counterpartName).")
            vouchLine
            HStack(spacing: 10) {
                Button {
                    accept()
                } label: {
                    Text("Accept")
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(SealTheme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, parentMode ? 10 : 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(SealTheme.silver)
                .disabled(busy)
                .parentTapTarget()

                Button {
                    engine.declineIntroduction(offer)
                } label: {
                    Text("Not now")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, parentMode ? 10 : 6)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.2))
                .disabled(busy)
                .parentTapTarget()
            }

        case .accepted:
            // NOT "waiting for <them>". Verified on device 8/25: both parties
            // had already accepted and both cards still said they were waiting
            // for the other, because a party only learns of the other's
            // acceptance when the INTRODUCER relays it. The card was blaming
            // the wrong person for a delay that belonged to a third phone.
            title("You accepted.")
            Text("You'll be linked once \(counterpartName) accepts too and \(introducerName)'s phone is next online — it's the only one that can pass their answer along. \(introducerName) only ever sees whether it's been accepted, never who has answered.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            phraseButton("Check \(counterpartName)'s phrase")

        case .linked:
            title(parentMode
                  ? "\(counterpartName) is in your chats now."
                  : "You and \(counterpartName) are linked.")
            Text("Introduced by \(introducerName) · \(statement.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(SealTheme.silver.opacity(0.9))
            vouchLine
            phraseButton("Say the phrase out loud")

        case .dismissed:
            Text("Introduction dismissed. Nobody was told.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

        case .sentWaiting:
            title("You introduced \(name(statement.partyAHash)) and \(name(statement.partyBHash)).")
            Text("Not accepted yet. Seal doesn't say which of them has answered.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                resend()
            } label: {
                Label(resent ? "Sent again" : "Send again",
                      systemImage: resent ? "checkmark" : "arrow.clockwise")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(SealTheme.silver)
            }
            .disabled(busy)
            .parentTapTarget()

        case .sentLinked:
            title("\(name(statement.partyAHash)) and \(name(statement.partyBHash)) are linked.")
            Text("They both accepted. Their friendship shows that you vouched for it, and that they haven't met in person.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(parentMode ? .title3 : .callout, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// THE honest sentence. It is the same claim in both modes, and it never
    /// says "verified": a linked friendship is exactly as trustworthy as the
    /// introducer's judgment, and the copy says so in those words.
    private var vouchLine: some View {
        Text(parentMode
             ? "\(introducerName) has met \(counterpartName) in person. You haven't."
             : "You haven't met \(counterpartName) in person through Seal. \(introducerName) has, and vouched for this connection.")
            .font(parentMode ? .callout : .caption)
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func phraseButton(_ label: String) -> some View {
        Button { showPhrase = true } label: {
            Label(label, systemImage: "waveform")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(SealTheme.silver)
        }
        .parentTapTarget()
    }

    private func accept() {
        guard let friendStore else {
            failure = "Seal couldn't reach your friend list. Reopen the chat and try again."
            return
        }
        busy = true
        failure = nil
        Task {
            let result = await engine.acceptIntroduction(offer, in: chat, from: myRoot,
                                                         friendStore: friendStore)
            busy = false
            failure = result
            // The fingerprint step is UI encouragement, not a protocol step —
            // but it is the only check that catches an introducer who vouched
            // for an impostor, so it opens by itself rather than waiting to be
            // found (docs/INTRODUCTIONS.md §Threats).
            if result == nil { showPhrase = true }
        }
    }

    private func resend() {
        guard let friendStore else { return }
        busy = true
        failure = nil
        Task {
            failure = await engine.resendIntroduction(statement, from: myRoot,
                                                      friendStore: friendStore)
            if failure == nil { resent = true }
            busy = false
        }
    }
}

// MARK: - Fingerprint step

/// Shown right after accepting, and reachable afterwards from the card.
///
/// This is the human layer, and on a linked friendship it is doing more work
/// than usual: every cryptographic check has passed, and all of them together
/// still only prove that the introducer vouched. Hearing the same phrase in
/// somebody's own voice is what turns "Mom says this is Linda" into "that is
/// Linda". The app can't do it, so it asks.
struct IntroductionPhraseSheet: View {
    let counterpartName: String
    let counterpartPublicKey: Data
    let introducerName: String
    var alreadyLinked: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(SealTheme.silver)
                        .padding(.top, 28)
                    Text(alreadyLinked
                         ? "Linked with \(counterpartName)"
                         : "Accepted — waiting for \(counterpartName)")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(FingerprintPhrase.phrase(for: counterpartPublicKey))
                        .font(.title2)
                        .foregroundStyle(SealTheme.silver)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Call \(counterpartName) — a phone or video call, not a text — and say this out loud. If their phone shows the same phrase for you, you have the right person.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)

                    Text("\(introducerName) vouched for this connection. Seal checked their signature, not their judgment — this call is the part only you can do.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)

                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(SealTheme.ink)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SealTheme.silver)
                    .parentTapTarget()
                    .padding(.top, 6)
                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .preferredColorScheme(.dark)
    }
}
