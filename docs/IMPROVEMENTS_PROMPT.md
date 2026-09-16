# Seal: the next round of improvements (brief for a fresh session)

You are picking up Seal in a new context window. Your job is to build the
improvements listed below, one at a time, in this repo. Read this whole file
before you touch any code.

## 0. Read these first, in this order

1. `HANDOFF.md` (where things stand, what is blocking, working style)
2. `docs/GOTCHAS.md` (read before debugging anything)
3. `docs/PRODUCT.md` (sections 7 and 8 are the promises; do not break them)
4. `docs/SDS.md` (key hierarchy and threat model)
5. `docs/RELEASE.md` (the release state machine)
6. `docs/CAPSULE.md` and `docs/RECORD.md` (only if a change touches the record)

## 1. How you work here

- **You have no compiler.** The human builds in Xcode on an iPhone and pastes
  back errors and screenshots. You write the Swift. So keep each step small
  enough that a failed build is easy to fix.
- **Step zero is the existing build.** HANDOFF says the 2026-09-16 batch is
  uncompiled. Before any new feature, ask the human to build and fix
  whatever breaks. Do not stack new work on an unbuilt tree.
- **One feature per phase. Commit after each working phase.** Check
  `git status` first. Then stop and ask the human to build and try it on a
  phone before you start the next phase.
- **iOS only, no backend, no new third party code.** CloudKit public
  database only. Apple frameworks only.
- **Do not change** the team, bundle id, CloudKit container, or the WebAuthn
  relying party `sealmessenger.com`.
- **New Swift files under `Seal/` join the target automatically.** A new
  target (a widget extension, a Watch app) does NOT. That needs Xcode steps
  the human must do by hand. Write those steps as a numbered list.
- **Any new CloudKit record type or queryable field** must be written into
  `docs/CLOUDKIT_DEPLOY.md` as numbered steps, because only the human can
  deploy the schema.
- **Tests live in the app target** (`Seal/SelfTest/`). Add tests there for
  anything that touches crypto, the record, or the release machine.
- **Words.** No em dashes anywhere: code comments, docs, and app copy. App
  copy is written to be read aloud to a parent over sixty: short sentences,
  plain words, the plain thing first. The user-facing term is "key holder".
  Do not rename it.
- **Security promises win.** If a feature below can only be built by
  weakening a promise in PRODUCT.md section 7, do not build that part. Write
  the trade-off down and stop for a decision.
- Update `HANDOFF.md` at the end of every phase: what landed, what is
  uncompiled, what is blocking.

## 2. What to build, in this order

### Phase 1. The "what to do first" guide

**Why:** a grieving family does not need a pile of passwords. They need to
know what to do first.

**What:** inside an envelope, a new optional section: an ordered checklist
the owner fills in. Each step has a short title, an optional note, and an
optional link to one of the envelope's secrets. Offer starter steps the
owner can pick from (call the bank, where the will and the car title are,
subscriptions to cancel, who takes the pet, funeral wishes, who to call
first). After release, the recipient sees numbered steps they can check off.
Check marks are stored only on the recipient's phone.

**Real example:** "1. Call Mike at the credit union. 2. The car title is in
the blue folder in the garage. 3. Cancel the gym membership."

**Rules:** it is sealed with the rest of the envelope, under the same
envelope content key. No new plaintext leaves the phone. Show it in
`FamilyPreviewView` too, since that view IS the real reveal screen.
Check whether the capsule format needs a version bump and update
`docs/CAPSULE.md` and `tools/verify_capsule.py` if so.

### Phase 2. Easier check-ins, and secrets that go stale

**Why:** the heartbeat only happens when the owner opens the app. A
forgotten app causes false alarms.

**What, part A (quick check-in):**
- An App Intent in the main target: "Check in with Seal", usable from Siri,
  Shortcuts, and the Action button. It may open the app to write the
  heartbeat if the keys cannot be reached without it. Say which you chose
  and why.
- A Lock Screen and Home Screen widget that shows "Last check-in: 12 days
  ago" and opens the app on tap. This is a new widget extension target, so
  give the human numbered Xcode steps. The widget must never read or show
  any envelope content, names, or secrets. Share only the last check-in
  date and the silence limit, through an App Group.
