# Introductions — a mutual friend vouches, remotely

**Status:** implemented 2026-08-25, UNVERIFIED ON DEVICE · **Code:** `Seal/Introductions/Introduction.swift`, `ChatEngine` (three payload kinds), `Seal/Views/IntroductionCard.swift`, `Seal/Views/IntroduceSheet.swift` · **Companions:** [SDS.md](SDS.md) §2/§5, [TRUST.md](TRUST.md) §5.1, [UI.md](UI.md) §1/§6, [CARDS.md](CARDS.md)

---

## 1. What this is, and the one thing it does not do

Friendship in Seal requires a ceremony: the friend taps THEIR root credential
on YOUR phone, and your phone verifies that signature against the public
directory. That is the product. Families are scattered, though, and a
grandmother two states away is never going to tap a key on her grandson's
phone.

An **introduction** is a third signed statement. A mutual friend who has met
both people in person signs "these two identities, these two published keys,
at this moment", both parties accept, and their phones create a friendship at a
**new, visibly different tier**: `linked` in code, **silver with a `link`
glyph** on screen.

**Brass still means physically met.** A linked friendship is never brass, never
reads "Verified", and `Friendship.isInPerson` is false for it everywhere. The
honest sentence is on both parties' cards and in the verification drawer, in
these words:

> You haven't met \<name\> in person through Seal. \<Introducer\> has, and
> vouched for this connection.

A linked friendship is exactly as trustworthy as the introducer's judgment.
The UI says that, rather than implying a check the app did not perform.

---

## 2. The statement — `seal.introduce.v1`

Signed by the introducer's **device key** (Secure Enclave, already root-endorsed
— the same key and the same verification chain as every message, SDS §2).

```
commitment = SHA256(
      "seal.introduce.v1"                       ← 17 bytes, ASCII, NOT framed
   ‖  u32be(len) ‖ introducerRootHash utf8      ← 64 hex chars → 4 + 64
   ‖  u32be(len) ‖ partyARootHash     utf8      ← 4 + 64
   ‖  u32be(len) ‖ partyAPublicKey              ← P-256 raw → 4 + 64
   ‖  u32be(len) ‖ partyBRootHash     utf8      ← 4 + 64
   ‖  u32be(len) ‖ partyBPublicKey              ← 4 + 64
   ‖  u32be(len) ‖ decimal(createdAtEpoch) utf8 ← e.g. "1756000000" → 4 + 10
)
```

Total preimage for real-world inputs: **371 bytes**. A reproducible test vector
and an independent second implementation live in
[`tools/introduction_vectors.py`](../tools/introduction_vectors.py) — the same
Python↔Swift cross-check discipline `mint_perks.py` uses for perk grants.

**Every variable-length field is length-framed.** `seal.endorse.v2` concatenated
two variable-length values without framing, so `(D, K)` and `(D‖K[0..<n],
K[n...])` hashed identically — one root signature authorising many splits, and
in practice a revoked endorsement that could be re-split until it no longer
byte-matched the revocation that killed it. This commitment carries **six**
variable-length values with four adjacent boundaries; unframed, one introducer
signature would speak for pairings naming hashes and keys that were never
signed. `tools/introduction_vectors.py` test 5 demonstrates the collision on
adjacent fields and shows framing removing it.

**The domain prefix is inside the hash** and is deliberately not framed — it is
a fixed-length constant, exactly as in `seal.receipt.v1` and `seal.endorse.v3`.
It is what stops a signature produced here from being replayed as a receipt, an
endorsement, or a friend ceremony. (The `signReceipt` lesson: a key that will
sign un-prefixed caller-supplied bytes is a signing oracle.)

**Parties are in canonical order** — `partyARootHash <= partyBRootHash` as
ASCII — so the introducer and both recipients derive byte-identical
commitments without agreeing on who is "first". The commitment hash is
therefore a stable id for the whole three-party flow, and every step is keyed
by it. That is what makes all of this idempotent and resumable.

**The timestamp is whole seconds rendered as decimal text**, for the reason
`CustodyReceipt.signedAtEpoch` gives: a `Date` round-trips through JSON as a
Double, and this value is rebuilt into a signed commitment on the verifier's
machine, where it must survive exactly and must not be able to carry a hostile
magnitude into a trapping conversion.

