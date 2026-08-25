import Foundation
import CryptoKit

//  SealedCard.swift
//  Seal
//
//  A HIGH-STAKES STRING, SENT EXACTLY AS WRITTEN.
//
//  A Sealed Card carries a crypto wallet address, payment instructions, or a
//  short statement. Cryptographically it is nothing new: it rides the existing
//  pipeline as `kind:"card"`, exactly the way `kind:"reaction"` and
//  `kind:"screenshot"` do, so it inherits the sender-chain signature, the AAD
//  transcript binding (group|epoch|sender|index|prev-hash) and TTL handling for
//  free. There is deliberately NO second signature scheme — the message
//  signature IS the card's authenticity, and a second one would only be another
//  thing to get wrong.
//
//  WHAT IS ACTUALLY NEW IS THE UI CONTRACT
//  ---------------------------------------
//  * `value` is the only field that matters, and the only field a recipient can
//    copy. Free text selection is off everywhere on the card, so the string
//    that reaches the pasteboard is the string the sender sealed.
//  * Copy re-reads the pasteboard afterwards and compares. A clipboard manager
//    that rewrites an address between the write and the read is caught; one
//    that rewrites it later is not, and the UI says so rather than implying a
//    guarantee it can't make.
//  * The copy confirmation shows the first and last characters of what actually
//    landed on the pasteboard, so the reader checks the ends against the card.
//  * `note` renders as visibly NOT part of the sealed value.
//
//  WHAT A CARD DOES NOT PROVE
//  --------------------------
//  That the address is correct, that the account exists, that the money will
//  arrive, or that the sender wasn't tricked or compromised before they typed
//  it. A card proves that THIS identity — hardware-rooted, met in person — sent
//  THESE exact bytes at this point in the transcript. Provenance, not truth.
//  The UI must never say "verified address"; it says "Sealed by <name>".
//
//  Compare CustodyReceipt.swift, which is two-party and dual-signed (the
//  receiver's ROOT credential, physically tapped, plus the giver's device key)
//  and is therefore a strictly stronger claim. A card is one party asserting
//  something; a receipt is two parties agreeing. Keep the copy for the two
//  visibly different — see docs/CARDS.md.
//
//  Out of scope on purpose (TODOs where they'd hook in): org/issuer badges,
//  audit export, backup keys, per-chain address validation, QR rendering.

// MARK: - Card kinds

enum SealedCardType: String, Codable, Hashable, CaseIterable {
    case cryptoAddress
    case paymentInstructions
    case statement

    /// Short label for the type picker and the card header.
    var label: String {
        switch self {
        case .cryptoAddress: "Crypto address"
        case .paymentInstructions: "Payment instructions"
        case .statement: "Statement"
        }
    }

    var valuePlaceholder: String {
        switch self {
        case .cryptoAddress: "Paste the address"
        case .paymentInstructions: "Account name, number, routing/IBAN, reference…"
        case .statement: "The exact words to seal"
        }
    }

    /// Only crypto addresses are regrouped into fixed-width chunks; payment
    /// instructions and statements are multi-line prose and chunking them would
    /// destroy them.
    var chunksForDisplay: Bool { self == .cryptoAddress }

    /// Only crypto addresses carry a ticker.
    var usesAsset: Bool { self == .cryptoAddress }

    var copyLabel: String {
        switch self {
        case .cryptoAddress: "Copy address"
        case .paymentInstructions: "Copy instructions"
        case .statement: "Copy statement"
        }
    }
}

// MARK: - The card

/// Rides inside the encrypted `MessagePayload`, so every field here is covered
/// by the message signature and the AAD transcript binding.
struct SealedCard: Codable, Hashable {
    let cardType: SealedCardType
    /// Sender-supplied label ("My BTC cold wallet", "Wire instructions — escrow #4412").
    let title: String
    /// THE string that matters. The only copyable field.
    let value: String
    /// Free-text ticker, crypto addresses only ("BTC", "ETH"). Never validated
    /// against a chain registry — it's a label, not a claim.
    var asset: String?
    /// Optional context, rendered as clearly NOT part of the sealed value.
    var note: String?
    /// What a build with no card support renders. See `ChatEngine.sendCard` —
    /// this string is ALSO copied into `MessagePayload.text`, which is the only
    /// field an older client actually reads.
    let fallbackText: String

    // MARK: Validation

    /// 2 KB of UTF-8. Comfortably above any real address or wire instruction,
    /// far below anything that would strain a CloudKit Bytes field.
    static let maxValueBytes = 2048
    static let maxTitleCharacters = 80
    static let maxNoteCharacters = 280
    static let maxAssetCharacters = 12

