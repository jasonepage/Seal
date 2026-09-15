# Conversion brief: Seal becomes a sealed-envelope legacy product

You are working in `~/Documents/GitHub/Seal`, an iOS app, Swift and SwiftUI,
iOS 26.5+, no backend, CloudKit transport. About 16,000 lines across 51 Swift
files, 37 commits.

Your job is to convert it from a private messenger into a sealed-envelope
legacy product, in place, in this repo, keeping the cryptographic engine and
replacing the product surface.

Read these before you touch anything, in this order: `HANDOFF.md`,
`docs/GOTCHAS.md`, `docs/SDS.md`, `docs/RECORD.md`, `docs/CARDS.md`. Most of
what is in GOTCHAS cost a day to find and looks like a different problem from
the outside.

---

## 1. What the product becomes

Today Seal is a messenger where two people who met in person can send each
other things that must not reach the wrong hands.

Tomorrow Seal is this: **a person writes a small number of sealed envelopes,
hands physical security keys to people they trust, and sets the rule for how
those envelopes open after they are gone.**

An envelope holds a letter, a few photos, a voice recording, and secrets. The
secrets are the reason people buy it: passwords, where the safe deposit key is,
the combination, the seed phrase, the thing they never told anybody.

Nobody, including Apple and including us, can open an envelope early. It takes
a threshold of custodians physically tapping their keys, after a long silence
from the owner, after weeks of loud warnings the owner can stop with one tap.

The user story to build against:

> A 58 year old man writes four envelopes on a Sunday night. One to his wife
> with every password and where the documents are. One each to his two kids,
> letters. One to his business partner with the domain registrar login. He
> hands a key to his wife, one to his brother, one to his attorney. The rule is
> any two of those three, after 90 days of silence and three weeks of warnings.
> He spends two hours. If he opens the app once during those three weeks, it
> all stops cold.

Why this and not a messenger: Seal cannot be used by one person. The handoff
document says it plainly, ten pairs and not ten people. This product is useful
the moment one person finishes setup, and the second person does nothing for
years. Same crypto, same ceremony, far better adoption.

The name does not change. A seal is wax on a letter the wrong person must not
open, and breaking one is a ceremony. Keep the relying party `sealmessenger.com`,
the bundle `io.github.jasonepage.Seal`, team `8C4BM6A82T`, and the CloudKit
container. Changing the relying party identifier invalidates every registered
credential. Do not do it for a word.

---

## 2. What you keep, and why

These are the reason we are converting instead of starting fresh. Do not
rewrite them. Extend them.

- `Seal/Identity/` minus the perk files. Root identity, device endorsement,
  backup credentials, revocation.
- `Seal/Crypto/`. `HybridKEM` (X25519 plus ML-KEM-768 into one derivation),
  `WebAuthnParsing`, `SenderChain`, `FingerprintPhrase`. The post-quantum
  wrapping was overkill for chat and is exactly right for a vault that gets
  decrypted decades from now.
- `Seal/Ceremony/`. The in-person hardware key ceremony is the single hardest
  thing in this product and it already works on real hardware.
- `Seal/Record/`. The signed hash-chained event record and the RFC 3161
  trusted timestamps. The timestamps are load bearing in the new product, see
  section 5.
- `Seal/Receipts/CustodyReceipt.swift`. A two-sided signed handover becomes the
  record of a key being handed to a custodian.
- `Seal/Sync/`. `SyncEngine`, `BackupDirectory`.
- `Seal/Cards/SealedCard.swift`. A sealed card carrying a payment address is
  already ninety percent of a secret field inside an envelope. Reuse it, do not
  rebuild it.
- `Seal/Theme/`, `Views/IdentityRing.swift`, `Views/SealMascot.swift`,
  `Views/RegistrationView.swift`, `Views/BackupKeysView.swift`,
  `Views/ForgeOnboarding.swift`, `Views/ForgeLogView.swift`,
  `Views/ProfileView.swift`, `Views/RecordView.swift`, `Views/ReceiptsView.swift`.
- `Seal/Theme/ParentMode.swift`. Bigger text and plainer wording matters more
  here than it did in a messenger. Half the users are over sixty.

---

## 3. What you remove

Use `git rm` so the history keeps it. If deletion is blocked in your
environment, `mv` the files into `retired/` and say so in the commit.

- `Seal/Chat/ChatEngine.swift`
- `Seal/Camera/CameraController.swift`
- `Seal/Introductions/Introduction.swift`
- `Seal/Views/ChatView.swift`, `ChatsView.swift`, `CameraTab.swift`,
  `NewGroupView.swift`, `IntroduceSheet.swift`, `IntroductionCard.swift`
