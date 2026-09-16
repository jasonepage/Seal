# The release: how sealed envelopes open

**Version:** 1.0 · **Date:** 2026-09-15 · **Code:** `Seal/Estate/ReleaseMachine.swift` · **Tests:** `Seal/SelfTest/ReleaseMachineTests.swift`

## 1. The machine

Nine states. A pure function of the record and the clock.

```
active ──(silence exceeded)──► overdue ──(claim)──► warning ──(warningDays)──► grace
                                                                                  │
                          ┌──────────────────────────────────────(graceDays)──────┘
                          ▼
                       claimOpen ──(M distinct taps)──► authorized ──(shares combined)──► released
                          │
   any live state ──(owner heartbeat or cancellation)──► cancelled ──(silence again)──► overdue
   any live state ──(custodian objection)──► objected ──(pause: withdrawn / veto: new claim)
```

"Live" means warning, grace, claimOpen, authorized or objected: a claim
exists and has not been stopped.

## 2. The rule, and the defaults

| Parameter | Choices | Default |
|---|---|---|
| `silenceDays` | 30, 90, 180, 365 | 90 |
| `warningDays` | 1 or more | 21 |
| `graceDays` | 0 or more | 14 |
| `threshold` | 1 to N | 2 (with 3 custodians) |
| `objectionBehavior` | pause, veto | pause |

## 3. Transitions, exactly

- **active to overdue.** `now - lastHeartbeat > silenceDays`, strictly. With
  no heartbeat ever, the estate's creation is the anchor. A custodian phone
  that observes this posts a signed `silenceObserved` once a day. That is
  evidence; it changes nothing.
- **overdue to warning.** A custodian posts a signed `releaseClaimed`. A
  claim posted before the silence period has fully elapsed is **ignored**,
  not honoured with a shorter countdown. Every other custodian is notified
  by the estate subscription the same day. The owner is warned daily.
- **warning to grace.** `warningDays` (plus any paused time) elapse.
- **grace to claimOpen.** `graceDays` more elapse.
- **claimOpen to authorized.** M distinct custodians each post an
  `authorization` carrying a WebAuthn assertion by their root credential over
  `SHA256(framed("seal.release.authorize.v1", [estateID, epoch, claimID,
  recordHeadDigest]))`, plus their Shamir share re-wrapped to the claimant's
  devices. A tap made before the claim opened, or during a pause, does not
  count. A second tap by the same custodian does not count.
- **authorized to released.** The claimant opens the shares on their phone,
  checks each against the commitment the owner signed (a bad share names its
  custodian), combines, checks the result against the Estate Key commitment,
  and posts `released` with the Estate Key in the clear.
- **any live state to cancelled.** The owner posts a `cancellation`, or simply
  a `heartbeat` dated at or after the claim. The app posts both. Cancelled is
  shown until the owner has been silent for a full period again, at which
  point the estate is overdue and a new claim may open.
- **any live state to objected.** A custodian posts an `objection` naming the
  claim. With `pause`, every later deadline slides by the time the objection
  stays open, and withdrawing it resumes the countdown. With `veto`, the claim
  is dead; withdrawing changes nothing; a new claim starts from the beginning.

## 4. The asymmetry

Cancelling requires the owner's phone and, if the app lock is on, Face ID.
Nothing else. It must never require the hardware key, because a living person
who lost their key would otherwise be declared dead. Releasing requires M
physical keys, each tapped over a challenge naming this exact claim and this
exact record head, so a tap cannot be replayed into another claim or another
history.

## 5. Time

There is no server running this clock. The owner's phone writes a signed
heartbeat on every launch and foreground. The custodians' phones read the
record and drive the machine. Each heartbeat, claim, tap, cancellation and
release is sent to an RFC 3161 timestamp authority (only its digest leaves the
phone) and the token comes back into the record. The feed prefers the token's
`genTime` over the actor's clock, so "the last heartbeat really was 100 days
ago" is a statement about an authority's clock, not a phone's.

