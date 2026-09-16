# Where Seal stands

**Updated:** 2026-09-16 (morning after) · **Owner:** Nathan (Jason Page) · natepage67@gmail.com
**Repo:** `~/Documents/GitHub/Seal` · iOS 26.5+, SwiftUI, no backend

New Swift files under `Seal/` join the target automatically (file system
synced groups), so no project edits are needed to add one.

## What Seal is

**Sealed envelopes for the people you leave behind.** One person writes a few
envelopes (letter, photos, voice, secrets), hands security keys to custodians,
sets the rule, and opens the app now and then. After a long silence, weeks of
warnings and M physical key taps, the envelopes open on the recipients'
phones. [docs/PRODUCT.md](docs/PRODUCT.md), [docs/RELEASE.md](docs/RELEASE.md).

The messenger it grew out of was retired on 2026-09-15 (phase 7 commit). The
identity layer, the ceremony, the hybrid wrapping, the signed record with
timestamps, custody receipts and sealed cards were kept and extended.

## Identifiers (unchanged, do not change)

- Team `8C4BM6A82T` · Bundle `io.github.jasonepage.Seal`
- CloudKit container `iCloud.io.github.jasonepage.Seal`
- WebAuthn relying party `sealmessenger.com`

## THE SPONSORED KEY (built 2026-09-16, UNCOMPILED, needs hardware)

Jason said cram it in, so it is in. `docs/PENDING_RECIPIENTS.md` option A:

- `Seal/Identity/SponsoredKey.swift`: the virtual device's private halves
  (P-256 signing key, X25519, ML-KEM seed), locked with AES-GCM under
  HKDF(PRF output, salt). `lock`, `unlock`, `publicParts`.
- `DeviceEndorsement.lockedPrivate` and `.prfSalt` (optional, nil on a
  phone; `isSponsored`). Outside the commitment on purpose. No CloudKit
  schema change: they ride inside the existing `deviceEndorsements` blob.
- `Friendship.sponsored` (optional), so PersonView can say how the person
  was added and nothing mistakes it for a ceremony.
- `CeremonyManager+Sponsored.swift`: `registerSponsoredKey`. Two taps on
  the spare key: registration with `prf = .checkForSupport` (refuses a key
  without PRF before anything is saved), then the endorsement assertion
  with `prf = .inputValues(salt)` whose output locks the halves. Publishes
  the identity, pins it, returns it. The owner's phone keeps nothing.
- `CeremonyManager.signIn`: when the directory says the identity is
  sponsored, the endorsement tap on the new phone also evaluates PRF over
  the stored salt and `installSponsoredHalves` onto that phone.
- `IdentityManager.sponsoredHalves` and `kemPrivateBundles` (own bundle,
  then the sponsored one). `EstateEngine.refreshGuarded` fetches invites
  with each; `openEnvelopes` tries each bundle per table.
