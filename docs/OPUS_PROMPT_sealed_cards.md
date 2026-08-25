# Prompt for Opus: Sealed Cards feature

Copy everything below this line into the coding session (repo `~/Documents/GitHub/Seal` mounted).

---

You are working on **Seal**, an iOS 26+ SwiftUI E2EE messenger with no backend (CloudKit public DB transport). Read `HANDOFF.md`, `docs/SDS.md`, and skim `Seal/Crypto/` and `Seal/Sync/` before writing any code. Follow the existing architecture exactly — do not introduce new dependencies, servers, or schema record types.

## Feature: Sealed Cards

A **Sealed Card** is a new message kind for high-stakes payloads — a crypto wallet address, wire/payment instructions, or a free-form "verified statement." It must be visually unmistakable from a normal bubble and must make the *exact signed string* the only thing a recipient can copy.

### Architecture constraints (non-negotiable)

1. Travel through the **existing E2EE pipeline** as a new payload kind, exactly the way `kind:"reaction"`, `kind:"screenshot"`, and `kind:"read"` already do (see `ChatEngine` and `MessagePayload`). No new CloudKit record types, no schema changes. The card is a bubble kind, not a non-bubble kind (`isNonBubble` stays false for it).
2. The card's payload fields ride **inside the encrypted payload**, so they inherit the sender-chain signature, the AAD transcript binding (group|epoch|sender|index|prev-hash), and TTL handling automatically. Do not add any separate signature scheme — the message signature IS the card's authenticity.
3. Persisted and rendered via the existing `ChatMessage` model + keychain store pattern (`seal.chats.<hash>`). Give cards a stable `wireID` reference like reactions use, so future features (reactions on cards, replies to cards) work.
4. **Compatibility:** older builds must degrade gracefully. Include a `fallbackText` field in the payload (e.g. "🔏 Sealed card: BTC address — update Seal to view") so pre-card builds render something meaningful instead of an empty bubble. Follow the compat notes in HANDOFF.md.

### Payload shape (add to MessagePayload)

`kind: "card"` plus a `card` object:
- `cardType`: `"cryptoAddress" | "paymentInstructions" | "statement"`
- `title`: short sender-supplied label ("My BTC cold wallet", "Wire instructions — escrow #4412")
- `value`: THE string that matters (the address / the instructions / the statement). This is the only copyable field.
- `asset` (cryptoAddress only): free-text ticker like "BTC", "ETH"
- `note`: optional short context, clearly rendered as NOT part of the verified value
- `fallbackText`: as above

Validation on send: `value` non-empty, ≤ 2 KB, trimmed of surrounding whitespace. For `cryptoAddress`, do a lightweight sanity check only (non-empty, no internal whitespace) — do NOT attempt per-chain checksum validation; render the string faithfully instead.

### UI (follow `docs/UI.md` "Vault Warmth"; brass = trust moments only, no mascot on security surfaces)

**Compose:** a new option in the composer (e.g. a seal/card button beside the camera) → sheet with card type picker, title, value (monospaced field, paste-friendly), optional note. Prominent warning copy: "This will be sealed exactly as written. Check every character."

**The card bubble:** visually distinct from all other bubbles — bordered card with a small brass seal glyph, the title, and the `value` in monospaced type, chunked for readability (groups of 4 chars for crypto addresses). Under it, a verification line: sender's display name + "Sealed" + timestamp. Tap the seal → the existing verification drawer / a detail sheet showing sender identity, key fingerprint (8-hex, same style as the messaging os-log fingerprints), epoch, and the fingerprint phrase.

**Copy behavior (this is the whole point):** one explicit "Copy" button that copies `value` byte-for-byte. Text selection elsewhere on the card is disabled. After copying, re-read the pasteboard and compare to `value`; if they differ (clipboard-manager interference), show an alert. Show a confirmation toast with the first/last 6 characters of what was actually copied — this is the anti-clipboard-swap UX.

**Screenshot-style notice:** none needed; cards are normal messages.

### Out of scope (do not build)

Org/issuer badges, audit export, backup keys, Android, per-chain address validation, QR rendering. Leave TODO comments where they'd hook in.

### Definition of done

- Send + receive a card of each type between two identities in demo mode (`DemoFixtures` should seed one example card so App Review / screenshots show it).
- Old-build fallback verified by rendering a card payload through the pre-card decode path.
- Copy button round-trip check works.
- No CloudKit schema changes (`git diff` shows only Swift + docs).
- Update `HANDOFF.md` (feature status section, same style as existing entries) and add a short `docs/CARDS.md`.
- Commit after it builds and works, message style consistent with repo history.

Work in small verified steps: payload + engine first, then compose UI, then bubble + detail sheet, then demo fixture, then docs.