    enum ValidationError: LocalizedError, Equatable {
        case emptyTitle
        case emptyValue
        case valueTooLong(bytes: Int)
        case addressHasWhitespace

        var errorDescription: String? {
            switch self {
            case .emptyTitle:
                return "Give the card a title so it's recognisable in the chat."
            case .emptyValue:
                return "There's nothing to seal yet."
            case .valueTooLong(let bytes):
                return "That's \(bytes) bytes — a sealed card holds up to \(SealedCard.maxValueBytes)."
            case .addressHasWhitespace:
                return "A crypto address can't contain spaces or line breaks. Check what you pasted."
            }
        }
    }

    /// Build a card or explain why not.
    ///
    /// Trims SURROUNDING whitespace only. Interior bytes are preserved exactly:
    /// a wire instruction legitimately contains newlines, and silently
    /// rewriting the middle of a string somebody is about to send money against
    /// is precisely the class of bug this feature exists to prevent.
    ///
    /// For `cryptoAddress` the only check is a sanity check — non-empty, no
    /// internal whitespace. NO per-chain checksum validation, on purpose: a
    /// validator that doesn't know a chain rejects good addresses, and one that
    /// gets a checksum subtly wrong is worse than none. Render faithfully and
    /// let the human compare.
    /// TODO: an issuer/org badge would attach here, alongside `asset`.
    static func validated(cardType: SealedCardType,
                          title: String,
                          value: String,
                          asset: String? = nil,
                          note: String? = nil) throws -> SealedCard {
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxTitleCharacters))
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNoteCharacters))
        }
        let cleanAsset = asset.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxAssetCharacters))
        }

        guard !cleanTitle.isEmpty else { throw ValidationError.emptyTitle }
        guard !cleanValue.isEmpty else { throw ValidationError.emptyValue }
        let byteCount = cleanValue.utf8.count
        guard byteCount <= maxValueBytes else { throw ValidationError.valueTooLong(bytes: byteCount) }
        if cardType == .cryptoAddress,
           cleanValue.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            throw ValidationError.addressHasWhitespace
        }

        let ticker = cardType.usesAsset ? cleanAsset.flatMap { $0.isEmpty ? nil : $0 } : nil
        return SealedCard(cardType: cardType,
                          title: cleanTitle,
                          value: cleanValue,
                          asset: ticker,
                          note: cleanNote.flatMap { $0.isEmpty ? nil : $0 },
                          fallbackText: fallbackText(for: cardType, asset: ticker))
    }

    // MARK: Compatibility

    /// What a pre-card build shows. It reads `MessagePayload.text` and nothing
    /// else, so `sendCard` puts this string there as well as here — without
    /// that, an older client renders an empty bubble.
    ///
    /// Deliberately excludes the title: the title is free text and could be
    /// long, confusing, or misleading out of context, and the fallback's whole
    /// job is to be short and unambiguous about what happened.
    static func fallbackText(for cardType: SealedCardType, asset: String?) -> String {
        let what: String
        switch cardType {
        case .cryptoAddress:
            let ticker = asset.flatMap { $0.isEmpty ? nil : $0 } ?? "crypto"
            what = "\(ticker) address"
        case .paymentInstructions:
            what = "payment instructions"
        case .statement:
            what = "statement"
        }
        return "🔏 Sealed card: \(what) — update Seal to view"
    }

    // MARK: Display helpers

    /// The value as it should be SHOWN. Crypto addresses are regrouped into
    /// fixed-width chunks so a human can compare them against another screen
    /// without losing their place; everything else is untouched.
    ///
    /// This is never what gets copied. The spaces below do not exist in
    /// `value`, and only `value` ever reaches the pasteboard.
    var displayValue: String {
        cardType.chunksForDisplay ? Self.chunked(value) : value
    }

    static func chunked(_ string: String, size: Int = 4) -> String {
        guard size > 0, string.count > size else { return string }
        var out = ""
        out.reserveCapacity(string.count + string.count / size)
        for (offset, character) in string.enumerated() {
            if offset > 0, offset % size == 0 { out.append(" ") }
            out.append(character)
        }
        return out
    }

    /// Header line under the title: "BTC · Crypto address" or just the type.
    var typeLine: String {
        if let asset, !asset.isEmpty { return "\(asset) · \(cardType.label)" }
        return cardType.label
    }

    /// What the copy confirmation says — the ACTUAL bytes that landed on the
    /// pasteboard, abbreviated. This is the anti-clipboard-swap cue: the reader
    /// checks these ends against the card, so a swapped string shows up as
    /// mismatched ends rather than as nothing at all.
    ///
    /// Short values are shown whole. Abbreviating a 10-character string would
    /// both reveal essentially all of it anyway and read as corruption.
    static func copyConfirmation(for copied: String) -> String {
        copied.count <= 16
            ? "Copied \(copied)"
            : "Copied \(copied.prefix(6))…\(copied.suffix(6))"
    }

    /// Reproducible digest of the card, recorded in `MessageProof` when the
    /// message is decrypted so the stored copy can be checked against it later.
    ///
    /// `.sortedKeys` because `JSONEncoder`'s default key order is not a
    /// documented guarantee, and this digest has to still match one computed
    /// months later on a different OS version.
    ///
    /// Returns nil rather than a sentinel if the encode ever fails. A sentinel
    /// would be both recorded and recomputed identically, so two failures would
    /// compare EQUAL and the check would pass on a digest that was never taken.
    /// A check whose only job is to catch drift must not fail open.
    var digest: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return Data(SHA256.hash(data: data))
    }
}