- Apple Watch: design only. Write a short note in HANDOFF. Do not build it.

**What, part B (stale secrets):**
- Each secret remembers when it was last confirmed. The editor shows its
  age in plain words ("Checked 7 months ago").
- Every 6 months (owner can change this), a local notification: "Are your
  saved passwords still right?" It opens a short review list where the
  owner taps "Still right" or "Update" on each one. The notification text
  never names a secret.
- Confirming a secret must not force a paid re-seal. Re-sealing is free, as
  HANDOFF says. If confirming changes nothing in the sealed data, it should
  not need a re-seal at all.

### Phase 3. Key holders who remember they are key holders

**What:** once a year (owner can change this), the key holder's phone asks
them to tap their key to confirm they still have it. The tap produces a
signed line in the record, like a custody receipt. The owner's home screen
shows each key holder's last confirmation. A key holder who has not
confirmed in over a year is flagged with a plain next step ("Ask Karen if
she still has her key").

**Rules:** this tap must not count toward a release, and must not be
mistakable for one anywhere in `ReleaseMachine`. Add tests that prove it.
It must not reveal anything about the envelopes to the key holder.

### Phase 4. The printed survival kit

**Why:** Seal is one developer. Buyers will ask what happens if the app goes
away.

**What:** from the owner's app, make a one-page PDF for each key holder, made
entirely on the phone. It says, in plain words: whose key this is, what
Seal is, what to do when the time comes, and what to do if the app no longer
exists (export the capsule, run `tools/verify_capsule.py`, where the format
is documented). Include a QR code to the site's how-it-works page. It must
contain no secrets, no share material, and no envelope details. Share it
with the normal share sheet so it can be printed.

### Phase 5. Couples set up together

**What:** a guided "set up with my partner" path. Each partner still has
their own identity and their own estate (one estate per identity does not
change). The flow walks two people, on two phones, through meeting in
person once, making each other a recipient and a key holder, and then each
writing their own envelopes. It is a guided path over existing pieces, not
a shared estate.

**Real example:** a husband and wife at the kitchen table, both phones out,
done in one sitting, each with an envelope to the other.

### Phase 6. More ways to open (design first, then build only what is safe)

Write a short design note in `docs/RELEASE.md` first. Then build.

- **A: open on a date.** A letter meant for a child's 18th birthday. There
  is no server and no trusted clock, so a date alone cannot open anything.
  The honest version: the envelope carries an "open no earlier than" date,
  and it still needs the owner to be past the silence rule and M key holder
  taps, OR it is only shown after release on or after that date. Pick the
  design that keeps PRODUCT.md section 7 true, and say plainly in the app
  what the date does and does not guarantee.
- **B: the owner is alive but cannot act** (for example after a stroke). A
  separate, smaller envelope set marked "bills and medical" with its own
  shorter rule, while personal letters keep the full rule. This probably
  means a second estate key or a second policy. That touches the key
  hierarchy. **Design it, write the trade-offs, and stop for a decision
  before building.**

### Phase 7. Envelopes for people who are not on Seal yet (design only)

**Why:** today every recipient must have an iPhone, have Seal, and have met
the owner in person. That stops many people from finishing.

**Real example:** a dad wants to write to his daughter, who uses Android and
lives in another state.

**What:** PRODUCT.md section 8 already calls this a known gap, and says the
simple fixes weaken the isolation promise. So do NOT build this. Write a
design note, `docs/PENDING_RECIPIENTS.md`, that lays out two or three real
options (for example: a key holder vouches for the recipient in person after
release and the envelope is re-wrapped to them then; a printed share given
to the recipient now; a sealed envelope the claimant can read). For each,
say exactly which promise it weakens, who could read the envelope early,
and what the app would have to say to the owner. End with a recommendation
and stop. The human decides.

## 3. Not in scope

- Selling through attorneys and planners is a business task, not code.
- No messenger features. HANDOFF explains why.
- No Android. No server. No analytics.

## 4. When you finish each phase, report

In plain words, short:
1. What you built, and one real example of how a person would use it.
2. Which files changed.
3. Any Xcode or CloudKit steps the human must do, numbered.
4. What you are least sure will compile.
5. Any promise you had to think hard about, and what you decided.
