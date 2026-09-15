# The Record

> **2026-09-15.** Seal became the sealed envelope product (docs/PRODUCT.md).
> Sections 1 to 3 and 7 describe the messenger era and are kept for the
> reasoning; sections 4, 5.2 and 13 (timestamps, canonical encoding, what a
> token proves) apply unchanged and the estate log builds on them. The
> export in section 6 became the capsule (docs/CAPSULE.md), and
> `tools/verify_capsule.py` is the verifier that section 6 asked for.

**Version:** 0.1 · **Date:** 2026-08-28 · **Companions:** [CARDS.md](CARDS.md) · [COLDSTART.md](COLDSTART.md) · `Seal/Receipts/CustodyReceipt.swift` · `Seal/Views/ForgeLogView.swift`

## 1. What Seal is

**A signed, timestamped record of what happened between two people who met in
person.**

The record is of **events, not content**. Seal can show that a sealed card
carrying a payment address was sent from Karen to Jason at a given moment, and
it can prove the exact bytes of that card have not changed, without ever being
able to read the address. That is not a limitation being worked around. It is
the design: Seal can prove a great deal precisely because it can read nothing.

Chat is the surface. The record is the product.

## 2. Most of this already exists

Four features have been built separately that are secretly one feature. They are
scattered across four screens and nothing presents them as a single thing.

| Event | Lives in | Signed by | Time comes from |
|---|---|---|---|
| Met in person | `Friendship.forgedAt`, FriendStore | friend's **root** credential over our nonce | the signer's own device |
| Met, auto-reciprocated | `Friendship.autoReciprocated` | peer's device key (`ForgeHandshake`) | the peer's device |
| Introduction made | `IntroductionStatement`, IntroductionStore | introducer's device key | their device |
| Sealed card sent | `ChatMessage.card` + `MessageProof` | sender's device key over `ciphertext ‖ aad` | the sender's device |
| Handover signed | `CustodyReceipt`, ReceiptStore | **both**: receiver's root, giver's device | the giver's device |
| Message sent | `ChatMessage` + transcript chain | sender's device key, hash-chained | the sender's device |
| Device added or revoked | `DeviceEndorsement` / `DeviceRevocation` | root credential | that device |
| Blocked someone | `ChatEngine.blockedHashes` | **nothing** | **nothing** |

Read the last column. **Every time source in the system is the actor's own
device.** A modified client can put any date it likes on anything. That is the
one real gap between "signed" and "provable", and it is what section 4 fixes.

Note the last row honestly: a block is a local flag with no signature and no
time. It belongs in the record only as a clearly marked local note, never as
proof of anything.

## 3. What the record does NOT prove

This list goes in the document, in the export, and on screen. It is not
throat-clearing, it is the thing that makes the rest believable.

- **Not who the legal person is.** Seal proves credential A did something with
  credential B. Binding a credential to a passport is what notaries sell and
  Seal does not do it. `CustodyReceipt.swift` already says this and the UI must
  never imply otherwise.
- **Not that the content is true.** A photo hash proves the photo has not
  changed since signing, not that the photo depicts the truth.
- **Not the plaintext of a message.** The per-message key is destroyed by the
  ratchet on decryption (SDS §2), so a message's plaintext can never be
  re-derived. Re-checking proves the stored ciphertext is authentic and that
  the stored copy matches the digest recorded when it arrived. See CARDS.md §5,
  which states this gap precisely and does not paper over it.
- **A timestamp proves "no later than T", not "exactly at T".**
- **Nothing about a blocked contact.** See above.

## 4. Trusted timestamps

### 4.1 What and why

Take the SHA-256 of an event, send **only that hash** to a timestamp authority,
receive a signed token asserting that hash existed no later than time T. The
content never leaves the device, because a hash is not the content. This is
RFC 3161, a twenty-five year old standard with off-the-shelf verifiers.

### 4.2 Which events get one

Not every chat message. Timestamping is a network round trip and a stored token,
and chat is high volume.

- **Met in person** (both directions)
- **Sealed card sent** and **sealed card received**
- **Handover signed**
- **A periodic chain anchor**, roughly daily per conversation

The anchor is the elegant part and it comes free from work already done. The
transcript chain means every message commits to the hash of the previous one. So
timestamping a single point in the chain proves that **everything before it
existed before then**, without a token per message.

### 4.3 Failure handling, which is most of the work

The network is not always there and the authority is not always up. The rule:

**Never display a timestamp Seal does not hold.** An event is in exactly one of
three states, and the UI names which:

- `signed`: signature verified, no timestamp yet
- `timestamped`: signature verified and a token exists
- `pending`: queued for timestamping, retrying