// MARK: - Re-checkable proof

/// Everything needed to re-check an inbound message's signature later, instead
/// of trusting the fact that we once checked it.
///
/// Ordinary bubbles don't carry this. They're verified on arrival by
/// `ChatEngine.verifyInbound` and after that they're just text, which is fine
/// for "see you saturday". A card can be a wire instruction somebody acts on
/// days later, and there "it verified when it arrived" is a memory, not a
/// proof. Keeping the tuple lets the detail sheet re-run
/// `IdentityManager.verify` against a freshly fetched directory entry every
/// time it opens — which also catches the case where the signing device was
/// REVOKED after the card landed, something an arrival-time check can't.
///
/// This is not a second signature scheme (SDS §2 / docs/CARDS.md): it is the
/// same message signature, kept instead of discarded.
///
/// EVERY FIELD ADDED HERE IN FUTURE MUST BE OPTIONAL. `ChatMessage.proof` is
/// decoded as part of the single `seal.messages.<hash>` blob, so a proof that
/// fails to decode takes the entire message store with it.
struct MessageProof: Codable, Hashable {
    let ciphertext: Data
    let signature: Data
    let signerDevicePublicKey: Data
    /// AAD inputs. Stored explicitly rather than re-derived from the chat and
    /// the wireID so the proof stays self-contained and survives any future
    /// change to how those are formatted.
    let groupID: String
    let epoch: UInt64
    let chainIndex: UInt64
    /// The transcript hash bound into THIS message's AAD — the sender's
    /// previous ciphertext hash. nil for the first message of a chain.
    let prevMessageHash: Data?
    /// `SealedCard.digest` of the card as it was decoded from the decrypted
    /// payload.
    ///
    /// This exists because re-checking the signature proves LESS than it looks
    /// like it proves. The message key was destroyed by the ratchet the instant
    /// this message was decrypted (SDS §2, per-message forward secrecy), so the
    /// plaintext can never be re-derived: the signature check confirms the
    /// stored ciphertext is authentic, NOT that the card rendered on screen is
    /// what that ciphertext contained. This digest closes the remaining gap on
    /// our own side — it catches the stored card drifting from the decoded one
    /// through a bug, a migration, or corruption.
    ///
    /// It does NOT defend against anything that can rewrite the keychain, which
    /// would rewrite the digest too. The detail sheet's wording claims exactly
    /// this much and no more.
    ///
    /// Optional, per the invariant above — a non-optional field added here
    /// would fail to decode against any proof written before it existed, and
    /// because the whole message store is one keychain blob, that single throw
    /// would empty every chat's history and the next `persist()` would make it
    /// permanent. This build always writes it, so nil can only mean a proof
    /// from before the field; `verifyCard` says so rather than silently
    /// skipping the comparison.
    let cardDigest: Data?

    /// 8 hex of SHA-256 over the signing key: the same fingerprint the
    /// `messaging` os-log prints, so a card on screen and a log line in
    /// Console.app can be matched by eye.
    var signerFingerprint: String { ChatEngine.fp(signerDevicePublicKey) }
}

/// Result of re-checking a card. "The signature is bad" and "I couldn't reach
/// the directory" are kept apart on purpose: on a card carrying a wallet
/// address they have opposite consequences, and one grey state covering both
/// would be a lie in whichever direction it resolved.
enum CardVerification: Equatable {
    case checking
    /// `sender` is the identity the check resolved FROM THE DIRECTORY, which is
    /// how a card from a group member you've never forged with still renders
    /// with their real name, tier and fingerprint phrase instead of "Someone".
    case sealed(signerFingerprint: String, sender: RootIdentity)
    case failed(String)
    case unavailable(String)
    case demo
}