**No display names anywhere in the statement.** Names are metadata everywhere
in Seal (`IdentityManager.updateDisplayName`): not in a commitment, not in a
credential hash. Every surface resolves them from the directory or the
FriendStore, so there is never a second, unsigned source of truth for who an
introduction is about.

### 2.1 The acceptance — `seal.introduce.accept.v1`

Signed by the accepting party's device key.

```
accept = SHA256(
      "seal.introduce.accept.v1"
   ‖  u32be(len) ‖ introductionCommitment       ← 32 bytes
   ‖  u32be(len) ‖ accepterRootHash utf8
   ‖  u32be(len) ‖ decimal(acceptedAtEpoch) utf8
)
```

Naming the introduction commitment stops an acceptance being lifted into a
different introduction; naming the accepter stops it being presented as
somebody else's. Its own domain string keeps it distinguishable from the offer
it answers.

### 2.2 The confirmation

`IntroductionConfirmation` = the statement + both acceptances. **It carries no
signature of its own and does not need one**: every claim inside is already
signed by the party it speaks for, and the recipient re-verifies all three
against the directory before anything happens. A tampered confirmation is
either identical to the real one or fails a signature check.

It is deliberately **self-contained**, which is what makes the flow survive a
reinstall: a phone that lost its local state can complete the friendship from a
confirmation alone, because its OWN acceptance inside it verifies against its
own published device keys and nobody else can produce that signature.

---

## 3. What each recipient verifies

Run in `Introduction.checkOffer` (pure, synchronous — the caller supplies the
directory) plus `Introduction.introducerEligibility` (needs the FriendStore):

| # | Check | Failure |
|---|---|---|
| 0 | The message sender **is** the introducer named in the statement | refused |
| 0 | It arrived in a **1:1 chat** (an introduction names two people; TRUST.md D3 keeps edges private) | refused |
| **c** | **Our own root hash AND public key appear in the commitment exactly** | refused |
| — | The statement is < 30 days old and not future-dated beyond 24h skew | refused |
| **a** | **Signature chain: introducer's device key → published endorsement → introducer's root**, via the same `IdentityManager.verify` every inbound message passes | refused |
| **d** | **The counterpart's key in the statement matches the directory's published key for that root hash** | refused, in plain language, never guessed |
| **b** | **The introducer is an IN-PERSON friend of ours** (`Friendship.isInPerson`) | refused, with the anti-chaining sentence |
| — | Directory unreachable | **not** refused — "checking", retried by `ensureIntroductionsProgressed` |

"This failed a check" and "I couldn't run the check" are kept strictly apart,
for the reason `CardVerification` gives: they have opposite consequences and one
grey state covering both would be a lie in whichever direction it resolved.

### 3.1 How "introduction does not chain" is actually enforced

Not by hiding a button. **Each recipient independently requires that its OWN
edge with the introducer is in-person** before it will accept (check b, run in
the card AND again inside `ChatEngine.acceptIntroduction`).

A's device checks A—introducer. B's device checks B—introducer. Between them,
**both halves of "the introducer must be brass with both parties" are checked by
the only two devices that can know**. A linked friend who patches their client
to send introductions is refused by both recipients, independently, with no
cooperation between them and no trust in the introducer's UI.

`ChatEngine.sendIntroduction` re-checks the same rule on the introducer's side,
and the picker only lists in-person friends — but those are the two layers that
a modified client removes, so they are not where the guarantee lives.

### 3.2 In-person means "came from a ceremony", including auto-reciprocal

`Friendship.isInPerson` is `introduction == nil`. An `autoReciprocated` edge
(ForgeHandshake.swift — the other person ran the ceremony on their phone and
their device signed us our half) **counts as in-person**.

This is a deliberate call. Such an edge is weaker *as proof to this device*, but
it is still the record of a meeting that physically happened, not a remote
vouch. Excluding it would forbid introducing to exactly the person this feature
exists for: whoever taps THEIR key on somebody else's phone ends up holding
nothing but auto-reciprocal edges, so Mom — who taps her key on her son's phone
and on her sister's — would have been unable to introduce anyone.

