import SwiftUI

/// The Sealed Card bubble (docs/CARDS.md) — deliberately unmistakable from
/// every other bubble in the chat: a bordered brass-edged card at full content
/// width, not a rounded glass capsule hugging one side. Alignment doesn't
/// identify the sender here; the verification line at the foot does, by name.
///
/// Nothing on this card is selectable. SwiftUI `Text` isn't selectable unless
/// `.textSelection(.enabled)` is applied, and it deliberately never is — the
/// only string a recipient can lift out of a card is `value`, through the one
/// checked Copy button.
struct SealedCardBubble: View {
    let message: ChatEngine.ChatMessage
    let card: SealedCard
    let mine: Bool
    let senderName: String
    let senderIdentity: RootIdentity?
    @Bindable var engine: ChatEngine

    @State private var showDetail = false

    /// Measured on the RENDERED string, not the raw one — chunking makes a
    /// crypto address about a quarter longer, and the line limit applies to
    /// what's actually drawn.
    private var isLongValue: Bool { card.displayValue.count > 320 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            valueBlock
            if let note = card.note, !note.isEmpty { noteBlock(note) }
            CardCopyButton(card: card)
            Divider().overlay(SealTheme.brass.opacity(0.2))
            verificationLine
        }
        .padding(14)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(SealTheme.brass.opacity(0.45), lineWidth: 1.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showDetail) {
            SealedCardDetailSheet(message: message, card: card, mine: mine,
                                  senderName: senderName, senderIdentity: senderIdentity,
                                  engine: engine)
                .presentationDetents([.large])
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            // The seal is the trust moment, so it's the one brass element and
            // the tap target for provenance. Not the mascot: UI.md §1.1 keeps
            // the seal character off security surfaces.
            Button { showDetail = true } label: {
                Image(systemName: "seal.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(SealTheme.brass)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sealed card details")

            VStack(alignment: .leading, spacing: 2) {
                Text(card.typeLine.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(SealTheme.brass.opacity(0.85))
                Text(card.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var valueBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardValueText(card: card, lineLimit: isLongValue ? 8 : nil)
            if isLongValue {
                Button { showDetail = true } label: {
                    Text("Show the full value")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(SealTheme.brass)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Rendered as visibly NOT part of what was sealed for verification. The
    /// note travels inside the same signed payload, so it IS authentic — it
    /// just isn't the string anyone should be pasting anywhere.
    private func noteBlock(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text("Note — not part of the value")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.35))
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var verificationLine: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 6) {
                Text(mine ? "You" : senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text("Sealed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SealTheme.brass)
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text(message.sentAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                // Cards are NOT exempt from disappearing messages, so they carry
                // the same hourglass every other expiring bubble does. Hiding it
                // here would be the quiet exception CardComposeSheet warns about.
                if message.expiresAt != nil {
                    Image(systemName: "hourglass")
                        .font(.system(size: 9))
                        .foregroundStyle(SealTheme.brass.opacity(0.7))
                }
                if mine {
                    Image(systemName: message.delivered ? "checkmark.seal" : "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Value rendering

/// The sealed value, monospaced. Crypto addresses are chunked in groups of four
/// for readability; the spaces are display only and never reach the pasteboard.
/// VoiceOver gets the raw string, spelled out character by character, because
/// hearing "bee cee one queue" run together is useless for checking an address.
struct CardValueText: View {
    let card: SealedCard
    var lineLimit: Int? = nil

    var body: some View {
        Text(card.displayValue)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(card.value)
            .speechSpellsOutCharacters(card.cardType == .cryptoAddress)
    }
}

// MARK: - Copy

/// The one way a value leaves a card.
///
/// Copies `value` byte for byte — never `displayValue`, which carries the
/// readability spaces — then re-reads the pasteboard and compares. A clipboard
/// manager or another app that rewrites the pasteboard between the write and
/// the read is caught here. One that rewrites it a second later is NOT, which
/// is why the confirmation shows the actual bytes that landed rather than a
/// green tick: the reader checks those ends against the card.
struct CardCopyButton: View {
    let card: SealedCard

    /// One alert, not two stacked modifiers. SwiftUI presents a single alert
    /// per view, and stacking `.alert(_:isPresented:)` lets the outer one
    /// shadow the inner — which here would be the tampering alarm, the one
    /// thing on this screen that must never fail to appear.
    private enum CopyAlert {
        case mismatch
        case unconfirmed

        var title: String {
            switch self {
            case .mismatch: return "The clipboard doesn't match"
            case .unconfirmed: return "Couldn't confirm the copy"
            }
        }

        var message: String {
            switch self {
            case .mismatch:
                return "Something on this device changed what was copied — a clipboard manager, or another app. Don't paste it. Open the card, compare by eye, and type it by hand or ask the sender to resend."
            case .unconfirmed:
                return "The value was copied, but this device didn't report back what's on the clipboard, so it couldn't be checked. Compare what you paste against the card before you use it."
            }
        }
    }

    @State private var confirmation: String?
    @State private var alert: CopyAlert?
    /// Changes on every copy so the auto-clear timer restarts even when the
    /// confirmation text is identical (it always is, for a given card).
    @State private var copyStamp = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: copy) {
                Label(card.cardType.copyLabel, systemImage: "doc.on.doc.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SealTheme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(SealTheme.brass, in: Capsule())
            }
            .buttonStyle(.plain)

            if let confirmation {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                    Text(confirmation)
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(SealTheme.brass)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(SealTheme.brass.opacity(0.12), in: Capsule())
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: confirmation)
        .task(id: copyStamp) {
            guard confirmation != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            // try? swallows CancellationError, so without this the toast is
            // cleared instantly whenever the task is torn down rather than
            // after the six seconds it's meant to stay up.
            guard !Task.isCancelled else { return }
            confirmation = nil
        }
        .alert(alert?.title ?? "", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )) {
            Button("OK", role: .cancel) { alert = nil }
        } message: {
            Text(alert?.message ?? "")
        }
    }

    private func copy() {
        let intended = card.value
        UIPasteboard.general.string = intended
        // Reading back a string this app wrote moments ago is a same-app read,
        // so it should not raise the system "Allow Paste?" prompt.
        // TODO: confirm on device — if a prompt ever appears here, the check
        // has to move behind an explicit "verify clipboard" affordance rather
        // than firing on every copy.
        let landed = UIPasteboard.general.string
        // A nil read is NOT evidence of tampering — the pasteboard can decline
        // to report its contents (privacy state, Universal Clipboard sync in
        // flight). Crying "something changed your clipboard" on that would be a
        // false alarm on an alert whose whole job is to be believed.
        guard let landed else {
            confirmation = nil
            alert = .unconfirmed
            return
        }
        guard landed == intended else {
            confirmation = nil
            alert = .mismatch
            return
        }
        confirmation = SealedCard.copyConfirmation(for: intended)
        copyStamp = UUID()
        SealTheme.sealHaptic()
    }
}

// MARK: - Detail

/// Tap the seal: who sealed this, with what key, and does it still check out.
///
/// The verification here is LIVE — `ChatEngine.verifyCard` re-runs the message
/// signature check against a force-refreshed directory entry every time this
/// sheet opens, rather than reporting the check the receive path ran once. That
/// is what catches a signing device revoked after the card landed.
struct SealedCardDetailSheet: View {
    let message: ChatEngine.ChatMessage
    let card: SealedCard
    let mine: Bool
    let senderName: String
    let senderIdentity: RootIdentity?
    @Bindable var engine: ChatEngine

    @State private var verification: CardVerification = .checking
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        verificationBanner
                        senderBlock
                        keyBlock
                        valueSection
                        honestyBlock
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Sealed card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(SealTheme.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { verification = await engine.verifyCard(message) }
    }

    // MARK: Sections

    private var verificationBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: bannerGlyph)
                .font(.system(size: 18))
                .foregroundStyle(bannerTint)
            VStack(alignment: .leading, spacing: 3) {
                Text(bannerTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(bannerDetail)
                    .font(.caption)
                    .foregroundStyle(bannerTint.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(bannerTint.opacity(0.35), lineWidth: 1))
    }

    /// Prefer the identity the live check resolved from the DIRECTORY over the
    /// FriendStore lookup. A card can come from a colony member you've never
    /// forged with, and for them the FriendStore has nothing — which would
    /// render a card that just verified as coming from "Someone", with a
    /// default silver ring and no fingerprint phrase at all.
    /// FriendStore first, directory second — the same precedence
    /// `ChatView.identity(for:)` uses. Preferring the directory copy would make
    /// this sheet open with the name every other screen shows and then visibly
    /// switch to a different one the moment the check returned.
    private var resolvedIdentity: RootIdentity? {
        if let senderIdentity { return senderIdentity }
        if case .sealed(_, let sender) = verification { return sender }
        return nil
    }

    private var resolvedName: String {
        if mine { return senderName }
        return resolvedIdentity?.displayName ?? senderName
    }

    private var senderBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Sealed by")
            HStack(spacing: 12) {
                // The ring draws the first letter of what it's given, so pass
                // the actual name — "You" would render a "Y" beside a label
                // reading "Nathan (you)".
                IdentityRing(displayName: resolvedName,
                             tier: resolvedIdentity?.tier ?? .passkey, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mine ? "\(resolvedName) (you)" : resolvedName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                    if let publicKey = resolvedIdentity?.publicKey {
                        Text(FingerprintPhrase.phrase(for: publicKey))
                            .font(.callout)
                            .foregroundStyle(SealTheme.brass)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var keyBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Signature")
            VStack(spacing: 0) {
                detailRow("Signing key", signerFingerprint ?? "—", monospaced: true)
                Divider().overlay(.white.opacity(0.08))
                detailRow("Key epoch", epochText, monospaced: true)
                Divider().overlay(.white.opacity(0.08))
                detailRow("Sent", message.sentAt.formatted(date: .abbreviated, time: .shortened))
            }
            .padding(.horizontal, 14)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            Text("The signing key is the first 8 hex of its SHA-256 — the same fingerprint the messaging log prints, so a card and a log line can be matched by eye.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var valueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Sealed value")
            CardValueText(card: card)
            CardCopyButton(card: card)
            if let note = card.note, !note.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("NOTE — NOT PART OF THE VALUE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.35))
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 4)
            }
        }
    }

    private var honestyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("What this proves")
            Text("That these exact bytes came from \(mine ? "your" : "\(resolvedName)'s") identity, at this point in the conversation, signed by a device that identity endorsed.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            Text("It does not prove the value is correct, that the account exists, or that the sender wasn't tricked before they typed it. Check it against a source you trust before you act on it.")
                .font(.caption)
                .foregroundStyle(.orange.opacity(0.8))
            // TODO: org / issuer badges and audit export hook in here.
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.5))
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.vertical, 11)
    }

    private var signerFingerprint: String? {
        message.proof?.signerFingerprint
    }

    /// Prefer the proof's epoch; fall back to parsing the wireID
    /// ("<sender>.e<epoch>.<index>") for cards received by an earlier build.
    private var epochText: String {
        if let epoch = message.proof?.epoch { return "\(epoch)" }
        guard let wireID = message.wireID else { return "—" }
        let parts = wireID.split(separator: ".")
        guard parts.count >= 3,
              parts[parts.count - 2].hasPrefix("e"),
              let epoch = UInt64(parts[parts.count - 2].dropFirst()) else { return "—" }
        return "\(epoch)"
    }

    private var bannerGlyph: String {
        switch verification {
        case .checking: "ellipsis.circle"
        case .sealed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unavailable: "questionmark.circle"
        case .demo: "theatermasks.fill"
        }
    }

    private var bannerTint: Color {
        switch verification {
        case .checking: .white.opacity(0.5)
        case .sealed: SealTheme.brass
        case .failed: .orange
        case .unavailable: .white.opacity(0.5)
        case .demo: .orange
        }
    }

    private var bannerTitle: String {
        switch verification {
        case .checking: "Re-checking…"
        case .sealed: "Re-checked just now"
        case .failed: "This card did not check out"
        case .unavailable: "Couldn't re-check"
        case .demo: "Demo card"
        }
    }

    /// Wording is deliberately narrow. The message key was destroyed when this
    /// message was decrypted, so the check confirms the SIGNATURE over the
    /// received message plus that the stored card still matches the digest
    /// taken at decryption — not that the bytes on screen were decrypted again.
    /// Claiming more here is the overstatement SealedCard.swift forbids.
    private var bannerDetail: String {
        switch verification {
        case .checking:
            return "Re-running the signature check against the public directory."
        case .sealed(let fingerprint, let sender):
            // The digest for an outbound card is taken at SEND, not on arrival.
            let whose = mine ? "your identity" : sender.displayName
            let when = mine ? "sent" : "received"
            return "The message carrying this card is signed by key \(fingerprint), still endorsed by \(whose) and not revoked. The card below matches the copy recorded when it was \(when)."
        case .failed(let reason), .unavailable(let reason):
            return reason
        case .demo:
            return "Demo fixtures aren't really signed — this card is here so the flow can be seen without a hardware key."
        }
    }
}
