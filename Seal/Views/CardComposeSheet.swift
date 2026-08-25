import SwiftUI

/// Compose a Sealed Card (docs/CARDS.md).
///
/// Two steps inside one sheet, because the flow is two different mental modes:
/// **compose** (transcribe one string correctly) and **commit** (irreversibly
/// seal it). Step 1 puts the value field first and carries no warning — there
/// is nothing to check yet. Step 2 shows the value exactly as the recipient's
/// bubble will render it, with the check-every-character warning immediately
/// above the characters it is talking about, and the honesty paragraph on
/// screen at the commit moment rather than below a fold.
///
/// The value field is monospaced with autocorrect and autocapitalisation off —
/// an autocorrected wallet address is a silent, total loss.
///
/// Vault Warmth (UI.md §1): SF Pro rather than Rounded, because this is a
/// security surface; brass on the seal glyph and the final commit only, which
/// are the trust moments; orange on the warnings, matching the TTL and
/// screenshot notices elsewhere. No mascot (UI.md §1.1).
struct CardComposeSheet: View {
    let chat: ChatEngine.Chat
    let myRoot: RootIdentity
    @Bindable var engine: ChatEngine

    private enum Step { case compose, review }

    @State private var step: Step = .compose
    @State private var cardType: SealedCardType = .cryptoAddress
    @State private var title = ""
    @State private var value = ""
    @State private var asset = ""
    @State private var note = ""
    @State private var validationMessage: String?
    /// Built by `SealedCard.validated` when Review is tapped; what step 2 shows
    /// and what `send()` sends, so the preview and the wire bytes can't drift.
    /// The raw fields above are never cleared, so Back preserves everything.
    @State private var reviewedCard: SealedCard?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    // Grouped: ViewBuilder tops out at 10 direct children.
                    VStack(alignment: .leading, spacing: 20) {
                        if step == .compose {
                            composeStep
                        } else if let reviewedCard {
                            reviewStep(reviewedCard)
                        }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            // Short titles: the old "Seal a card" truncated to "Seal a…" next
            // to two toolbar buttons. The primary action now lives at the
            // bottom, so the bar holds one word and one button.
            .navigationTitle(step == .compose ? "New card" : "Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .compose {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        // Back to compose, every field intact.
                        Button {
                            withAnimation(.snappy) { step = .compose }
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                                .labelStyle(.titleAndIcon)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { primaryButton }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Step 1 · Compose

    /// Value first. Title/asset/note are metadata and fade in only once there
    /// is a value to label — before that they are noise between the sender and
    /// the one field that matters. (Chosen over a disclosure group after seeing
    /// both: the fade needs no extra tap and can't hide a half-filled field.)
    @ViewBuilder
    private var composeStep: some View {
        Group {
            typePicker
            valueField
            if let validationMessage {
                inlineError(validationMessage)
            }
        }
        if !trimmedValue.isEmpty {
            Group {
                titleField
                if cardType.usesAsset { assetField }
                noteField
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: - Step 2 · Review and seal

    /// The warning sits immediately above the characters it is telling the
    /// sender to check, and the honesty paragraph is on screen at the commit
    /// moment — that ordering is the point of the whole restructure.
    @ViewBuilder
    private func reviewStep(_ card: SealedCard) -> some View {
        Group {
            warningBanner
            reviewValue(card)
            reviewSummary(card)
        }
        Group {
            destinationLine
            ttlWarning
            if let validationMessage {
                inlineError(validationMessage)
            }
            honestyNote
        }
    }

    /// Rendered through the same `CardValueText` the recipient's bubble uses,
    /// so this preview IS what they'll see — chunking included.
    private func reviewValue(_ card: SealedCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("How they'll see it")
            CardValueText(card: card)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(SealTheme.brass.opacity(0.25), lineWidth: 1))
            if cardType.chunksForDisplay {
                Text("Spaces are added for readability. They aren't part of the address and aren't copied.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func reviewSummary(_ card: SealedCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryRow("Title", card.title,
                       footnote: "A label for the chat list. Not part of what's sealed for verification.")
            summaryRow("Type", card.typeLine, footnote: nil)
            if let note = card.note, !note.isEmpty {
                summaryRow("Note", note, footnote: "Context — shown separately from the sealed value.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func summaryRow(_ label: String, _ text: String, footnote: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            fieldLabel(label)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var destinationLine: some View {
        Label("Sending to \(chat.name)", systemImage: "paperplane")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
    }

    // MARK: - Primary button

    /// One primary action per step, pinned above the keyboard/home indicator.
    /// Deliberately never disabled: tapping with an empty or malformed value
    /// must SAY what's wrong, not sit inert and leave the sender guessing.
    /// Brass is reserved for the commit — Review is navigation, not a trust
    /// moment (UI.md §1).
    private var primaryButton: some View {
        Button {
            step == .compose ? review() : send()
        } label: {
            Text(step == .compose ? "Review" : "Seal and send")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(step == .compose ? Color.white.opacity(0.12) : SealTheme.brass,
                            in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(step == .compose ? .white : SealTheme.ink)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(SealTheme.ink.opacity(0.94))
    }

    // MARK: - Sections

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "seal.fill")
                .font(.system(size: 18))
                .foregroundStyle(SealTheme.brass)
            VStack(alignment: .leading, spacing: 3) {
                Text("This will be sealed exactly as written.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Check every character. It can't be edited after it's sent.")
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(SealTheme.brass.opacity(0.35), lineWidth: 1))
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Type")
            Picker("Type", selection: $cardType) {
                ForEach(SealedCardType.allCases, id: \.self) { type in
                    Text(shortLabel(type)).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: cardType) { _, _ in validationMessage = nil }
        }
    }

    /// The segmented control has no room for "Payment instructions".
    private func shortLabel(_ type: SealedCardType) -> String {
        switch type {
        case .cryptoAddress: "Address"
        case .paymentInstructions: "Payment"
        case .statement: "Statement"
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Title")
            TextField("My BTC cold wallet", text: $title)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .padding(12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            Text("A label for the chat list. Not part of what's sealed for verification.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var assetField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Asset (optional)")
            TextField("BTC", text: $asset)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .foregroundStyle(.white)
                .padding(12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var valueField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                fieldLabel(cardType == .statement ? "Statement" : "Value")
                Spacer()
                // The system paste control: an explicit tap grants pasteboard
                // access without the "Allow Paste?" prompt a programmatic read
                // would trigger.
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first else { return }
                    value = pasted
                    validationMessage = nil
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .tint(SealTheme.brass)
            }
            ZStack(alignment: .topLeading) {
                // Autocorrect and autocapitalisation OFF for every type, not
                // just addresses. The contract is "exactly as written", and iOS
                // helpfully capitalising the first letter of a statement, or
                // "correcting" a reference number, breaks it just as thoroughly
                // as mangling a bech32 address does.
                TextEditor(text: $value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: cardType == .cryptoAddress ? 78 : 130)
                    .padding(6)
                    .onChange(of: value) { _, _ in validationMessage = nil }
                if value.isEmpty {
                    Text(cardType.valuePlaceholder)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("This is the only field a recipient can copy.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                if byteCount > SealedCard.maxValueBytes / 2 {
                    Text("\(byteCount)/\(SealedCard.maxValueBytes)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(byteCount > SealedCard.maxValueBytes
                                         ? .orange : .white.opacity(0.4))
                }
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("Note (optional)")
            TextField("Context — shown separately from the sealed value", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .foregroundStyle(.white)
                .padding(12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Cards are not exempt from disappearing messages — say so before sending
    /// rather than quietly carving out an exception to what the verification
    /// drawer promises.
    @ViewBuilder
    private var ttlWarning: some View {
        if let ttl = engine.chats.first(where: { $0.id == chat.id })?.ttl {
            Label("Disappearing messages are on in this chat — this card will be deleted after \(ttlLabel(ttl)), like every other message.",
                  systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.orange.opacity(0.85))
        }
    }

    private var honestyNote: some View {
        Text("A sealed card proves these exact bytes came from your identity. It doesn't prove the address is correct — check it against the source you trust before you send it.")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.35))
    }

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.5))
    }

    // MARK: - Helpers

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var byteCount: Int { trimmedValue.utf8.count }

    /// Matches the exact values ChatView's TTL menu offers. Deliberately not a
    /// range match: this line is read immediately before someone seals a wallet
    /// address, and a range would keep rendering "1 minute" for any new option
    /// added below an hour without anyone noticing it had started lying.
    private func ttlLabel(_ ttl: TimeInterval) -> String {
        switch ttl {
        case 60: return "1 minute"
        case 3600: return "1 hour"
        case 86_400: return "1 day"
        default:
            return Duration.seconds(ttl).formatted(
                .units(allowed: [.days, .hours, .minutes], width: .wide))
        }
    }

    /// Validate, and only move to review if the card builds. Same never-inert
    /// contract as sending: a malformed value gets a readable reason inline.
    private func review() {
        do {
            reviewedCard = try SealedCard.validated(cardType: cardType, title: title,
                                                    value: value, asset: asset, note: note)
            validationMessage = nil
            withAnimation(.snappy) { step = .review }
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func send() {
        do {
            // Re-validated from the raw fields at the moment of commit — cheap,
            // and it means the sent card can never differ from a stale
            // `reviewedCard` if a future edit path forgets to rebuild it.
            let card = try SealedCard.validated(cardType: cardType, title: title,
                                                value: value, asset: asset, note: note)
            Task {
                // Commit-moment check ("Face ID to seal a card", AppLock).
                // Runs AFTER validation so a cancelled prompt costs nothing,
                // and BEFORE dismiss so a refused prompt leaves the sender on
                // the review step with a plain-language reason, not a silently
                // unsent card.
                guard await AppLock.confirmSeal(ownerHash: myRoot.credentialIDHash) else {
                    validationMessage = "Couldn't confirm it's you — nothing was sent."
                    return
                }
                // Dismiss immediately after confirmation: the card is appended
                // optimistically by sendPayload, so the sender sees it land in
                // the chat, and a queued offline send shouldn't hold the sheet.
                dismiss()
                await engine.sendCard(card, in: chat, from: myRoot)
            }
        } catch {
            validationMessage = error.localizedDescription
            withAnimation(.snappy) { step = .compose }
        }
    }
}