An event that never gets a token stays `signed` forever and says so. A greyed
state that could mean either is a lie in whichever direction it resolves, which
is the same rule CARDS.md §5 already applies to `.failed` versus `.unavailable`.

Queue in the existing outbox pattern. Tokens are keyed by event digest, so a
retry is idempotent and a duplicate submission is harmless.

### 4.4 Privacy cost, stated plainly

The authority learns that some hash was submitted at time T from some address.
It learns nothing about content, parties or subject. That is real metadata
leakage and it goes in the privacy policy and in the UI, not just here.

### 4.5 Which authority

Open question, section 8. RFC 3161 gives an instant token and depends on
trusting one operator. OpenTimestamps anchors to Bitcoin, needs no trusted
operator, and takes about an hour to confirm. They are not exclusive, and
carrying both for high-value events is defensible.

## 5. The shape in code

### 5.1 `RecordEvent` is a projection, not a new store

```
struct RecordEvent: Identifiable, Codable {
    enum Kind: String, Codable {
        case metInPerson, metReciprocal, introduction,
             cardSent, cardReceived, handover, chainAnchor,
             deviceAdded, deviceRevoked, blockedLocal
    }
    let kind: Kind
    let occurredAt: Date          // the actor's claim, always
    let counterpartHash: String?
    let counterpartName: String?  // snapshot, like CustodyReceipt does
    let digest: Data              // SHA-256 over the canonical event encoding
    let summary: String           // "Sealed card: BTC address". NEVER the value.
    let sourceRef: String         // receiptID, wireID, friendRootID
}
```

**It is computed from the existing stores on demand. It is never a second copy
of the truth.** Two stores that can disagree is how a record system becomes
worthless, and `ForgeLogView` already derives its list this way.

Timestamp tokens are the only new persisted thing, stored beside the record
keyed by `digest`, so they attach to events without owning them.

### 5.2 Canonical encoding

Every digest is computed over a domain-separated, length-delimited encoding, the
same discipline `CustodyReceipt.commitment` already uses, so no two different
events can collide by shuffling bytes between fields. A record event digest is
prefixed `seal.record.v1` so it can never be replayed as a friend ceremony, a
receipt or a reciprocal handshake.

## 6. The export, which is where the value actually lands

A record nobody can check is a diary. The export is the product.

**"Give me the record with Karen"** produces:

1. A **JSON document**: every event with its type, parties as hashes plus the
   names as they stood at the time, digest, signatures, signer public keys, and
   timestamp tokens. It embeds the identity public keys it needs, so it verifies
   with **no app, no server and no account**.
2. A **readable HTML or PDF rendering** of the same thing for a human.
3. `tools/verify_record.py`, a standalone script that takes the JSON and checks
   every signature and every timestamp token, printing a line per event.

Item 3 is not optional. Without an independent verifier, "anyone can check this"
is marketing. With it, the other side's expert can run it in a minute, and that
is the entire point.

## 7. Screens

- **A person's record.** People → tap someone → Record. One chronological
  timeline. Each row: what happened, when, and the state chip from §4.3. Card
  rows show the title only, never the value, for the same reason
  `ChatEngine.summary` never summarises a card's value.
- **The whole record.** Replaces History. Same rows, all
  counterparts.
- **Export** sits at the top of a person's record.

## 8. Open questions

1. **Which timestamp authority.** RFC 3161 first for the instant token,
   OpenTimestamps as a second anchor later? Needs someone to check operator
   terms and uptime rather than picking from a search result.
2. **Do TTL chats produce record events?** A disappearing message burns, but the
   event still happened. Recording "a sealed card was sent at T, digest X" while
   the content is gone is either the most useful property here or a betrayal of
   what disappearing promised. **Decide before building.** Current lean: yes,
   record the event, and say so in the TTL copy, because the record is about
   events and always was.
3. **Are ordinary messages events at all**, or only cards, handovers and
   meetings? Current lean: only the chain anchor, not individual messages.
4. **What FRE 902(13) and (14) let us say.** Those rules remove the need for a
   live witness to authenticate, but they do not make anything admissible, and
   both still require a certification from a qualified person plus notice to the
   other side. So the claim is **"the technical showing is already done, in the
   form the rules were written for"**, and never "court admissible". One
   conversation with a litigator is worth more than a month of building here.

## 9. Build order

1. **`RecordEvent` projection plus the person timeline.** No new crypto, no
   network. Worth shipping alone, because it makes four scattered features read
   as one product for the first time.
2. **Timestamping**: the service, the queue, the three states, the chip.
3. **Export**: JSON, then `verify_record.py`, then the readable rendering.
4. Chain anchors.

