# Paste this into a new session

Repo: `~/Documents/GitHub/Seal`, a SwiftUI iOS 26 app called Seal. Public at
github.com/jasonepage/Seal, MPL-2.0. Read `HANDOFF.md`, `docs/PRODUCT.md` and
`docs/GOTCHAS.md` before anything else. `README.md` and the six pages in
`site/` are the current, accurate description of the product.

## House rules, not negotiable

- **No em dashes anywhere.** Code, copy, commit messages, docs, all of it.
- **Never the word "will" as an auxiliary verb in user-facing copy.** "It opens",
  not "it will open". The noun is fine and is the whole pitch: a will filed for
  probate becomes a public court record, so a password cannot go in one.
- **Plain words for people over sixty.** Every sentence gets read aloud to a
  parent. Define anything technical on first use.
- **Brass (`SealTheme.brass`) marks a trust moment only.** Never decoration.
  Silver for anything vouched for at a distance.
- **Do not touch `Seal.xcodeproj`.** New Swift files under `Seal/` join the
  target automatically. Do not touch `Seal/Crypto` logic (the MPL header
  comments at the top of those files are fine and are meant to be there).
- Commit after each working milestone, `git status` first, and write commit
  messages that explain **why**, matching the existing style in `git log`.
  End them with the attribution lines your session reminder gives you.

## Where this stands

`HEAD` is `43a6e5e`, everything is pushed, the working tree is clean.
Fourteen commits landed in the previous session on top of `4723bac`:

- The retire ceremony refuses a backup key instead of bricking it
- CloudKit estate push went silent (it was firing on every owner heartbeat and
  notifying key holders several times a day), replaced by local notifications
  from `Seal/Estate/CustodianNotices.swift`
- Two screens that could not scroll now do (`FriendsView`, `RegistrationView`)
- On-device dictation (`Seal/Speech/Dictation.swift`, `DictationButton.swift`)
- An envelope can be written to a typed name before meeting anybody
  (`Envelope.draftRecipientName`, `unbound.` hash prefix, skipped by the seal)
- The home screen before the first seal is one card, "1 of 4 done"
- Threshold-of-one copy was saying "you cannot open anything" to somebody who
  could open everything; fixed, and the default threshold now moves to 2 on the
  second key holder
- Directory failures name the person and the real reason instead of "check your
  connection", which was the one cause it could never be
- The website, the App Store listing copy, the README, SECURITY.md and LICENSE

## THE MOST IMPORTANT FACT

**None of this has ever compiled.** Not one line. There is no Swift toolchain
and no Xcode here. Nathan builds in Xcode and pastes errors back, and you fix
them in place. That is job zero and it comes before any of the five tasks
below. Do not stack more uncompiled work on top without asking.

Where errors are most likely, each flagged in its own file:

1. `Seal/Views/Interview/InterviewDrafting.swift` — the FoundationModels API
   spelling (`LanguageModelSession { instructions }`,
   `session.respond(to:generating:).content`, `@Generable`, `@Guide`).
2. `Seal/Speech/Dictation.swift` — `AVAudioApplication.requestRecordPermission`,
   `addsPunctuation`, `supportsOnDeviceRecognition`.
3. `Seal/Views/Onboarding/OnboardingFigures.swift` — `let` bindings inside
   ViewBuilder closures in `ShamirCurveFigure`.

Build settings that matter: `SWIFT_VERSION = 5.0`,
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, deployment target **iOS 18** at
the target level despite the docs saying 26.5, so every iOS 26 API needs
`@available` and `#if canImport`.

## The five things to build

Do them in this order. Each is independent and each gets its own commit.

### 1. Remind the OWNER to check in, before their own countdown starts

The entire ongoing obligation is "open the app now and then", and if the owner
forgets for 90 days they trigger their own death process. Nothing reminds them.
`CustodianNotices` handles the other side only.

Post local notifications to the owner at roughly 50% and 80% of their silence
window, and again a few days before the limit. Same pattern as
`CustodianNotices`: keep the last level announced in the keychain per identity,
never repeat one, wipe it in `ContentView.wipeLocalAndEngines`, skip in demo
mode. Read `lastHeartbeatAt` from `estateEngine.ownerSnapshot` and
`policy.silenceDays` from the estate, and drive it from
`HomeView.refreshEverything()` which already runs on launch and foreground.

Copy should be calm, not alarming: this is a person who is alive and busy, not
a person in trouble.

### 2. Notice when a key holder gets a new phone

**This is a silent failure that turns two-of-three into one-of-three and nobody
finds out for a decade.**

A Shamir share is wrapped to a custodian's *device* KEM keys at seal time. Those
keys are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they do not sync
and do not restore. A custodian who replaces their phone signs in, gets endorsed,
and the app says everything is fine, but their share was wrapped to a device that
no longer exists. `Estate.needsNewEpoch` only compares
`publishedCustodianHashes`, which is the set of *people*, not their devices.

Fix: at seal time, record a digest of each custodian's endorsed device KEM
bundles. Add `var publishedCustodianDevices: [String: [String]] = [:]` to
`Estate` in `Seal/Estate/EstateModels.swift` (a stored property with a default
keeps `Codable` happy with existing saved data). Populate it in
`EstateEngine.sealAndPublish` where it already calls
`kemBundles(of: c.rootHash)`. Then on `refreshOwner`, compare against current
bundles and surface it on the home screen: name the person, say their phone
changed and their piece is on a phone they no longer have, and make sealing
again one tap.

