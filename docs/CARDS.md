# Sealed Cards

**Version:** 0.1 · **Date:** 2026-08-25 · **Companions:** [SDS.md](SDS.md) · [UI.md](UI.md) · `Seal/Cards/SealedCard.swift`

A **Sealed Card** carries a high-stakes string — a crypto wallet address, wire or
payment instructions, or a short statement — through the ordinary message
pipeline, wrapped in a UI that makes it impossible to mistake for chat and makes
the sender's exact bytes the only thing a recipient can copy.

## 1. Why it isn't a new protocol

A card is `kind:"card"` inside `MessagePayload`, exactly the way
`kind:"reaction"`, `kind:"screenshot"` and `kind:"read"` already work. That
buys, for free:

- the sender-chain signature over `ciphertext ‖ aad`;
- the AAD transcript binding — `group | epoch | sender | index | prev-hash`
  (SDS §2), so a card can't be reordered, replayed into another conversation, or
  silently dropped without the next message failing;
- TTL handling, the offline outbox, epoch rotation, block/report, reactions and
  replies (a card carries the same `wireID` as any other message);
- CloudKit transport with **no new record type and no schema change**.

There is deliberately **no second signature scheme**. The message signature *is*
the card's authenticity. A separate one would be another thing to get wrong, and
it would have to be verified against the same directory and the same endorsement
chain anyway.

A card is a **bubble kind** — `isNonBubble` stays false — so it gets `recipients`
and fires the normal push.

## 2. Payload

```
kind: "card"
text: <fallbackText>            ← see §3, this is not decoration
card: {
  cardType:     "cryptoAddress" | "paymentInstructions" | "statement"
  title:        short sender-supplied label
  value:        THE string. The only copyable field.
  asset:        free-text ticker, cryptoAddress only ("BTC", "ETH")
  note:         optional context, rendered as NOT part of the value
  fallbackText: "🔏 Sealed card: BTC address — update Seal to view"
}
```

**Validation on send** (`SealedCard.validated`): surrounding whitespace trimmed,
`value` non-empty and ≤ 2 KB of UTF-8, `title` non-empty. For `cryptoAddress`,
one sanity check only — no internal whitespace.

**No per-chain checksum validation, ever.** A validator that doesn't know a chain
rejects good addresses, and one that gets a checksum subtly wrong is worse than
none at all. Render the string faithfully and let the human compare. Interior
bytes are never rewritten for the same reason: silently "fixing" the middle of a
string someone is about to wire money against is the exact bug this feature
exists to prevent.

## 3. Old-build compatibility

A pre-card build decodes a card payload without error — Swift's synthesized
decoder ignores unknown keys — falls through the receive switch's `default:`
branch, and renders **`payload.text` and nothing else**.

So `sendCard` writes `fallbackText` into `text` as well as into the card. Put the
fallback only inside `card` and an older client shows an *empty bubble*, which is
the failure the field exists to prevent. Verified by decoding a real card payload
against the pre-card field set for all three card types.

On a build that *can* render cards, `text` is never displayed:
`ChatEngine.summary` returns `🔏 <title>` for the chat list and reply quotes. The
`value` is never summarised anywhere — a truncated address in a list row is an
invitation to misread it.

## 4. Copy behaviour — the whole point

- Exactly one Copy button. It copies `value` byte for byte, never `displayValue`
  (which carries the readability spaces).
- Free text selection is off everywhere on the card. SwiftUI `Text` isn't
  selectable unless `.textSelection(.enabled)` is applied, and it never is.
- After writing, the pasteboard is **read back and compared**. A clipboard
  manager or another app that rewrites the string between the write and the read
  is caught, and the alert says not to paste it.
- The confirmation shows the first and last six characters of what *actually*
  landed, not a green tick — so the reader checks the ends against the card.
  Values of 16 characters or fewer are shown whole.
- A `nil` pasteboard read is reported as **"couldn't confirm"**, not as
  tampering. The pasteboard can decline to report its contents, and a false
  "something changed your clipboard" alarm would spend the credibility of the
  one alert that has to be believed.