## 10. Files

| File | Change |
|---|---|
| New `Seal/Record/RecordEvent.swift` | the projection and the canonical encoding |
| New `Seal/Record/TimestampService.swift` | RFC 3161 request, token store, retry queue |
| New `Seal/Record/RecordExport.swift` | JSON and the readable rendering |
| New `Seal/Views/RecordView.swift` | the timeline, per person and global |
| New `tools/verify_record.py` | standalone verifier |
| `Seal/Views/ForgeLogView.swift` | becomes a filter over the record, or retires |
| `Seal/Views/ProfileView.swift` | The Your record section points at the record |
| `site/privacy.html` | the §4.4 metadata disclosure |

---

## 11. Phase 1 as built (2026-08-28)

**Unbuilt beyond a balance check. Needs Xcode.**

New: `Seal/Record/RecordEvent.swift` and `Seal/Views/RecordView.swift`.

`RecordEvent` is a projection and adds no store. `RecordBuilder.events(...)`
reads FriendStore, ChatEngine's messages, ReceiptStore and IntroductionStore and
returns one sorted list. Seven kinds ship: met in person, met reciprocally, met
through an introduction, introduction made, card sent, card received, handover.

Digests use the section 5.2 encoding, domain-separated `seal.record.v1` and
length-delimited, so they are already the right shape for a timestamp authority
to sign in phase 2. Card events bind the card's own digest, handovers bind the
handover photo hash.

`TimeProof` ships with all three states even though phase 1 only ever produces
`.deviceClaimed`. That keeps phase 2 a new producer rather than a change to
every consumer, and it keeps the UI switch exhaustive today.

**Blocks are deliberately absent.** `ChatEngine.blockedHashes` is a bare Set
with no signature and no time. There is nothing to place on a timeline and
nothing to prove, and inventing a moment for it is the one kind of entry a
record must never contain.

Two entry points: You → Your record → **Record** for everything, and a person's
row in People → long press → **See the record** for one timeline. Record sits
above History because it is a superset; History retires into it once
the export lands.

The footer states the limits on screen: signed and re-checkable, times are the
signing phone's own clock, and a line proves credential A did something with
credential B rather than anything about a legal identity.

`ProfileView` now takes `chatEngine`, purely so the record is reachable from You.

## 12. Question 2, decided (2026-08-28)

**A record event survives its content burning.** `ChatEngine.purgeExpired()`
writes a tombstone for every sealed card it is about to drop, before it drops
it, so a card sent in a chat with disappearing messages on still leaves a line.

New: `Seal/Record/RecordStub.swift`.

- The stub keeps kind, moment, counterpart, the card's **title** and its
  **digest**. It never keeps the `value`. The value burning is the whole point
  of the TTL, and a stub carrying it would turn disappearing messages into a
  lie.
- The title surviving is a deliberate disclosure. A line reading "a card was
  sent" with no label is close to useless, the stub lives only in this phone's
  keychain, and nobody but its owner sees it. `CardComposeSheet`'s TTL warning
  now says so before the card is sealed: "Your record keeps the title and the
  time. The value goes."
- **The digest is identical before and after the burn**, because the same
  fields feed it either way. `contentBurned` is deliberately not one of those
  fields: an event does not become a different event when its content goes, and
  a line whose id changed at the moment it burned would be worthless as
  evidence.
- The capture hook is `purgeExpired` rather than send or receive, so one place
  covers every path and nothing can be dropped without passing through it, even
  a card that arrived and expired while the app was closed.
- The row says "Deleted on schedule. This line and its digest remain, the
  card's contents do not."

This is the ONE place the no-second-store rule bends, and it bends because the
original is destroyed on purpose. A tombstone cannot drift out of step with a
thing that no longer exists. Nothing else may be added here on the same excuse.

`RecordEvent.epochSeconds` is a non-trapping Date to Int64 conversion used by
both the live projection and the tombstone, so a corrupt stored date renders a
wrong row instead of crashing the viewer.

`RecordStubStore.wipe` is called from `ContentView.wipeLocalAndEngines`, so
stubs go on sign-out and delete like every other local store.

## 13. Phase 2 as built (2026-08-28)

**Compiles unverified, but the protocol code is tested. See "verification" below.**

New: `Seal/Record/TimestampService.swift`.

### What it does

Takes the SHA-256 of a record event, sends **only that hash** to an RFC 3161
timestamp authority, and keeps the signed token that comes back. The content
never leaves the device, because a hash is not the content.

### What this phone checks, and what it does not