**The consequence, stated honestly:** anything that can forge an auto-reciprocal
edge can reach introducer eligibility. See §6.3.

---

## 4. The flow

```
   INTRODUCER (Mom)                PARTY A (Nathan)              PARTY B (Linda)
   ───────────────                 ────────────────              ───────────────
   pick two in-person friends
   sign seal.introduce.v1
         │
         ├─ kind:"introduce" ─────► card: Accept / Not now
         │   (1:1 chat, E2EE)                │
         └─ kind:"introduce" ──────────────────────────────────► card: Accept / Not now
                                             │                            │
                                   sign accept.v1                sign accept.v1
                                             │                            │
   record ◄── kind:"introduce.accept" ───────┘                            │
   record ◄── kind:"introduce.accept" ─────────────────────────────────---┘
         │
   both present?
         │
         ├─ kind:"introduce.confirm" ─────►  verify all 3, force-refresh
         │   (statement + BOTH acceptances)  directory, create LINKED friend
         │                                            │
         └─ kind:"introduce.confirm" ───────────────────────────► same, other side
                                             │                            │
                                     fingerprint phrase          fingerprint phrase
                                     "call them and say it out loud"
```

**Transport: no new record type, and no GroupInvite-style record either.** All
three kinds ride the existing E2EE message pipeline the way `kind:"reaction"`
and `kind:"card"` do. This is not only the established pattern — the
GroupInvite and ForgeHandshake records live in the **world-readable public
database**, and an introduction names two people plus the fact that a third
vouched for them, which is precisely the who-knows-whom data
[TRUST.md](TRUST.md) **D3** ("counts public, edges private") says stays private.
The chat pipeline encrypts it; a public record would publish it.

The cost of that choice is stated in §5: a phone that loses its chain state
cannot re-read messages it never decrypted, so a reinstall mid-flow needs the
introducer to send again. A public record would have survived that — at the
price of publishing the family's social graph. Not close.