Custodian phones are woken by a CloudKit subscription on the estate's events
and by background refresh. Punctuality is not required. Correctness is: every
decision is recomputed from the whole record every time.

The clock is injected everywhere (`Seal/Time/Clock.swift`). Nothing calls
`Date()`. The debug Time Travel screen swaps in a simulated clock and advances
it by days, so the entire machine runs end to end in ninety seconds. The
self-test `release.ninetySecondRun` does exactly that.

## 6. What a custodian's phone checks before believing an event

1. The event's device signature verifies.
2. That device is endorsed by the root the event names, verified through the
   pinned root key (the owner's, from the ceremony; a fellow custodian's,
   from the owner's signed epoch statement).
3. The actor may write that kind: owner kinds for the owner, custodian kinds
   for hashes named in the owner's newest epoch statement, nobody else.

Anything that fails is dropped before the feed ever sees it.

## 7. Rotation

Removing a custodian, adding one, or changing the threshold means a new
epoch the next time the owner seals: fresh Estate Key, fresh shares, fresh
owner wraps, and each table's small inner ciphertext re-encrypted under the
new key. Tables and blobs are never touched. A claim names its epoch; a claim
against an old epoch is still valid against that epoch's material, so
rotating during a claim does not make the claim disappear. The owner's
heartbeat does that.

## 8. Custody confirmations are not taps

Since 2026-09-16 a custodian's phone asks them, once per
`custodyConfirmMonths` (default 12, set by the owner in the rule), to tap
their key and say they still have it. That writes a `custodyConfirmed`
event: an assertion over `seal.custody.confirm.v1` naming the estate, the
epoch and the record head, and nothing else. It is a receipt. The feed
ignores it, the machine never sees it, the challenge domain is different
from `seal.release.authorize.v1`, and it carries no share. Three custody
confirmations during an open claim leave the state exactly where it was
(`custody.neverCountsTowardRelease`). The owner's home screen reads them to
say when each key holder last confirmed, and to name the one to ask.

## 9. Open on a date (built 2026-09-16)

A letter for a child's eighteenth birthday. There is no server and no
trusted clock, so a date cannot open anything and the design does not
pretend it can. The honest version, which is what is built:

- The envelope carries `openNoEarlierThan` inside its sealed payload.
- It still needs the full release: the silence, the warnings, the grace
  and M key taps. Nothing in the machine reads the date. The key table
  and the blobs are exactly what they would be without it.
- After the release, the recipient's phone shows the title and "opens on
  <date>", and nothing else, until that day by its own clock.

What the app says to the owner, on the card: the date does not open
anything by itself; it is not a lock; there is no clock everyone can
trust, so the recipient's phone honours it the way a person honours a
wish; someone determined, with the capsule and a computer, could read it
sooner. That is the whole truth and PRODUCT.md section 7 stays true.

The stronger version, a real time lock, would need a third party that
releases a key on a date. That puts a stranger into the promise. Not
built, and not planned unless a customer asks for it with the trade-off
understood.

## 10. The owner is alive but cannot act (built 2026-09-16 as two estates per identity)

**Built the same day Jason approved it, as the first option below.** The
app calls it "Bills and medical": a segmented control at the top of the
Envelopes and Keys tabs switches between the letters and the urgent set.
The urgent set is a second `Estate` run by a second `EstateEngine`
(`slot: .urgent`) with its own local storage, its own key holders, its
own rule (default: the shortest silence the machine allows, one week of
warnings, no grace), its own Estate Key, shares, tables and log. The
owner's heartbeat is written to both on every open. A key holder's phone
sees it as a separate estate from "Nathan (bills and medical)". Nothing
in the key hierarchy is shared, so a release of the urgent set opens
none of the letters. The design discussion that led here follows.

The case: a stroke. The owner is alive, the heartbeat stops because
nobody opens the app, and the family needs the bills and the medical
information now, not the letters, and not in 90 plus 21 plus 14 days.

The idea: a second, smaller envelope set marked "bills and medical" with
its own shorter rule (say 14 days of silence, 3 of warnings, 0 of grace,
and the same key holders or a subset), while the personal letters keep
the full rule.

What it touches. The rule is per estate and the Estate Key is per estate.
A shorter rule for some envelopes means one of:

- **Two estates per identity.** The cleanest: a second `Estate` with its
  own policy, epoch, Estate Key, shares and tables, owned by the same
  identity. The machine, the feed, the engine and every screen assume
  one estate per identity (PRODUCT.md section 3, `EstateStore.load`).
  Everything that loads an estate by owner hash would take an estate id
  instead. Large, mechanical, no cryptographic novelty. Key holders see
  two estates from the same person, each with its own claim and taps.
- **Two policies in one estate.** One Estate Key, two rules, tables
  tagged "personal" or "urgent". But the Estate Key is one key: once M
  taps release it under the urgent rule, every table's inner layer is
  open, and the only thing keeping the letters closed is the recipient's
  phone declining to show them. That is section 9's weakness applied to
  the whole vault. It breaks PRODUCT.md section 7 for the letters.
  Rejected.
- **Two Estate Keys in one estate.** One log, two rules, two sets of
  shares and commitments in the epoch statement, each table wrapped
  under one of the two keys. Sound, about half the surgery of two
  estates, but `EpochBody`, `EpochKeyMaterial`, the share wrapping, the
  claim and authorization bodies and the capsule format (a version bump)
  all change. Cryptographic surface touched, without a compiler.

The question the design cannot answer for the owner: who gets the
urgent set. A stroke patient's spouse needs the bills; the spouse is
usually also a key holder. "The spouse can open the bills after two
weeks of silence" is close to "the spouse can open the bills". The app
would have to say that.

**Recommendation:** two estates per identity, built as "a second set of
envelopes with its own rule", in the batch after this TestFlight round.
Stop here. The human decides.

## 11. The owner deletes their account (built 2026-09-16, UNCOMPILED)

The delete screen asks one question when anything is sealed: keep the
envelopes for the family, or cancel them. The owner's phone then writes one
signed `ownerDeparted` entry (`{ keepEnvelopes, departedAtEpoch }`) into
each envelope set's record, before the delete marker and the wipe.

- **Keep.** The machine is unchanged. Like every owner entry it is the
  owner's last sign of life, so a claim can open once the silence period
  has passed from it, and the warnings, grace and M taps still apply. Key
  holders see the earliest claim date and the earliest opening date.
- **Cancel.** The owner's phone deletes every sealed blob it uploaded
  (epoch material, key tables, contents). `EstateEngine` refuses claims,
  taps and releases on every key holder's phone. A cancel beats a keep.
- **A later heartbeat voids the entry**: the delete did not finish.
- A release that already happened is not undone (section 4 of PRODUCT.md,
  "Undoing a release").
- `ReleaseMachine` does not read the kind. `ReleaseFeed` lists it with the
  kinds it passes over. `DepartureRules.swift` holds the meaning.
- The owner's record stays readable for history: the delete flips the
  tier but keeps the device endorsements, and key holders read it through
  `fetchIdentityForHistory`, trusted only via the pinned root key. Before
  this, the record froze on every other phone the day the owner left.

## 12. Known judgement calls, for review

- After a **veto**, a new claim may open immediately if the owner is still
  overdue; the objecting custodian must veto again. An alternative (the
  objector must withdraw before any new claim) would let one custodian block
  forever. Not decided in the brief; this was the smaller assumption.
- Taps are counted against the pause **as it stood at the moment of the
  tap**. A pause that starts after a valid tap does not invalidate it.
- A **released** event wins over a later heartbeat. The key is out.
- Authorization assertions require user presence but **not user
  verification** by default, because the UV policy is `.preferred` and a
  PIN-less key cannot produce UV. `WebAuthnAssertion.verify(with:requireUserVerification:)`
  exists for a policy that wants it.

## 13. A rule per envelope (designed 2026-09-16, NOT BUILT, decision made)

Jason's ask, in his words: move the rule into each envelope, so that when
you are writing the letter, the steps, the secrets, the photos and the
voice, you can also choose when that envelope opens; and get rid of the
Letters versus Bills and medical picker, so envelopes live on the
Envelopes tab and keys live on the Keys tab.

Decided with Jason the same day: each rule has its own key holders; at
most three rules per person; design first, then build, then the tour.

### 13.1 The one thing this design cannot pretend

A rule is not a setting on a letter. A rule is the lock on a box of keys.
Every envelope's key sits in a box (the Estate Key), and the rule is what
the key holders have to do to open that box: the silence, the warnings,
the grace, and M taps. Once the box is open, every key in it is out. A
rule "per envelope" with one box is a rule the app could only pretend to
honour, and section 10 rejected exactly that. So:

**An envelope picks a rule. Envelopes that share a rule share a box.
Each rule is its own box, with its own Estate Key, shares, key holders,
claim and taps.** This is what Bills and medical already is under the
hood (`EstateEngine.Slot.urgent`: a second engine, second storage, no
shared key material). This design takes the two fixed slots and makes
them a short list of named rules. Nothing cryptographic changes.

### 13.2 What the owner sees

*Amended after step 1 was on a phone (Jason, 2026-09-16): the Keys tab
is about people, not rules. Rules live on each envelope's "When it
opens" card and under "Your rules" in the Envelopes menu; the Keys tab
lists each person who holds a key, with the rules they hold it for.
The paragraphs below describe the first cut and are kept for the
reasoning.*

- **Envelopes tab.** One inbox with every envelope, no picker. When more
  than one rule exists, each row carries a small tag with its rule's
  name. The Seal bar seals every box that has something unsealed, one
  payment check, one pass.
- **The editor.** A sixth card, "When it opens", after the voice card.
  It shows the rule this envelope is on ("Your rule: after 90 quiet days,
  21 days of warnings, 14 more, any 2 of 3 keys") and lets the owner pick
  another rule or "Make a new rule" (up to three). Picking a different
  rule moves the envelope into that rule's box, and the card says so:
  "This moves the envelope to a different set of keys. Both sets need
  sealing again." "Open on a date" (section 9) stays on this card and
  works with any rule; it is a wish the recipient's phone honours, not a
  lock.
- **Keys tab.** One section per rule: its name, its numbers, its key
  holders with their yearly standing, its seal state, and its own "The
  rule" button. "Add a rule" at the bottom, hidden at three. Rename from
  the section header. A rule can be deleted only when it holds no
  envelopes and has never been sealed, or after its envelopes have been
  moved; the button says why when it is off. "Set up with my partner"
  stays where it is and works on the default rule.
- **Names.** The default rule is called "Your rule" until renamed. A new
  rule starts named "Sooner", with the short numbers Bills and medical
  uses today (the shortest silence allowed, 7 warning days, no grace),
  because that is the one people ask for. The owner can name it anything.
- **Cost, said on screen.** When making a second or third rule: "Every
  rule is its own set of keys. Your key holders tap once per rule, and
  each rule shows on their phone as its own line."

### 13.3 What a key holder or recipient sees

Unchanged in shape. Each rule's box arrives on their phone as its own
estate, named by the invite's `ownerName`: the default rule is "Karen";
any other is "Karen (Sooner)", the way "Karen (bills and medical)" works
today. `Slot.ownerLabel` becomes `RuleSlot.ownerLabel`, the suffix is the
rule's name. No model change, no CloudKit change. `GuardedEstateView`,
the For others tab, the claim, the taps and the capsule are untouched.

### 13.4 What changes in code

- `EstateEngine.Slot` (two cases) becomes `RuleSlot: Codable, Hashable
  { id: String; name: String }`. `id` is `""` for the default rule and
  `"urgent"` for the one Bills and medical made, so **no storage moves on
  any phone**; new rules get `"r2"`, `"r3"`. `storeHash` is unchanged in
  shape: the identity hash for `""`, `"\(id).\(hash)"` otherwise.
- `RuleBook` (new, `Seal/Estate/RuleBook.swift`): the list of this
  identity's rules, keychain JSON at `seal.rules.<hash>`, with `add`
  (refuses a fourth), `rename`, `remove` (refuses while the engine has
  envelopes or a published epoch), and the migration: on first load, if
  an `urgent` estate exists on disk, the book lists it as a rule named
  "Bills and medical"; otherwise the book holds only the default.
- `ContentView` builds one `EstateEngine` per rule in the book, held in
  an observable `EstateEngines` (the default first). `HomeView`
  heartbeats every engine and schedules `OwnerNotices` per engine, as it
  does for two today. `EstateHomeView` takes `engines` instead of
  `lettersEngine` and `urgentEngine`; `estateEngine` for the inbox is
  gone, replaced by a flat list of `(engine, envelope)` pairs; `runSeal`
  loops the engines that need sealing after one purchase check.
- The editor gets the "When it opens" card. Moving an envelope:
  `EstateEngines.move(envelopeID, from:, to:)` = `removeEnvelope` on the
  source engine and `updateEnvelope` (with the same content, media
  re-filed under the new `storeHash`) on the target, and, if the
  recipient is not yet in the target estate, `addRecipient` there. Both
  engines mark themselves unsealed.
- `EstateEngine.wipe` iterates the book's ids plus `""` and `"urgent"`.
  `RuleBook.wipe` joins `wipeLocalAndEngines`.
- The widget keeps showing the default rule's numbers (`shareCheckIn`
  guards on `slot.id == ""`).
- `FriendStore.refreshGone` and the unresponsive key holder box take the
  full engine list, as they take two today.
- `PolicyView` is unchanged; it edits one engine's estate.

Untouched: `ReleaseMachine`, `ReleaseFeed`, `EstateLogVerifier`, the key
hierarchy, `EstateEvent`, the capsule format, every CloudKit record type,
the project file.

### 13.5 Tests (`RuleBookTests`, registered)

Loads an empty book as the default rule only; lists `urgent` as "Bills
and medical" when that estate exists; refuses a fourth rule; refuses to
remove a rule with envelopes or a published epoch; `ownerLabel` is the
bare name for the default and "Name (Rule)" otherwise; `storeHash` for
`""` and `"urgent"` equals what the code produced before this change;
moving an envelope keeps its letter, steps, secrets and media and leaves
nothing behind in the source; wipe covers every id in the book.

### 13.6 Order of building

1. `RuleSlot`, `RuleBook`, `EstateEngines`, N engines in `ContentView`
   and `HomeView`, the Keys tab as one section per rule, the picker
   removed, the inbox flat with rule tags, seal-all. Envelopes keep their
   rule; nothing moves yet. Build. Check a phone that already has a
   Bills and medical set: it must show as a rule with its envelopes.
2. The editor card, "Make a new rule", moving an envelope. Build. Move
   one envelope, seal, and check on Mom's phone that she sees two lines
   from you and that the moved envelope opens under the new rule with
   Time Travel.
3. Tests, GOTCHAS, HANDOFF, PRODUCT.md section 3 (the word "rule" gets
   "one or more per owner; each is its own box of keys"), and this
   section marked built.

### 13.7 Judgement calls, for review

- Three rules, not more. Each is a round of taps for the family.
- Own key holders per rule. A rule with no key holders cannot seal, and
  the Keys tab says so under that rule.
- Moving an envelope unseals both boxes. There is no cheaper honest
  version: the envelope's key is in the old box and must come out.
- The default rule keeps the bare owner name on other phones, so nothing
  changes for anyone who set up before this.