`site/support.html` already tells people this happens. The app should be the
thing that notices.

### 3. Catch a seed phrase typed into the letter

The letter is shown in full when an envelope opens. A secret is hidden behind a
Face ID check and copied byte for byte. People paste in the wrong box.

Add a deterministic check (no model, no network) on the letter field in
`Seal/Views/EnvelopeEditorView.swift`: if it contains 12, 15, 18, 21 or 24
consecutive lowercase words that are all in the BIP39 English wordlist, offer
one line under the field: something like "Those twelve words look like a
recovery phrase. Letters are shown in full. A secret stays hidden until Seal
checks your face. Move it?" One tap moves it into a `SealedCardType.seedPhrase`
secret and removes it from the letter.

Ship the wordlist as a plain Swift file (`let bip39English: Set<String>`) so it
joins the target with no project change. The list is public domain.

Do the same for anything that looks like a long private key or an `xprv`. Keep
it deterministic and quiet: no scolding, one line, easy to dismiss.

### 4. On-device review: "would this actually help them?"

**This is the on-device AI task, and it targets the product's real failure mode.**
`docs/PRODUCT.md` §11 says it plainly: the way Seal fails is an empty vault that
opens perfectly. The near miss is a *full* vault that opens and still leaves the
reader stuck, because the letter says "the folder in the study" and never says
which folder, or "call Marco" with no way to reach him.

Before sealing, run the letter through Apple's Foundation Models on device and
surface anything a reader could not act on: a reference with no referent, a
person named with no contact, an instruction with no location, a promise of a
document that appears nowhere.

Hard rules, and the file to copy them from is
`Seal/Views/Interview/InterviewDrafting.swift`:

- **Secrets never reach the model.** Enforce by filtering on type, the way
  `InterviewDraftingShared.letterAnswers` does, not by convention.
- On-device only, `#if canImport(FoundationModels)` plus
  `@available(iOS 26, *)`, and a phone that cannot run it gets **no feature**
  rather than a server. Same fail-closed shape as `InterviewHelper.drafter()`.
- It suggests, it never edits. The owner changes every word or ignores it.
- It never comments on the wisdom of what is being left to whom.

Present it as a soft, dismissible list on the envelope editor, not a blocker.
Sealing is never gated on it.

### 5. "What your family sees"

The owner has no way to see what they are actually leaving. They write into a
form and tap Seal and hope. That is a confidence problem and it is the last
thing between somebody and paying for this.

Build a read-only preview reachable from the envelope editor and from the home
screen that renders exactly what one recipient sees at release: their name,
their envelopes in reveal order, the letter, the photos, the voice message, and
the secrets behind the same Face ID check. All from local state. It touches no
engine, no clock and no network, exactly like `SealOnboardingView`.

`Seal/Views/RevealView.swift` is the real recipient screen and is the thing to
mirror so the preview cannot drift from it.

While you are there: `Envelope.revealOrder` exists and there is barely any UI
for it. Let the owner reorder a person's envelopes by dragging.

## Known problems, not on the list, do not lose them

- **The rename.** The physical key was dropped as a concept on 2026-09-15 once
  it turned out nothing cryptographic ever touched it. A custodian's own passkey
  or security key signs the authorization and their *phone* holds the share. But
  the app, `docs/PRODUCT.md`, `README.md` and six web pages all still say "key
  holder", "hand a key" and "put it somewhere you can find in ten years". This
  is one sweep, worth doing in one go, and it is the biggest remaining
  inconsistency in the product.
- `EnvelopeInterviewView.onDraft` dismisses one sheet and presents another in
  the same run loop turn, which is the classic SwiftUI trap. Watch for the
  editor failing to open after the interview. Fix by presenting from `onDismiss`.
- `InterviewDraftingShared.splitToCardSize` promises byte-exact reassembly for
  answers over 2048 bytes, but each part then goes through
  `SealedCard.validated`, which trims surrounding whitespace, so a split landing
  on a newline loses it.
- `InterviewFollowUp` is gated on `question.allowsFollowUp` rather than on the
  target being `.letter`. True today by accident. One `guard` fixes it.
- Three screens still cannot scroll: `CapsuleExportSheet`, `ForgeLogView`, and
  the voice recorder sheet in `EnvelopeEditorView`.
- `Message`, `SealGroup` and the messenger transport in `SyncEngine` are dead
  code. `HANDOFF.md` says safe to remove. The stale push notification bug came
  out of exactly that corpse. Do it **after** a green build, not before.
- `seal.onboardingRole` is written in `SealOnboardingView` and never read.
- `SealMascot` renders on the empty People screen, which `docs/GOTCHAS.md` would
  call a security surface.
- The WebAuthn relying party ID is still `sealmessenger.com` and cannot be
  renamed without every identity registering again. `HANDOFF.md` says decide
  before TestFlight. TestFlight has shipped.
- `docs/GOTCHAS.md` still warns that ML-KEM-768 is a TODO. It is not: it is
  implemented in `Seal/Crypto/KEMBundle.swift` behind an iOS 26 check. Delete
  that stale warning.

## Working style

Numbered steps for ops tasks. Concise replies. Verify claims against the code
before stating them; this codebase has burned people three times with copy that
contradicted shipped behaviour, and `docs/GOTCHAS.md` has a section called
"Copy and docs that lie" because of it. If the data does not support a claim,
say so.