**Bubble vs non-bubble.** `introduce` is a **bubble** kind: it renders a card
and fires a push, exactly like a sealed card. (The brief called for a non-bubble
kind; a non-bubble kind renders nothing, and the same brief requires the offer
to render as a card in the chat. Bubble is the reading that satisfies both, and
it is what makes the offer reach a phone that isn't open.) `introduce.accept`
and `introduce.confirm` render nothing, like reactions. A confirmation is the
one non-bubble kind that still carries `recipients`, i.e. still pushes
(`ChatEngine.firesPush`): it is the moment a friendship comes into existence on
the other phone, at most twice per introduction — silent would mean a new family
member appears only when the app is next opened for some other reason.

**A decline sends nothing, ever.** The introducer sees "Not accepted yet" and
the card says, in the UI, that Seal does not report which of them has answered.
There is nothing useful an introducer could do with that information and plenty
of family they could do it to.

---

## 5. Partial states — the matrix

Everything is keyed by the commitment hash and every transition is idempotent.
`ensureIntroductionsProgressed` runs on every `refreshAll` (launch, foreground,
push) and on the open-chat poll, and is the single place that turns "what
landed" into "what this device still owes".

| Situation | What happens | Resolves by |
|---|---|---|
| One party accepts, the other is silent | Introducer's card: "Not accepted yet". No confirmation is sent. | The second acceptance, whenever it arrives — no deadline inside the 30-day window. |
| A party declines | `declinedAt` recorded locally. **Nothing is sent.** Card reads "Introduction dismissed. Nobody was told." | Never — the introducer can re-send, which re-opens the same card unless it was declined. A declined offer stays declined on that device. |
| Introducer offline after both accepted | Acceptances sit in their store. | The introducer's next `refreshAll` sends both confirmations. Latched only when **both** were shipped — half a confirmation is two people waiting on each other forever. |
| A party is offline when the confirmation is sent | The message record is durable (deterministic name, never deleted) and their chain will read it on the next refresh. | Next refresh. |
| Acceptance never reached the introducer (send failed with nothing queued) | The party's store still knows it accepted. | `resendAcceptanceOnce` — one nudge per launch, no sooner than 10 minutes after accepting. Bounded on purpose: a permanent retry queue for a message that is probably already delivered is invisible chatter. |
| Directory unreachable when an offer lands | Offer stored as "checking…", **not** refused. | `retryUncheckedOffers` re-runs the checks and updates the card in place — the message itself can never be re-read, because the ratchet has already destroyed its key. |
| Confirmation arrives twice | `record`/`recordAcceptance` are upserts; `materialize` no-ops once `completedAt` is set. | — |
| Offer arrives twice, or is re-sent after a TTL burned the card | One card per commitment per chat: a duplicate is dropped, a re-send after the card is gone renders again. | — |
| Counterpart is **already a friend** | `materialize` marks the flow complete and **writes nothing**. A replayed confirmation can never downgrade a brass friendship to silver. | — |
| Counterpart's directory key changed between offer and confirmation | `materialize` refuses, says so in plain language, writes no friendship. | Ask to be introduced again. |
| The introducer was un-forged between offer and confirmation | `materialize` refuses (check b again). Un-forging someone is deliberate and should stop what they were carrying. | — |
| A party reinstalls **after** accepting | Chain state is gone, so old messages are unreadable — but a confirmation that arrives later is self-contained, and their own acceptance inside it verifies against their published devices. | The confirmation completes it with no local state. |
| A party reinstalls **before** accepting | Offer and store are gone with the keychain; the message can't be re-read. | The introducer's card offers **Send again**, which re-ships the identical signed statement (same commitment, so nobody ends up holding two offers). |
| Introducer reinstalls mid-flow | Their store is gone; acceptances already delivered are unreadable. Nothing completes. | Introduce again — a new timestamp is a new commitment, and both parties see a fresh card. |
| Chat has disappearing messages on | The card burns with everything else. Introductions are **not** exempt: the drawer promises disappearing messages disappear, and a message class that quietly outlives that promise is how honest copy becomes dishonest (CARDS.md made the same call). | **Send again** re-renders the card; state was never in the bubble. |
| Both accept but the friendship already exists as linked | No-op. | — |

---

## 6. Threats

### 6.1 What a malicious introducer CAN do

**Introduce an impostor they control.** Mom mints a second identity, calls it
"Aunt Linda", forges with it in person (she is holding both keys), and
introduces it to her son. Every check passes: the signature chains to Mom, the
key matches the directory, both parties accept. Nathan ends up linked to an
identity Mom operates.

This is not a bug to be closed — it is the honest boundary of what a vouch can
prove. The mitigations, in order of load-bearing-ness:

1. **The tier.** The friendship is silver-link, never brass, everywhere: friend
   list, chat header, colony bar, verification drawer. It never reads
   "Verified". `ForgeRank` (TRUST.md §5.1) weights vouched edges at a fraction
   of a real ceremony and decays them if they are never upgraded by a meeting,
   so this cannot be farmed into reach.
2. **The provenance line.** "Introduced by Mom · 25 Aug 2026", on the friend,
   permanently, next to the sentence saying you have not met them. The claim is
   attributable and it stays attributed. A vouch that goes wrong is traceable to
   exactly one person's judgment.
3. **The fingerprint phrase step.** After accepting, the card opens the phrase
   with "call them — a phone or video call — and say this out loud". This is the
   one check that catches an impostor, it is a human check, and the app says so
   rather than pretending it did it.
4. **It costs a real edge.** The introducer must be brass with the victim, which
   in Seal means they met. This is not a remote attack.

### 6.2 What a malicious introducer CANNOT do

- **Forge either acceptance.** They are device-signed by each party and verified
  against the directory. No acceptance, no friendship.
- **Substitute a different key for a real person.** Check (d) compares the
  statement's key against the directory's published key for that root hash and
  refuses on mismatch, with `materialize` repeating the comparison against a
  forced refresh at write time.
- **Replay an introduction at a third party.** Check (c) requires the
  recipient's own root hash *and* public key to appear in the commitment; a
  statement made for someone else can never name a new party without a fresh
  signature.
- **Chain a vouch.** A linked friend is refused by both recipients (§3.1).
- **Downgrade an existing friendship.** `materialize` never overwrites an
  existing friend record.
- **Learn who declined.** Nothing is sent on a decline.
- **Reach into a group.** Offers are refused outside 1:1 chats.

### 6.3 Pre-existing, NOT introduced here, and now load-bearing

`ForgeHandshakeService.check` accepts any correctly-signed handshake naming this
device's owner, and creates an `autoReciprocated` friendship from it — **without
any evidence that a ceremony happened**. Any registered identity can therefore
add itself to a stranger's friend list today, before this feature exists.

Introductions do not create that hole, but they extend what it reaches: an
auto-reciprocal edge counts as in-person (§3.2), so a forged one confers
introducer eligibility. The attacker still appears as a stranger in the victim's
Circle, which is noisy, and they must still get the victim to accept.

**The fix, for a separate pass:** A already holds `friendship.attestation` —
B's own root assertion over `friendChallenge(A, B, nonce)`. Putting that
assertion inside the `ForgeHandshake` record would let B verify **its own root
signature over a challenge naming both parties**, which a stranger cannot
produce. That closes it properly and cheaply. It changes the handshake wire
format (old handshakes carry no assertion), so it is the same "family updates
together" break as `wrapToAll` and the backup-key authority set, and it belongs
in its own commit with its own testing.

### 6.4 Residual, accepted

- A linked friend can invite you to a group (`checkInvites` asks
  `friendStore.isFriend`, which is true for linked). That is consistent with
  being a friend; the group's verification drawer shows their tier.
- The counterpart identity cached on an offer is a snapshot (stripped of
  `backupCredentials`, per `completeRegistration`'s reasoning). Names shown
  before completion come from that snapshot or the directory cache; the
  friendship written at completion uses a freshly fetched identity.
- A device that never comes online again leaves an introduction pending
  forever. There is no expiry beyond the 30-day acceptance window, and nothing
  is ever deleted from the store — at family scale that is a handful of
  entries.

---

## 7. Ops checklist

**None.** No new CloudKit record type, no new field on an existing type, no
schema deploy, no security-role change, no subscription change. Introductions
ride `Message` records that already exist, with `recipients` set exactly as a
normal message sets it, so the existing push subscription carries them.

The only new local storage is a keychain blob, `seal.introductions.<ownerHash>`,
wiped by `ChatEngine.wipe` alongside chats and messages — so sign-out and
delete-identity already clear it.

**Wire compatibility:** a build without introductions decodes the payload fine
(unknown keys are ignored), falls through to `default:`, and renders
`payload.text` — which is why the offer's `text` carries "\<name\> would like to
introduce you to \<name\>. Update Seal to accept." rather than being empty. Its
acceptances and confirmations would render as empty bubbles on such a build,
the same harmless behaviour reactions had before 6/13. Family updates together.

---

## 8. Files

| File | Role |
|---|---|
| `Seal/Introductions/Introduction.swift` | Domains, framed commitments, the three statements, the pure checks, `IntroductionStore` |
| `Seal/Chat/ChatEngine.swift` | Three payload kinds; send / accept / decline / resume / materialize |
| `Seal/Models/Models.swift` | `Friendship.introduction` + `Friendship.isInPerson` |
| `Seal/Views/IntroductionCard.swift` | The card in the chat, all nine states, and the fingerprint step |
| `Seal/Views/IntroduceSheet.swift` | Picker + "exactly what will be shared" confirmation |
| `Seal/Views/IdentityRing.swift` | Silver dashed ring + `link` glyph |
| `Seal/Views/ChatView.swift` | Card rendering, drawer provenance, "Introduce … to" row |
| `Seal/Views/FriendsView.swift` | Linked row styling, "Introduce … to" menu item |
| `Seal/Views/ChatsView.swift`, `Seal/Views/SealMascot.swift` | Linked ring in the chat list and colony bar |
| `Seal/DemoFixtures.swift` | Aunt Linda (linked), Uncle Ray (pending offer), Mom (introducer) |
| `tools/introduction_vectors.py` | Independent implementation + test vector for the commitment |