Verifying an RFC 3161 token properly means parsing CMS SignedData and
validating a certificate chain. iOS ships no API for that, and hand-rolling a
CMS verifier to hit a deadline is exactly the wrong kind of security code. So
the app is deliberately modest:

- It **builds** the request, which is a small fixed DER structure.
- It **reads** the response's top-level `PKIStatus`, a shallow well-defined
  parse, and accepts only `granted` or `grantedWithMods`.
- It **refuses** any token that does not literally contain the digest. That is a
  byte scan, not a parse, and it is used **only to reject**. A guard that can
  produce a false rejection and never a false acceptance is a safe use of a
  heuristic. The reverse would not be.
- It **stores the token bytes untouched**, because the export verifier needs
  exactly what came back.

**It does not check the authority's signature**, and the record footer says so
in those words: "That token's own signature is checked when you export the
record, not here." Full verification belongs in `tools/verify_record.py` in
phase 3, where real ASN.1 libraries exist and where the check actually matters,
because that is the artefact somebody else reads.

### Off by default

Timestamping tells a third party that some hash was submitted at some time from
some address. Small, real, and not something an app should start doing quietly.
The toggle is **Independent timestamps** under Your record on the You screen,
off until asked, and the
record footer points at it.

### Behaviour

- Stamping runs when the record screen opens, because nothing else in the app
  knows what an event is.
- Failure is silent: no signal, a bad day at the authority, a captive portal
  returning HTML. None of those deserve an alert. The line simply stays
  "Signed".
- Five attempts, then the event settles at "Signed" and stops asking. An app
  that retries a dead endpoint forever is a battery bug wearing a feature's
  clothes.
- Twenty per pass, so a neglected record does not fire a hundred requests the
  first time somebody opens the screen.
- A fresh 64-bit nonce per request, so a replayed old response is detectable by
  a verifier even though this phone does not check it.
- `certReq` is true, so the authority returns its certificate inside the token.
  That is what lets the export verify offline years later without having to go
  and find it.

### Verification

The DER code was tested against real artefacts rather than assumed:

1. **Request encoder.** The exact algorithm was ported to Python, its output
   written to a file, and `openssl ts -query -in file -text` read it back:
   version 1, sha256, the correct message digest, the correct nonce,
   "Certificate required: yes". OpenSSL parsing our request is the definitive
   check that the encoder is right.
2. **Status parser.** A local OpenSSL TSA was stood up with a self-signed
   time-stamping certificate and produced a genuine RFC 3161 response. The
   parser, ported line for line, read `PKIStatus = 0` from it.
3. **Digest guard.** That same real response was confirmed to contain the digest
   bytes, so the reject-only guard does not throw away valid tokens.

What is still untested: the live round trip against a public authority, and
whether the chosen operator is reliable. That is open question 1 and it stays
open. `TimestampService.defaultAuthority` is FreeTSA, chosen only because it is
public and free, which is not a good enough reason to keep it.

### What makes a timestamp "official", and what does not

No library. Swift and CryptoKit have no ASN.1, no RFC 3161 and no CMS support,
and iOS ships no CMS API at all. The request builder in
`TimestampService.swift` is about eighty hand-written lines of DER. That is
exactly why it was tested against OpenSSL rather than trusted.

**The official part is not ours and never could be.** RFC 3161 is an IETF
standard from 2001. A Time Stamping Authority runs a clock it is accountable
for and signs a statement saying "this hash was presented to me at this time",
using a certificate carrying the `timeStamping` extended key usage. That
signature is the whole of the officialness. Seal contributes the hash and keeps
the token. Anyone can check it later with a one-line OpenSSL command and never
has to trust us or the app.

**There are tiers of authority, and this matters if the record is ever meant to
carry weight.**

- Any public RFC 3161 authority, which is what ships today, produces a
  technically valid token. In the United States there is no special legal status
  attached to it. It is evidence, weighed like any other evidence.
- In the European Union, a **qualified** electronic time stamp from a qualified
  trust service provider on the EU Trusted List carries a legal presumption of
  the accuracy of its date and time under eIDAS. That presumption is a real
  legal advantage and it is the difference between "a timestamp" and an
  "official" one in the sense most people mean.

`defaultAuthority` is currently FreeTSA, chosen only because it is public and
free. That is fine for proving the plumbing works and is not a defensible choice
for anything anyone relies on. Picking a real operator, and deciding whether a
qualified one is worth paying for, is open question 1 and it is still open.

A second, independent anchor is worth considering alongside whichever operator
wins: OpenTimestamps writes the hash into the Bitcoin blockchain, needs no
trusted operator at all, and confirms in about an hour. Carrying both means the
record does not depend on one company staying in business.