- `Seal/Identity/PerkAuthority.swift`, `PerkRedeemer.swift`,
  `Seal/Views/RedeemPerkView.swift`, `tools/mint_perks.py`
- `docs/INTRODUCTIONS.md` and `docs/COLDSTART.md` move to `docs/archive/`

Do this at phase 7, not at the start, so the app keeps compiling while the new
engine lands.

Never commit `tools/founder_private.pem`. It is correctly gitignored today.
Keep it that way.

---

## 4. The key hierarchy to add

Build on the existing hierarchy, do not replace it. The root credential still
endorses Secure Enclave device keys, and device keys still certify the hybrid
KEM bundle. Add these layers above the existing wrapping.

```
Envelope Content Key   random 256 bit, AES-256-GCM, one per envelope
    wrapped by
Estate Key             one per owner per epoch, wraps the Key Table
    reachable two ways
    ├─ wrapped directly to each of the OWNER's own devices (owner always reads)
    └─ split by Shamir into N shares, threshold M
           each share wrapped to one custodian via the existing HybridKEM
```

The Key Table is a small encrypted file mapping envelope identifiers to their
content keys plus the encrypted envelope metadata (title, recipient, reveal
position). It stays kilobytes even with large media, which is what makes
rotation cheap.

**Rotation and revocation.** Removing a custodian means a new epoch: fresh
Estate Key, re-encrypt the Key Table, re-split, re-wrap. The media blobs are
never touched. Reuse the epoch machinery that already exists for group
membership changes.

**Shamir.** This is the only genuinely new cryptography and it is small.
Implement threshold secret sharing over GF(256) as its own file with its own
test vectors. Store a SHA-256 commitment of each share and of the recovered
secret in the signed record, so a custodian submitting a bad share is
identified rather than causing a silent failure. Do not invent anything else.
Do not write a new AEAD, a new key derivation, or a new signature scheme.

**Recipient isolation.** Each recipient gets their own encrypted Key Table.
A custodian must not learn the number of envelopes, the titles of envelopes, or
the existence of envelopes not addressed to them, before or after release. An
owner must be able to write an envelope to a person the rest of the family does
not know about, and nothing in the record may reveal that it exists.

---

## 5. The release state machine

This is the core of the product. Build it as a pure Swift value type with no
input or output and no direct clock access, in its own file, fully unit tested.
Everything else hangs off it.

**States:** `active`, `overdue`, `warning`, `grace`, `claimOpen`, `authorized`,
`released`, `cancelled`, `objected`.

**Policy parameters,** owner chosen with these defaults: `silenceDays` (30, 90,
180 or 365, default 90), `warningDays` (21), `graceDays` (14), `threshold` M of
N custodians, and `objectionBehavior` (pause or veto, default pause).

**Transitions.**

- `active` to `overdue`: now minus last heartbeat exceeds `silenceDays`. Any
  custodian device that observes this posts a signed, timestamped observation.
- `overdue` to `warning`: a custodian opens a signed `ReleaseClaim`. Every
  other custodian is notified the same day. Warnings go to the owner on every
  channel, daily, for `warningDays`.
- `warning` to `grace`: `warningDays` elapse with no heartbeat and no
  cancellation.
- `grace` to `claimOpen`: `graceDays` elapse.
- `claimOpen` to `authorized`: M distinct custodians each produce a WebAuthn
  assertion over a challenge binding `(estateID, epoch, claimID, recordHeadHash)`.
  Reuse the existing challenge construction pattern.
- `authorized` to `released`: shares combine on the claiming device, the Estate
  Key is recovered, envelopes open in the owner's reveal order.
- Any state to `cancelled`: the owner posts a signed cancellation, **or the
  owner simply produces a heartbeat.** A heartbeat beats everything.
- Any state to `objected`: a custodian posts a signed objection.

**The asymmetry is deliberate and you must preserve it: stopping a release is
easy, starting one is hard.** Cancelling requires the owner's phone and Face ID
and nothing else. It must never require the hardware key, because a living
person who lost their key would otherwise be declared dead. Releasing requires
M physical keys.

**There is no server running this clock.** The owner's phone writes a signed
heartbeat with a trusted timestamp on every launch. The custodians' phones
watch that record and drive the machine. The RFC 3161 timestamps already in
`Seal/Record/TimestampService.swift` are what make "the last heartbeat really
was 100 days ago" provable rather than a claim from somebody's phone clock.
Wake custodian devices with CloudKit subscriptions and background refresh.
Punctuality is not required. Correctness is.