**Honest limit:** the round-trip check narrows the window, it does not close it.
Something that rewrites the pasteboard a second after the read still wins. That
is why the confirmation shows bytes rather than claiming success.

## 5. Verification, and what it actually proves

Cards are the only message kind that keeps a `MessageProof` — the ciphertext,
signature, signer device key, and the AAD inputs. Ordinary bubbles are verified
on arrival and then they're just text, which is fine for "see you saturday". A
card can be acted on days later, and there *"it verified when it arrived"* is a
memory, not a proof.

Tapping the seal re-runs `IdentityManager.verify` against a **force-refreshed**
directory entry. That catches the case an arrival-time check never can: a signing
device **revoked after the card landed**.

### The gap, stated plainly

The per-message key is destroyed by the ratchet the instant a message is
decrypted (SDS §2, per-message forward secrecy). The plaintext therefore can
**never** be re-derived. So re-checking the signature proves the stored
*ciphertext* is authentic — **not** that the card rendered on screen is what that
ciphertext contained.

`MessageProof.cardDigest` closes that on our own side: a SHA-256 of the card as
decoded, recorded at decryption, compared against the stored card on every
re-check. It catches the stored copy drifting through a bug, a migration, or
corruption. It does **not** defend against anything that can rewrite the
keychain, which would rewrite the digest too.

The detail sheet's wording claims exactly this and no more: *"The message
carrying this card is signed by key `<fp>` — a device `<name>` still endorses and
hasn't revoked. The card below matches the copy recorded when it arrived."*

`.failed` and `.unavailable` are separate states on purpose. "The signature is
bad" and "I couldn't reach the directory" have opposite consequences for someone
about to send money; one grey state covering both would be a lie in whichever
direction it resolved.

### What a card does not prove, full stop

That the address is correct. That the account exists. That the money will arrive.
That the sender wasn't tricked or compromised *before* they typed it. A card
proves that this identity — hardware-rooted, met in person — sent these exact
bytes at this point in the transcript. **Provenance, not truth.** The UI never
says "verified address"; it says "Sealed".

## 6. Cards vs. Custody Receipts

`Seal/Receipts/CustodyReceipt.swift` is a **strictly stronger** claim and the
copy must keep the two visibly apart:

| | Sealed Card | Custody Receipt |
|---|---|---|
| Parties | One — the sender asserts | Two — both sign the same commitment |
| Strong half | Device key (root-endorsed) | Receiver's **root** credential, physically tapped |
| Re-verifiable | Signature + digest, needs local state | Fully self-contained, offline, years later |
| Says | "I sent you this string" | "I handed you this, you took it" |

A card is one party asserting something. A receipt is two parties agreeing. The
`statement` card type sits closest to a receipt and is therefore the one to watch:
its copy says "Sealed by \<name\>" and never "verified", "attested" or "notarized".

## 7. Disappearing messages

Cards are **not** exempt from TTL. They inherit the chat's setting like any other
message, show the same hourglass, and burn on the same schedule. Carving out a
message class would quietly break the promise the verification drawer makes about
FR-12, so `CardComposeSheet` warns before sending instead of overriding.

## 8. Costs and limits

- A card's `MessageProof` stores the full message ciphertext (up to ~2 KB plus
  GCM overhead) in addition to the decoded card. `persist()` serialises all of
  `messagesByChat` into the single `seal.messages.<hash>` keychain item, so cards
  cost roughly double a normal message there. Cards are rare by nature; measure
  before this matters. **TODO:** proof trimming or expiry if it ever does.
- **Every field added to `MessageProof` in future must be optional.** A proof
  that fails to decode takes the whole message store with it.
- Inbound `value` length is bounded by CloudKit's Bytes field, not by our 2 KB
  send-side cap — a modified client could exceed it. The bubble line-limits long
  values and pushes the full string to the detail sheet.

## 9. Out of scope (TODO comments mark where each hooks in)

Org/issuer badges (`SealedCard.validated`, beside `asset`), audit export and
backup keys (`SealedCardDetailSheet.honestyBlock`), Android, per-chain address
validation (§2 — deliberately never), QR rendering, and editing or retracting a
sent card.
