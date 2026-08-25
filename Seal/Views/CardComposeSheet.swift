import SwiftUI

/// Compose a Sealed Card (docs/CARDS.md).
///
/// The whole screen exists to slow the sender down for about four seconds. The
/// value field is monospaced with autocorrect and autocapitalisation off — an
/// autocorrected wallet address is a silent, total loss — and a live preview
/// shows the chunked value exactly as the recipient will see it, so "check
/// every character" is something the sender can actually do here rather than
/// advice they're given after the fact.
///
/// Vault Warmth (UI.md §1): SF Pro rather than Rounded, because this is a
/// security surface; brass on the seal glyph only, which is the trust moment;
/// orange on the warnings, matching the TTL and screenshot notices elsewhere.
/// No mascot (UI.md §1.1).
struct CardComposeSheet: View {
    let chat: ChatEngine.Chat
    let myRoot: RootIdentity
    @Bindable var engine: ChatEngine

    @State private var cardType: SealedCardType = .cryptoAddress
    @State private var title = ""
    @State private var value = ""
    @State private var asset = ""
    @State private var note = ""
    @State private var validationMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    // Grouped in threes: ViewBuilder tops out at 10 direct
                    // children, and a flat list here was already at exactly 10.
                    VStack(alignment: .leading, spacing: 20) {
                        Group {
                            warningBanner
                            typePicker
                            titleField
                            if cardType.usesAsset { assetField }
                        }
                        Group {
                            valueField
                            preview
                            noteField
                        }
                        Group {
                            ttlWarning
                            if let validationMessage {
                                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            honestyNote
                        }
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Seal a card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Deliberately never disabled: tapping with an empty or
                    // malformed value should SAY what's wrong, not sit inert
                    // and leave the sender guessing.
                    Button("Seal and send") { send() }
                        .fontWeight(.semibold)
                        .foregroundStyle(SealTheme.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
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

    /// Shows the value exactly as the recipient's card will render it, chunking
    /// included. This is where "check every character" actually happens.
    @ViewBuilder
    private var preview: some View {
        if !trimmedValue.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("How they'll see it")
                Text(cardType.chunksForDisplay ? SealedCard.chunked(trimmedValue) : trimmedValue)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(SealTheme.brass.opacity(0.25), lineWidth: 1))
                    .accessibilityLabel(trimmedValue)
                if cardType.chunksForDisplay {
                    Text("Spaces are added for readability. They aren't part of the address and aren't copied.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
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

    private func send() {
        do {
            let card = try SealedCard.validated(cardType: cardType, title: title,
                                                value: value, asset: asset, note: note)
            // Dismiss immediately: the card is already appended optimistically
            // by sendPayload, so the sender sees it land in the chat, and a
            // queued offline send shouldn't hold the sheet open.
            dismiss()
            Task { await engine.sendCard(card, in: chat, from: myRoot) }
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