**The clock is injected everywhere.** Define a `Clock` protocol with
`SystemClock` and `SimulatedClock`. Nothing anywhere calls `Date()` directly.
Ship a debug-only time travel control that advances the simulated clock by any
number of days, so the entire machine runs end to end in ninety seconds. This
is not a nice to have. Without it the product is untestable.

---

## 6. Four security fixes, before anything else

`docs/SDS.md` §11 already lists these under "Known, NOT introduced by FR-3". In
a messenger they are bad. In a vault holding somebody's seed phrase they are
disqualifying. Fix them in phase 1, each with a test.

1. **Nothing pins a friend's root public key at forge time**, so the
   directory's `publicKey` field is trusted on every fetch. Fix this first. If
   the directory can swap a key, the directory can swap an heir.
2. **`WebAuthnAssertion.verify` checks the ECDSA signature but not the relying
   party identifier hash, the user presence and user verification flags, or
   `clientData.type`.**
3. **`DeviceEndorsement.revokedAt` is unsigned but treated as authoritative**,
   so anyone able to write a record can un-verify every device on it.
4. **`seal.endorse.v2` concatenates two variable length values without length
   framing.**

---

## 7. The capsule export

The whole promise is that the archive outlives the company. CloudKit dies with
the Apple developer account, so CloudKit is transport and not the archive of
record. The archive of record is a file on each custodian's own disk.

Build `docs/CAPSULE.md` as a versioned format specification written for a
stranger, and `tools/verify_capsule.py` as a standalone verifier with no
dependencies beyond the Python standard library and one vetted crypto library.

The capsule contains: the encrypted envelopes, the encrypted key tables, the
wrapped shares, every identity public key it needs, the full signed record with
its timestamp tokens, and the format version.

`docs/RECORD.md` §6 already has the right sentence and it applies here without
change: without an independent verifier, "anyone can check this" is marketing.

---

## 8. Order of work

Commit after every phase. If you run out of room, **stop at a phase boundary
with a clean commit and write exactly where you stopped into `HANDOFF.md`.**
Do not leave the tree half converted and uncommitted.

0. The working tree currently has twenty plus modified files and nothing has
   compiled since 2026-08-28. Build it, fix what is broken, commit that as its
   own commit before any conversion work. Do not mix the pivot into an
   uncommitted mess.
1. The four security fixes from section 6, with tests.
2. The `Clock` protocol and the simulated clock, threaded everywhere.
3. Shamir sharing plus the Estate Key hierarchy from section 4, with vectors.
4. The data model: `Estate`, `Envelope`, `Custodian`, `Policy`, and the new
   record event types.
5. The release state machine from section 5, pure, exhaustively unit tested
   against the simulated clock including every cancel path.
6. CloudKit record types and the `SyncEngine` extension.
7. The removals from section 3.
8. The new screens: write an envelope, add a custodian, hand over a key, the
   policy screen, the heartbeat, the claim and countdown, the release ceremony,
   the reveal.
9. The capsule export and `tools/verify_capsule.py`.
10. Rewrite `README.md`, `HANDOFF.md`, `docs/SDS.md`, `docs/SRS.md`. Add
    `docs/PRODUCT.md` and `docs/RELEASE.md`. Move superseded docs to
    `docs/archive/`.

---

## 9. Constraints

- **No em dashes anywhere.** Not in code comments, not in documentation, not in
  app copy. This is a hard rule in this repo.
- No backend. No Render, no Vapor, no Cloudflare Worker beyond the static
  Apple app site association file that already exists.
- No new third party dependencies. CryptoKit and the standard library.
- Do not invent cryptographic primitives. Shamir over GF(256) is the only new
  construction and it is a known one.
- Do not hand edit `Seal.xcodeproj`. New Swift files under `Seal/` join the
  target automatically through file system synced groups.
- Do not change the relying party, bundle identifier, team, or CloudKit
  container.
- Numbered steps for operational tasks. Concise replies. Check `git status`
  first, because the working tree is often ahead of the last commit.
- Try to build with
  `xcodebuild -project Seal.xcodeproj -scheme Seal -destination 'generic/platform=iOS' build`
  and report the result honestly. If you have no Xcode available, say so
  plainly and do not guess at whether the code compiles.

## 10. What to tell me at the end

Which phases you finished, which you did not, what you deleted, what you
added, the exact build status, and every place where you had to make a judgment
call that a human should review. Be specific about anything in the
cryptographic layer you were not fully sure about. Do not smooth over
uncertainty.