- `SponsoredKeyView`, reached from People ("Register a key for someone who
  is not here"). Says: whoever holds this key and its PIN is them; set a
  PIN; nothing opens before the release.
- Tests: `SponsoredKeyTests` (lock opens only with the key; halves match
  the public parts; a sponsored endorsement verifies like a phone's).
- `docs/SECURITY_KEY_TEST_MATRIX.md` has the PRF columns and the three
  failure names. `docs/CAPSULE.md` section 4 documents the two fields.

**Needs real hardware to prove.** The PRF API names on the security key
request and result types (`prf`, `.checkForSupport`, `.inputValues(.init(saltInput1:saltInput2:))`,
`.prf?.isSupported`, `.prf?.first`) mirror Apple's iOS 18 platform passkey
API and Apple's docs list the security key `prf` property as iOS 26.4. If
the spelling differs, every call is in `CeremonyManager+Sponsored.swift`
under "PRF plumbing". Test with a YubiKey 5 with a PIN set: register a key
as "Emma" on phone A, write and seal an envelope for Emma, sign in on
phone B with that key, run a release with Time Travel, open.

**Custodian use is not wired.** A sponsored identity can be a recipient.
Making one a key holder would need `myShare` and `release` to try
`kemPrivateBundles` too and a way to tap the key for authorization on the
future phone; that works in principle (the key is the root credential)
but is untested and deliberately left for after the first hardware pass.

## BILLS AND MEDICAL: the second envelope set (built 2026-09-16, UNCOMPILED)

`EstateEngine.Slot` (`.letters`, `.urgent`) and `storeHash`: the same
engine, a second instance, its own keychain keys and media directory
(`urgent.<hash>`). `ContentView` makes `urgentEngine`; `HomeView` writes
its heartbeat beside the letters' and schedules its owner reminders under
its own store key; `EstateHomeView` takes `lettersEngine` and
`urgentEngine` and a `slot` picker ("Letters" / "Bills and medical") at
the top of the Envelopes and Keys tabs, with `estateEngine` computed from
it. What this phone holds for others is read from the letters engine
only. The urgent set's default rule is the shortest silence allowed,
seven warning days, no grace; `createEstateIfNeeded` sets it. Invites
from the urgent set carry the owner name as "Nathan (bills and medical)"
so a key holder's phone tells the two estates apart with no model change.
`EstateStore.save` takes the store key now (DemoFixtures updated). Sign
out wipes both slots. The widget shows the letters' rule.

Most likely to fail to compile: `@Bindable var lettersEngine` /
`urgentEngine` with the computed `estateEngine` (if `@Bindable` is
unhappy on a computed property's source, drop it; nothing binds through
it); `Slot` with a raw value of "" for `.letters`.

## APPROVED AND DONE (Jason, 2026-09-16)

1. The sponsored key: built, needs hardware.
2. Bills and medical: built.

## THE MORNING BATCH (2026-09-16, UNCOMPILED): everything in

Jason's call: cram everything into this TestFlight build. So, on top of
the tabs and the inbox:

- **Phase 7, design only, done:** `docs/PENDING_RECIPIENTS.md`. Three
  options for a recipient who is not on Seal; recommends A, the
  sponsored key that carries a secret via the WebAuthn PRF extension,
  which Apple ships for hardware security keys from iOS 26.4 (the app
  requires 26.5). Not built: it is the riskiest code in the app and
  needs a decision and a hardware test matrix. The next batch if A.
- **Phase 6A, built:** `Envelope.openNoEarlierThan`, in the sealed
  payload as `openNoEarlierThanEpoch`. `Payload.isHeld(now:)`. The
  editor has an "Open on a date" card that says exactly what the date
  does and does not do; `RevealPager` shows `heldView` (title and date,
  nothing else) until the recipient's clock passes it. Nothing in the
  machine, the keys or the tables reads the date. RELEASE.md section 9;
  CAPSULE.md section 7; test `firststeps.openOnADate`.
- **Phase 6B, designed, stopped:** RELEASE.md section 10. Two estates
  per identity is the recommendation. Decision needed before code.
- **The 47 warnings, swept:** all one shape. Forty four were the test
  suites passing a main actor function as a plain closure; each
  `.init(name:run:)` is now `.init(name:) { try fn($0) }`. Three were
  `ReleaseFeed.effectiveTime` (nonisolated) reading `EstateEvent` and
  calling `TimestampDER`; both types are now `nonisolated` (they are
  pure data and pure arithmetic). One was `CustodyReminders.identifier`
  used with `map`; now `nonisolated`. If the sweep produced NEW
  warnings, the cause is Xcode's default main actor isolation on the
  module: fix the named symbol with `nonisolated`, never by turning the
  setting off.

Most likely to fail to compile in this batch: `nonisolated struct` and
`nonisolated enum` (Swift 6.2 syntax; if the toolchain rejects it,
mark the three members instead: `digest`, `occurredAt`, `genTime`);
the `DatePicker` bindings in `openOnDateCard`.

## BEFORE THE NEXT TESTFLIGHT BUILD: the checklist (2026-09-16)

Written the morning after the improvements batch, when Jason asked what
was left before archiving. The answer is nothing in code. These, in
order, and none of them can be skipped:

1. **Commit everything.** `git status` shows Phase 4 (the printed key
   holder page), Phase 5 (set up with my partner), the three tab home
   screen, the inbox, `docs/Seal-explained.pdf` and this file. Two or
   three commits, any sensible split. Delete
   `docs/Seal-explained-for-the-family.pdf` (superseded).
2. **Deploy the CloudKit schema to Production.** `EstateEvent` with
   `estate` QUERYABLE, per `docs/CLOUDKIT_DEPLOY.md`. TestFlight talks to
   Production. Without this every seal from the TestFlight build fails
   and the failure looks like "could not seal", not like a schema error.
   This is the most likely way the test goes wrong.
3. **Decide the domain.** The ceremony screen shows `sealmessenger.com`
   to every tester. After the first outside tester the relying party
   cannot change. "Keep it" is a valid decision; "not yet" is not.
4. **The product in App Store Connect:** `io.github.jasonepage.Seal.lifetime`,
   non consumable, $29.99, plus the Paid Apps agreement. The paywall
   stands in front of every seal, so a build with no product cannot seal.
5. **If the widget target was added:** App Groups ticked on both
   targets (`group.io.github.jasonepage.Seal`), or the widget says "Not
   sealed yet" forever. If it was not added, the app builds fine without
   it; the Siri check-in still works.
6. **App Review notes** still name the demo path (`SEALDEMO`, "Set up
   with Face ID"). Unchanged this batch.
7. **Wipe local state on any phone that switched environments** (sign
   out and back in), or the Development estate in the keychain confuses
   the Production build (GOTCHAS "Environments"). The engine now rotates
   the epoch when the published material is missing, so this is less
   fatal than it was, but a clean start is still the honest test.

What has never run on a phone and needs the TestFlight week: the
widget, "Check in with Seal" by Siri, the yearly key confirmation (needs
a second phone or Time Travel), video and the steps list on a real
release. Mom is the tester.

After the build is out: the 47 main actor warnings (one sweep, one
word each, `nonisolated` or `@MainActor`, mostly in `Seal/SelfTest`),
then `docs/PENDING_RECIPIENTS.md` (Phase 7, design only), then Phase 6.

## STATUS 2026-09-16 (evening): the improvements batch, phase by phase

The whole tree through `e713868` (the pricing work and the brief itself)
**built and ran clean on a phone** on the evening of 2026-09-16. The
improvements brief is in `docs/IMPROVEMENTS_PROMPT.md`; this section tracks
it. Each phase is committed on its own and is uncompiled until the line
below says otherwise.

### Phase 1: "What to do first" (UNCOMPILED)

An envelope carries an ordered list of steps (`FirstStep`: title, note,
optional index of one of the envelope's secrets). It is a field on
`Envelope` and on `Envelope.Payload`, so it is sealed under the envelope
content key with the letter and the secrets and nothing new leaves the
phone. The recipient sees numbered steps with check circles in
`RevealPager`; ticks are kept in the keychain under the viewer's hash
(`FirstStepsDone`) and nowhere else. The owner's preview shows the same
view with ticks that do not persist. `FirstStep.starters` is the list the
owner can pick from. Capsule format: additive, no version bump;
`docs/CAPSULE.md` section 7 says so. `tools/verify_capsule.py` never reads
a payload and did not change.

Files: `Seal/Estate/FirstSteps.swift` (new), `Seal/Views/FirstStepsEditorView.swift`
(new), `Seal/SelfTest/FirstStepsTests.swift` (new), `EstateModels.swift`,
`EnvelopeEditorView.swift`, `RevealView.swift`, `ContentView.swift`,
`SelfTestRegistry.swift`, `docs/CAPSULE.md`.

**A bug found on the way, fixed in the same phase:** `Estate`, `Envelope`
and `Envelope.Payload` relied on `var x: [T] = []` to decode JSON that has
no `x`. Swift's synthesized decoder does not do that; it throws
`keyNotFound`, `EstateStore.load` swallows it with `try?`, and the owner's
estate would simply not be there. Every field added after the first save
(`publishedCustodianHashes`, `publishedThreshold`,
`publishedCustodianDevices`, `publishedTableIDs`, and now `firstSteps`) is
now read with `decodeIfPresent` in hand written `init(from:)` extensions at
the bottom of `EstateModels.swift`. `firststeps.oldEstateDecodes` proves it.
**Any new stored property with a default on those three types must be added
to the matching `init(from:)`, or it silently breaks loading.**

Built and ran clean on the phone on 2026-09-16 (evening). Phase 1 is done.

### The home screen is three tabs (UNCOMPILED)

Jason's call on 2026-09-16 morning: one scroll with the status, every
envelope, every key holder, every guarded estate and a footer was
clutter, and "Seal the envelopes" sat below all of it. `EstateHomeView`
is now a `TabView`: Envelopes (status or setup card, the envelopes,
family preview, saved secrets, the Seal button), Keys (the rule, who
holds a key for you with their yearly standing, set up with my partner,
what you hold for others, the footer), People (`FriendsView` as a tab,
no longer a sheet). Every sheet and alert hangs off the tab view in
`attachSheets(to:)` so any tab can open any of them. The status card's
check-in paragraph is one sentence; the rest is behind "Watch it
happen". Every user facing "custodian" on these screens, in `PolicyView`
and in `ReleasePolicy.summary` is now "key holder", and the summary
reads "Your one key holder" at one instead of "Any 1 of your 1".

**Then the Envelopes tab became an inbox** (same morning): one compact
row per envelope, newest first (initial, name, title, one line of
contents, date, orange dot when unsealed), a one-line status strip
instead of the status card (the card still shows for a claim, a release
or a long silence), a floating brass Write button (write, or help me
write it), the preview, the saved secrets and "Watch it happen" behind
the ellipsis menu, and a Seal bar above the tab bar only while
something is unsealed. `envelopesSection`, `envelopeRow`,
`familyPreviewRow`, `helperRow`, `secretReviewRow` and `sealButton` are
gone; `runSeal` is the one seal path.

Most likely to fail to compile: `@ViewBuilder private var inbox`
with `if let` inside; `FriendsView` as a tab (it carries its own
`NavigationStack`, which is what a tab wants); the `.toolbarBackground`
calls on the `TabView`.

### Phase 5: set up with my partner (UNCOMPILED)

`Seal/Views/CoupleSetupView.swift`: a guided checklist over existing
pieces, run on both phones. Pick the partner from the people met (the
choice is remembered per identity in UserDefaults; a name, not a
secret). Six steps: meet, make them a key holder, hand them a key (opens
PersonView's receipt flow), write the envelope (creates it and opens the
editor), one more key holder each (recommended, not gating; with only
each other one key alone opens after the silence), seal (the home
screen's one seal path, paywall in front). Every step says what happens
on this phone and what the partner does on theirs, and the screen says
plainly that it can only check its own side. Nothing in the key
hierarchy moves; one estate per identity is unchanged. Reached from the
setup card's "Set up with my partner" button. `AnyButtonStyle` (bottom
of the file) erases two button styles behind one `if`.

Most likely to fail to compile: `PersonView` presented inside a sheet
with an extra toolbar item; `AnyButtonStyle` (if `makeBody` on a
`ButtonStyle` value is not directly callable, replace with two separate
`if` branches).

Not committed yet: the shell on Jason's Mac stopped starting on the
evening of the 16th, so Phase 4, Phase 5 and `docs/Seal-explained.pdf`
were written straight to disk through the file bridge. `git status` will
show them. Commit them in two commits (Phase 4 with the PDF, Phase 5).

### Phase 4: the printed survival kit (UNCOMPILED)

`Seal/Views/SurvivalKitPDF.swift`: `SurvivalKit.content(...)` builds the
words from two names, the rule, the key holder count and a date, and
nothing else, so the page cannot carry a secret, a share or an envelope
detail by construction. `render` draws one US Letter page with
`UIGraphicsPDFRenderer` and a Core Image QR code to
`sealmessenger.com/how-it-works.html`; the verifier's address and
`docs/CAPSULE.md` are named in the text. `makeFile` writes it to the
temporary directory for the share sheet. Reached from `PersonView`'s key
holder card: "A page to keep with the key", then "Print or send the page
for Karen". Tests in `SurvivalKitTests` check the words and that the
bytes are a PDF. No Xcode steps, no CloudKit.

Note for the pilot: the page tells the key holder to save a capsule
today, because a capsule is the only thing that makes recovery easy if
the app is gone. Say that out loud at the elders evening.

Most likely to fail to compile: `CIFilter.qrCodeGenerator()` needs
`import CoreImage.CIFilterBuiltins` (it is there); `UIGraphicsPDFRendererFormat.documentInfo`
keys as `String`.

### Phase 3: key holders confirm they still have their key (built clean 2026-09-16)

- `Seal/Estate/CustodyConfirmation.swift`: the `custodyConfirmed` event
  body, the challenge in its own domain (`seal.custody.confirm.v1`, no
  claim id, no share), the pure readers (`latest`, `latestVerified`
  against the pinned root key), `standing` for the owner's screen, `isDue`.
- `ReleasePolicy.custodyConfirmMonths` (6, 12, 24; default 12) with a hand
  written decoder so older policies load. Shown in `PolicyView`. Changing
  it is a policy change, so it is announced with `policyChanged` and the
  key holders' phones learn the interval from the record.
- `ReleaseFeed` lists the kind under the ones it ignores. `ReleaseMachine`
  is untouched. `custody.neverCountsTowardRelease` proves three
  confirmations during an open claim leave the snapshot identical.
- Engine: `confirmCustody` (custodian, reuses the release tap ceremony
  with the custody challenge), `myLastCustodyConfirmation`,
  `custodySince`, `custodyConfirmationDue`, `custodyStanding(for:)`.
- `GuardedEstateView.custodyCard`: asks when due, brass button "Tap my
  key to confirm"; otherwise one quiet line. `EstateHomeView.custodianRow`
  shows each key holder's standing, orange with "Ask Karen if she still
  has it" when overdue.
- `Seal/Estate/CustodyReminders.swift`: the local notification at the
  due date, per estate, replaced on each refresh; posted at once if the
  date already passed and this anchor was never announced.
- `tools/verify_capsule.py` admits the kind for custodians. `docs/CAPSULE.md`
  and `docs/RELEASE.md` section 8 say what it is and is not. No CloudKit
  change: `kind` is a String field already.

Tests: `Seal/SelfTest/CustodyConfirmationTests.swift`. Most likely to fail
to compile: `EstateLogTests.Actor` used from another file (it is
internal, should be fine); `KeyPinStore.pinnedKey(for:)` spelling.

### Second pass on the envelope (built clean 2026-09-16, evening)

Jason looked at Phase 1 on the phone and called it a form with a popup
menu, which it was. Rebuilt on 2026-09-16 evening (`bda513c`):

- `EnvelopeEditorView` is five cards in the order the recipient sees
  them (letter, what to do first, secrets, photos, voice). A filled card
  shows its contents small; an empty one says in one line why the
  recipient would want it. A packing line and five dots at the top say
  what is in the box. The letter card opens to write and closes to a
  four line preview. The voice card plays back in place.
- `FirstStepsEditorView` is a timeline with inline editing (title, note
  with dictation, secret picker that can create a secret on the spot),
  starter chips in an adaptive grid, up and down arrows to reorder.
- `FirstStepsViews.swift` (new) holds the shared pieces: `StepMarker`,
  `StepsTimelineMini`, `SecretChip`, `StarterChip`, and the recipient's
  `StepsChecklist` with "2 of 5 done" and the next step lit.
- `Envelope.contentsSummary` feeds the home screen row.

**Video and saving (same evening, UNCOMPILED):** `Envelope.videoNote` and
`Payload.videoNote`, `MediaItem.Kind.video`, `Envelope.allMedia` (the one
list the engine encrypts, uploads and removes). `VideoRecorderPicker`
(system camera, front, one minute, medium quality, 80 MB ceiling),
`VideoPlaySheet` (AVKit, with Save), `MediaSaving` (Photos add-only for
photos and video, temp files for the player and the share sheet). The
reveal now has Save under each photo, Save on the video, Share on the
voice message, and its order is the editor's: letter, voice, video,
photos, steps, secrets. `NSPhotoLibraryAddUsageDescription` is in
Info.plist; the camera usage string in the project file now mentions
video. GOTCHAS: an old build cannot decode a payload with a video.

Most likely to fail to compile: `TextField(..., axis: .vertical)` with
`.lineLimit(2...6)`; the `@FocusState` keyed by a String; the generic
`card(...)` helper with a `@ViewBuilder` closure containing if/else
chains (if the type checker times out, split the branch bodies into
their own `private var`s). In the video code: `AVAssetImageGenerator.image(at:)`
(async, iOS 16), `PHPhotoLibrary.requestAuthorization(for:)` async form,
`ShareLink(item: URL)`, and `UTType.movie.identifier` needing
`UniformTypeIdentifiers`.

### Phase 2: easier check-ins, and secrets that go stale (built clean 2026-09-16)

**Part A, the quick check-in.**

- `Seal/CheckIn/CheckInIntent.swift`: the App Intent "Check in with Seal"
  for Siri, Shortcuts and the Action button. **It opens the app.** The
  heartbeat is signed by a Secure Enclave key that is "when unlocked, this
  device only", the engine that writes the log lives in the running app,
  and if the app lock is on the Face ID check is the gate PRODUCT.md
  section 7 promises; a background heartbeat would fail on the first, race
  on the second and go around the third. Opening the app IS the heartbeat.
  The intent leaves a flag (`CheckInRequest`) and `HomeView` answers with
  one line after the heartbeat lands ("You are checked in...").
- `Seal/CheckIn/CheckInShared.swift`: after every heartbeat the engine
  writes exactly two numbers into the App Group
  `group.io.github.jasonepage.Seal`: the last check-in time and the silence
  days. Nothing else ever goes through it. Wiped on sign out.
- `SealWidget/` (new folder, NOT in the app target): the Lock Screen and
  Home Screen widget. "Last check-in: 12 days ago. 78 of 90 quiet days
  left. Tap to check in." It reads the two numbers and nothing else. This
  is a new target and needs the Xcode steps below.
- `Seal/Seal.entitlements` now carries the App Group.

**Xcode steps for the widget (only Nathan or Jason can do these):**

1. File > New > Target. Pick iOS > Widget Extension. Product Name exactly
   `SealWidget`. Untick "Include Configuration App Intent" and "Include
   Live Activity". Team 8C4BM6A82T. Finish. When Xcode offers to activate
   the SealWidget scheme, say Activate (it does not matter either way).
2. Xcode makes a `SealWidget` folder and template files. The folder
   already holds four files from this commit. If Xcode asks about the
   existing folder, keep it. Then move Xcode's own template files to the
   trash: `SealWidget.swift` and `SealWidgetBundle.swift` (and
   `AppIntent.swift` if it made one). Keep `Info.plist`, `Assets.xcassets`
   and the four files that were already there (`CheckInWidgetBundle.swift`,
   `CheckInWidget.swift`, `CheckInShared.swift`, `SealWidget.entitlements`).
3. Select the SealWidget target > Signing & Capabilities. Set the team.
   Tap "+ Capability" and add App Groups. Tick
   `group.io.github.jasonepage.Seal` (tap + and type it if it is not
   listed). If Xcode points the target at a different entitlements file,
   that is fine as long as the group is ticked.
4. Select the Seal target > Signing & Capabilities. Add App Groups the
   same way and tick the same group. The entitlements file already lists
   it, so it should show as ticked.
5. SealWidget target > General: set the minimum deployment to match the
   app (iOS 26.5).
6. Build and run the Seal scheme on the phone. The widget ships inside the
   app. On the phone, hold the Lock Screen, Customize, add "Check in with
   Seal"; or hold the Home Screen, +, search Seal.
7. For the Action button: Settings > Action Button > Shortcut > pick
   "Check in" under Seal. For Siri, say "Check in with Seal".

**Apple Watch: design only, not built.** A Watch app would be one button,
"I am here", that writes the heartbeat. It cannot, for the same three
reasons the intent cannot: the signing key is on the phone. The honest
Watch version is a complication showing the same two numbers as the
widget (through Watch Connectivity or the App Group on a paired watch,
which does not share app groups, so it would need
`WCSession.transferCurrentComplicationUserInfo`), and a tap that opens the
phone app. That is a mirror of the widget with a paired-device transport
on top, for a group of users who mostly do not wear one. Not worth a
target until somebody asks.

**Part B, secrets that go stale.**

- `Seal/Estate/SecretReview.swift`: `SealedCard.confirmationKey` (SHA-256
  of type, title and value), `Envelope.secretConfirmations` (owner's copy
  only, never in the payload), `SecretAge.line` ("Checked 7 months ago"),
  and the `SecretReview` schedule: every 3, 6 (default) or 12 months, one
  local notification that never names a secret.
- `EstateEngine.confirmSecret` writes the date and nothing else: not
  `updatedAt`, not `sealed`. `secretreview.confirmDoesNotTouchPayload`
  proves the payload is byte for byte unchanged. `updateEnvelope` stamps
  newly added secrets, so adding is confirming.
- `Seal/Views/SecretReviewView.swift`: the list. "Still right" or "Update"
  per secret, and the interval picker. Reached from a row on the home
  screen under the envelopes, which turns orange when a review is owed.
- The editor shows the age under each secret.

Files: `Seal/CheckIn/CheckInIntent.swift`, `Seal/CheckIn/CheckInShared.swift`,
`SealWidget/*` (all new), `Seal/Estate/SecretReview.swift` (new),
`Seal/Views/SecretReviewView.swift` (new), `Seal/SelfTest/SecretReviewTests.swift`
(new), `EstateEngine.swift`, `EstateModels.swift`, `HomeView.swift`,
`EstateHomeView.swift`, `EnvelopeEditorView.swift`, `ContentView.swift`,
`SelfTestRegistry.swift`, `Seal.entitlements`.

Most likely to fail to compile, in order: `AppShortcutsProvider`
(`appShortcuts` must be a `static var` with `@AppShortcutsBuilder`
semantics; if it complains, wrap the single `AppShortcut` in `[ ]`);
`static var description = IntentDescription(...)` on the intent; the
widget's `containerBackground(for: .widget)`; `Picker` with
`.pickerStyle(.segmented)` on the dark sheet is a look problem, not a
build problem. The App Group will fail at RUNTIME (widget shows "Not
sealed yet" forever) if step 3 or 4 above was skipped.

## What landed on 2026-09-16

The five features from the handoff brief, then the known-problem list:

1. `OwnerNotices`: the owner is reminded to open the app at half, four
   fifths, and a few days before their silence window. Scheduled after
   every heartbeat and replaced on the next; nothing is posted while the
   app is open.
2. `Estate.publishedCustodianDevices`: a key holder who replaces their
   phone is noticed on refresh and named on the home screen, with "Seal
   again" one tap away. Only for estates sealed after this landed.
3. `LetterSecretScan` plus `Seal/Cards/Wordlists`: a recovery phrase or a
   private key typed into the letter gets one quiet line and one tap to
   move it into a secret. Every BIP39 language, SLIP39 (Trezor), Monero.
4. `LetterReview`: on-device "Check the letter for gaps". Letter only, by
   type. Suggests, never edits. Fail closed without the model.
5. `FamilyPreviewView`: "What your family sees" from the home screen and
   "See it as Karen sees it" from the editor. It IS `RevealPager`, the
   recipient's real screen, so it cannot drift. Drag to reorder is in its
   toolbar. Reading it exposed that the reveal showed secrets in the
   clear; `AppLock.confirmReveal` now gates them, as the site promised.

Then: the interview sheet trap (present from `onDismiss`), the follow-up
gated on the letter target, `keepEdges` for split secrets, two more
scrolling screens, no mascot on the People or History screens, the
messenger's dead code removed, `NotificationsOffCard` when a phone that
matters has notifications denied, and the stale ML-KEM warning in GOTCHAS.

## What is blocking (besides the build)

1. **The CloudKit schema.** `EstateEvent` (with `estate` QUERYABLE) must
   exist in Development and be deployed to Production.
   [docs/CLOUDKIT_DEPLOY.md](docs/CLOUDKIT_DEPLOY.md). Only Nathan can do this.
2. **Every phone must sign in once** on the new build so its endorsement is
   republished with the hybrid KEM bundle.
3. ~~The site and the store listing still describe a messenger.~~ Rewritten
   2026-09-15 evening (`20beefc`, `37274d1`, `71a1921`).
4. **A timestamp authority** is still FreeTSA, chosen for being free. See
   [docs/RECORD.md](docs/RECORD.md) section 13.
5. **The domain says "messenger", and the window to change it closes at
   TestFlight.** Decided on 2026-09-15 to leave it and revisit after the story
   has been walked on a phone. Written down here because "not yet" turns into
   "too late" on its own.

   Two separate things wear that name. The **relying party ID** is a
   cryptographic identifier: every credential on every security key is scoped
   to the exact string `sealmessenger.com`, and WebAuthn has no rename path,
   so changing it means every identity registers again from scratch and every
   person is met in person again to re-pin their key. Today that is three
   people. After the first outside tester it is a migration that cannot be
   run. The **marketing domain** is free and can be changed any time, because
   nobody types a relying party ID.

   The cost of leaving it: iOS shows the relying party ID on the system sheet
   during the key ceremony, so somebody setting up their will reads the word
   "messenger" at the exact moment they most need to understand what they are
   agreeing to. It is also in the invite text (`FriendsView.inviteURL` and the
   invite message) and printed on the shareable card footer in `ForgeLogView`.
   Those three are ordinary copy and can be changed without touching identity.

   **Decide before the first TestFlight build goes out, not after.**

## What was done on 2026-09-15, by phase

0. The uncommitted 2026-08-28 tree committed as it stood.
1. Four security fixes with tests: root key pinning (`KeyPinStore`),
   WebAuthn context enforced, unsigned `revokedAt` removed from the type,
   v2 endorsement accepted only at canonical lengths.
2. `Clock` protocol, `SystemClock`, `SimulatedClock`, threaded through.
3. Shamir over GF(256) with Python vectors, the hybrid X25519 plus
   ML-KEM-768 bundle, the Estate Key hierarchy with recipient isolation.
4. Data model and the signed, hash linked estate log.
5. The pure release state machine, exhaustively tested.
6. CloudKit record types and the `EstateEngine`.
7. The messenger removed (`git rm`, history kept).
8. The screens: home, envelope editor, policy, person, guarded estate,
   reveal, time travel.
9. The capsule export, `docs/CAPSULE.md`, `tools/verify_capsule.py`
   (tested against a synthetic capsule and a real OpenSSL RFC 3161 token).
10. Docs rewritten; superseded docs in `docs/archive/`; em dashes removed
    from every tracked file outside the archive.

## Judgement calls a human should review

Listed in the final report of the conversion session and repeated here:

- **Recipients must be Seal identities** met in person. No "whoever opens
  it" envelope exists. PRODUCT.md section 8.
- **The Estate Key is published in the clear at release.** SDS.md section 2
  explains why that is safe; check the argument.
- **Custodians pin each other's root keys from the owner's signed epoch
  statement** (transitive trust through the owner).
- **After a veto, a new claim may open immediately.** RELEASE.md section 8.
- **Authorization taps do not require user verification** by default.
- **The record is a hash linked graph, not a chain**, because there is no
  server to order concurrent writers.
- **Tests are in the app target** rather than a test target.
- **The invite record is addressed by hash in the clear**, so the directory
  can see that a hash has some part in some estate.
- **`Message`, `SealGroup`, `SenderChain` and the message transport in
  `SyncEngine`** were left as dead code after phase 7 and removed on
  2026-09-16 (`a9a12a7`).

## The You screen: done

The 2026-09-15 note about a wall of paragraphs is resolved in the code as
it stands: `SettingRow` puts the long text behind an (i), the hex hashes sit
in a closed "Technical details" disclosure, and the backup keys card is a
heading and a button with its paragraphs behind "What it does". Verified by
reading `ProfileView.swift` and `BackupKeysView.swift` on 2026-09-16, not on
a phone.

## Pricing: decided 2026-09-16, not built

**$29.99, one time, charged on the first seal.** Decided by Nathan on
2026-09-16 after the first Production seal. The reasoning, so it is not
reopened by accident:

- The app stays free to install. Key holders and recipients did not choose
  Seal; the owner did. They must never see a price.
- The owner pays once, at the first tap of "Seal the envelopes". Writing,
  meeting people and holding a key are free. Re-sealing after a change is
  free forever: a person who has to pay to fix a typo in a letter to their
  daughter does not fix it.
- One time, never a subscription. `site/index.html` already says "no
  subscription", and a sealed estate that could break because a card
  expired would be a product that lies.
- Not built until the release story has been walked on Production by two
  phones (claim, keys, open). Nobody pays for the part that has not been
  proven. Built BEFORE the first outside tester, because the first person
  who seals for free is the person you can never charge.

Built 2026-09-16 (`51c9e83`, `2c3db1c`, and the every-seal fix after):
StoreKit 2, one non-consumable product `io.github.jasonepage.Seal.lifetime`,
`SealPurchase` at the app root, `SealPaywallView`. The gate is in
`EstateHomeView.runSeal` and sits in front of EVERY seal: pay once and all
later seals are free, never pay and nothing seals. (The first cut gated on
"has this estate ever sealed", which let any estate that got through once
seal free forever. Do not reintroduce that.) Restore is on the sheet and the
You screen, and "Pay for your seal" is under Help. Demo mode never asks.
Still on Nathan: the product in App Store Connect, the Paid Apps agreement,
and a review screenshot.

## Ideas that are written down, not built

- **The interview that fixes the blank page.** [docs/PRODUCT.md](docs/PRODUCT.md)
  section 11. An on-device question set, and later a model, that helps
  somebody actually write their envelopes, because the way this product fails
  is an empty vault that opens perfectly. Specified on 2026-09-15, to be built
  after the story walks. The build order in that section matters: the plain
  question list first, the model only if the list works.
- **Not a messenger.** Raised on 2026-09-15 and declined the same day. The
  messenger was retired in phase 7 and that is the reason the app has one
  sentence. Adding chat back drags in App Review's user-generated-content
  obligations and costs the kitchen-table pitch. `SealedCard` is already the
  one-way signed statement if something needs sending before a death; grow
  that instead of `Message`.

## Before you debug anything

[docs/GOTCHAS.md](docs/GOTCHAS.md), including the new section at the bottom.

## Working style

Numbered steps for ops tasks. Concise replies. No em dashes anywhere. Commit
after each working milestone, and check `git status` first. Mom is a tester.
