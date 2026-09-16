# Where Seal stands

**Updated:** 2026-09-16 (night: the review fixes) · **Owner:** Nathan (Jason Page) · natepage67@gmail.com
**Repo:** `~/Documents/GitHub/Seal` · iOS 26.5+, SwiftUI, no backend

New Swift files under `Seal/` join the target automatically (file system
synced groups), so no project edits are needed to add one.

## THE REVIEW FIXES (2026-09-16 night, UNCOMPILED)

`docs/REVIEW.md` found two things; both are built. Not committed.

- **Finding 1, backdated claims.** `Seal/Estate/FirstSeen.swift` (new):
  a per-engine table of when this phone first saw each event id
  (keychain `seal.firstseen.<storeHash>`, wiped by `EstateStore.wipe`).
  `EstateEngine` loads it in `init` (seeding once from the events already
  there, at their own time), calls `noteSeen` after every merge (own
  events at their own time, fetched events at `clock.now`), and hands
  `firstSeen.timeOf` to both `ReleaseFeed.snapshot` calls in
  `recomputeAll`. Claims and taps are clamped; heartbeats are not.
  `ReleaseMachine`, `ReleaseFeed`, `EstateLogVerifier` untouched.
  Tests: `FirstSeenTests`, registered.
- **Finding 2, sealing after a release.** `sealAndPublish` throws
  `notAllowed` when `ownerSnapshot?.releasedAt != nil`.
  `EstateEngine.startNewSet()` makes a fresh estate (new id, empty
  envelopes, the rule and the people carried across, old media removed,
  the old log dropped from this phone). The released status card gets
  "Start a new set of envelopes" with a confirmation in `EstateHomeView`.
- GOTCHAS: three new lines (findings 1, 2 and 3).

Most likely to fail to compile: `timeOf: firstSeen.timeOf` (a method
reference on a struct property; if it complains, write `{ self.firstSeen.timeOf($0) }`);
`EstateEvent` memberwise init in `FirstSeenTests.event` (argument order
follows the declaration: id, estateID, kind, actorHash,
actorDevicePublicKey, occurredAtEpoch, previousDigest, payload,
signature, timestampToken).

How to test: `FirstSeenTests` runs at launch. On phones: two phones,
Time Travel the owner past the silence, claim from Mom's phone; the
owner's phone must show the warning card today, not "keys can be
tapped". For finding 2: run a release with Time Travel, then on the
owner's phone the status card shows "Start a new set of envelopes";
tapping Seal before that says the set cannot be sealed again.

## ATTACH A FILE, AND "READ IT FOR ME" (2026-09-16 night, UNCOMPILED)

PRODUCT.md section 12 is the design, written and built the same evening
on Jason's "build it, go with your gut". Not committed.

**What changed.**

- `MediaItem.Kind` gains `.file`; `MediaItem.fileName: String?` (nil for
  photos, voice, video) and `fileExtension`. `Envelope.files` and
  `Envelope.Payload.files`, both `decodeIfPresent` in the hand written
  decoders, both in `allMedia` so the engine encrypts, uploads and
  removes them like a photo. `contentsSummary` counts them.
- `EstateEngine.attachMedia` takes `fileName:`; the `switch` over the
  kind has the new case. `EstateEngines.move` carries files across.
- `Seal/Estate/FileReading.swift` (new): `FileReader.text` (PDFKit page
  by page with a "[page N]" line each, or plain text), `pieces` (about
  3,000 characters, page lines kept), `steps` (the on-device model, the
  same `OnDeviceDrafter.respond` and `houseStyle` the interview uses, up
  to eight `ProposedStep`s), and the two `@Generable` shapes `ReadStep`
  and `ReadSteps` behind `#if canImport(FoundationModels)`. No model on
  the phone means no steps and no button; the file still attaches.
- `EnvelopeEditorView`: a "Files" card after Photos (system file picker
  via `.fileImporter`, 50 MB ceiling, security scoped read, one file at
  a time), each file with a remove button and, when the phone can read
  it, "Read it for me": a sheet that reads on the phone and lists the
  proposed steps with ticks; "Add N" appends them to the envelope's
  "what to do first" list. Nothing is written until Add.
- `RevealView`: files show after the photos as a row; tap opens the
  system viewer (`.quickLookPreview`), share once loaded. The owner's
  preview gets the same through `RevealPager`.
- Tests: `Seal/SelfTest/AttachedFileTests.swift`, registered: payload
  round trip with names, an old payload and an old photo item decode,
  the media list and the vault commitment include the file, extension
  rules, piece cutting keeps page lines and the cap, plain text reading,
  a proposed step becomes a `FirstStep` within the limits. The model is
  not called in tests.
- Docs: PRODUCT.md section 12 (build order amended), GOTCHAS.

**Not changed:** the crypto, the machine, the record, CloudKit (a file
is a `MediaAsset` blob like a photo), the capsule format beyond the
additive `files` key in a payload nobody outside the recipient decodes.

**Most likely to fail to compile**, in order:

1. `.fileImporter(... allowedContentTypes: [.pdf, .plainText,
   .commaSeparatedText, .json, .zip, .image, .data] ...)`: needs
   `import UniformTypeIdentifiers` (added); if `.json` or `.zip` are not
   `UTType` statics on this SDK, drop them, `.data` covers everything.
2. `.quickLookPreview($previewURL)` needs `import QuickLook` (added).
3. `@Generable struct ReadSteps { var steps: [ReadStep] }`: an array of
   a `@Generable` type inside another. If the macro objects, flatten to
   five optional step fields or ask for one step per call.
4. `MediaItem` memberwise init now has a trailing defaulted `fileName`;
   the engine builds it without it and sets it after (`var item`).
5. `ProposedStep: Hashable` with `let id = UUID().uuidString`.
6. In `AttachedFileTests.oldPayloadOpens`, `sha256` as `"AAAA"` (base64
   for three zero bytes).

**How to test.** Build. Open an envelope, Files, Attach, pick a PDF from
Files or iCloud Drive. The row shows its name and size. On a phone with
Apple Intelligence on, "Read it for me" appears: tap it, wait, tick the
steps, Add. The steps card grows by that many, each note ending in
"(page N)". Seal. On the recipient's phone after a release (Time
Travel), the file row is under the photos; tap opens it; the share
button appears once it has loaded. What your family sees (the preview)
shows the same row. A phone without the model: attach works, no Read
button, and the caption says only "Sealed like a photo."

## A RULE PER ENVELOPE, STEPS 1 AND 2 (2026-09-16 evening; step 1 built clean, step 2 UNCOMPILED)

RELEASE.md section 13 is the design. Step 1 (the engine list, RuleBook,
the inbox across rules) compiled and ran on Jason's phone. Jason then
asked for the cut he had in mind: rules live on the envelope, and the
Keys tab is about people, not rules. Step 2 does that. Not committed.

**What step 2 changed.**

- `Seal/Views/RuleSheet.swift` (new): one sheet for everything about
  rules. One card per rule: name (rename and delete behind the ellipsis),
  the numbers in a sentence, who holds a key, "Numbers" (opens the
  existing `PolicyView`), "Key holders" (tick people met in person;
  `addCustodian` / `removeCustodian` on that rule's engine), and, with
  an envelope in hand, "Use this rule for the envelope" with the
  warning that both sets need sealing again. "Make a new rule" at the
  bottom, hidden at three. Reached from the editor's "When it opens"
  card and from the Envelopes menu as "Your rules".
- `EnvelopeEditorView`: a "When it opens" card between the secrets and
  "Open on a date" (only when `engines` is passed; every other caller is
  unchanged). It shows the envelope's rule in one line and "Change"
  opens the rule sheet. `onMove` is handed in by the home screen.
- `EstateEngines.move(_:from:to:)` (RuleBook.swift): a fresh envelope in
  the target rule (new id, new content key, because the old key sat in
  the old rule's tables), the words carried over, every photo, voice and
  video decrypted under the old rule and attached again under the new,
  the old copy removed only after everything landed, and the old rule
  marked `tablesStale` so its next seal publishes its tables without the
  envelope. `EstateEngine.adopt(_:recipient:)` and `markTablesStale()`
  are the two engine doors. `Estate.tablesStale` is a new stored
  property with a default, decoded with `decodeIfPresent` and counted in
  `hasUnsealedChanges`, cleared by the seal.
- `EstateHomeView`: the Keys tab is people. `EstateEngines.keyHolderRows`
  folds the custodians of every rule into one row per person with
  "Holds a key for Your rule and Sooner" when there is more than one
  rule; the row opens `PersonView` on the default rule's engine when
  they hold that one. "Add a key holder" picks the person, then asks
  which rule when there is more than one. No rule headers, no "The
  rule" buttons, no "Add a rule" on Keys. `EnvelopeRef` has a stable id
  so the editor sheet stays up through a move. The setup card's "Set
  your rule" still opens `PolicyView` for the default rule.

**Not changed:** the crypto, `ReleaseMachine`, `ReleaseFeed`,
`EstateLogVerifier`, `EstateEvent`, CloudKit, the capsule, `PolicyView`,
`PersonView`, `FriendsView`, `CoupleSetupView`, `GuardedEstateView`, the
project file.

**Still on the default rule only:** new envelopes start there (move
them from the card); "Your saved secrets", "What your family sees" and
Time Travel read it; People's "Make them a key holder" adds to it.

**Most likely to fail to compile**, in order:

1. `EnvelopeEditorView`'s new trailing parameters `engines:` and
   `onMove:` after `ownerName:` (the call in `EstateHomeView` passes
   them in that order; the memberwise init follows declaration order).
2. `Estate.tablesStale`: the `Keys` enum in the `Estate` decoding
   extension gained `case tablesStale`; the synthesized `encode(to:)`
   uses the synthesized CodingKeys, which include it automatically.
3. In `RuleSheet`, `current === engine` (both `EstateEngine?` and
   `EstateEngine`; if it complains, write `current.map { $0 === engine } ?? false`).
4. `confirmationDialog` with a `ForEach` over engines for the "which
   rule" question in `EstateHomeView`.
5. `EstateEngines.move` uses `Envelope.unbound(name:title:now:)` and
   `Envelope.new(...)`, then assigns `firstSteps`, `secretConfirmations`,
   `openNoEarlierThan`; all are `var`s on `Envelope`.
6. The `card(...)` helper in the editor with a `Text` and an `if` in its
   content closure (the same shape the other cards use).

**How to test.** Build. Envelopes tab: open an envelope, scroll to "When
it opens": it names your rule and its key holders. Tap Change: the rule
sheet, your rule marked as this envelope's. Tap "Make a new rule", keep
Sooner, Add: the numbers screen opens with 30, 7, 0; Done. On the Sooner
card tap "Key holders" and tick Karen. Tap "Use this rule for the
envelope", confirm: the sheet's marker moves to Sooner; Done; the card
now says "When it opens: Sooner". Back on the inbox the row carries a
Sooner tag and the Seal bar says two envelopes (or "Seal again" for the
old rule). Seal. Keys tab: one Karen row, "Holds a key for Your rule and
Sooner". On Karen's phone, For others shows "Jason" and "Jason (Sooner)".
Time Travel past 30 days on Karen's side and the Sooner claim can start
while the letters cannot. Envelopes menu, "Your rules": the same sheet
with no envelope marked.

## THE FIRST MINUTE, REDONE (2026-09-16 evening, UNCOMPILED)

Written through the file bridge (the Mac shell would not start). Nothing
here has been built. Not committed.

The onboarding was written before most of this week's features existed.
Same bones (two shared screens, a fork by role, one figure per screen,
skippable, re-openable, Chapters menu), new content, two new paths.

**What changed.**

- "Which one are you?" has four choices: Just me, Me and my partner, I was
  handed a key, Someone wrote me an envelope. `OnboardingRole` gains
  `.couple`; `.sealer` is unchanged, so every caller compiles as it was.
- The two sealer paths are one script builder (`sealerScreens`) with an
  id prefix (`s.` and `c.`), so the copy exists once. Just me is eleven
  screens after the fork; the couple path is twelve (it adds "Two phones"
  and swaps the keys screen for "One more key holder each", and its
  checklist says what happens on each phone). Between them they teach:
  the envelope and its parts, the seed phrase catch, the check-in with
  Siri and the widget, the rule, one tap stops it, who opens what, the
  arithmetic, key holders met in person with the yearly tap and the
  printed page, the backup key and why there is no email reset, bills
  and medical, envelopes that wait (typed name, sponsored key in one
  line, open on a date said exactly, the delete question), and the price.
- The price screen reads `SealPurchase.displayPrice` from the environment
  (`@Environment(SealPurchase.self) private var purchase: SealPurchase?`,
  optional so previews and any tree without the store do not crash) and
  falls back to "The price is shown before you pay." No number is typed
  anywhere. Key holders and recipients never see a price.
- Key holder path: four screens, tightened, plus the yearly tap and the
  printed page on the keep screen. Fixed two old wrong sentences: at a
  threshold of 1 with several key holders the title said "You are the only
  one" (now "Any one of you can act"), and the curve screen said "1 points
  fix the line" (now its own honest screen at a threshold of 1). "All
  three of you" and "both of you" at a threshold equal to the count.
- Recipient path: three screens, tightened. No longer says the envelope
  opens "after the person is gone" as a fact; says "after a long silence"
  and "after their key holders act" (PRODUCT.md section 8).
- `OnboardingNumbers.custodyConfirmMonths` (defaulted, read from the real
  policy when there is one) and `custodyConfirmLead` ("Once a year,"), so
  the yearly tap is never a typed number. `anyMofN` says "all 3" instead
  of "any 3 of 3". The timeline legend no longer says "0 more quiet days"
  or "1 days".
- Two new figures in `OnboardingFigures.swift`: `TwoPhonesFigure` (two
  phones, a key crosses each way, brass on landing because the handover
  is a receipt) and `SpareKeyFigure` (the key in use, a spare slides in
  behind it). Animate once, Reduce Motion shows the finished state.
- Every figure has an accessibility label in words
  (`OnboardingScreen.Figure.accessibilityLabel(_:)`), applied on the
  figure in `SealOnboardingView`.
- Skip, Back, Next and the role buttons all carry `parentTapTarget()`.

**Files.** `Seal/Views/Onboarding/SealOnboardingView.swift` (rewritten),
`Seal/Views/Onboarding/OnboardingFigures.swift` (numbers struct, legend,
two figures added; the four old figures untouched),
`Seal/SelfTest/OnboardingCopyTests.swift` (new),
`Seal/SelfTest/SelfTestRegistry.swift` (one line), this file. Not touched:
`SealMark.swift`, `GuardedRoleCard.swift`, `RegistrationView`,
`ProfileView`, `EstateHomeView`, `CoupleSetupView`, `SponsoredKeyView`,
the paywall, the store, any engine, the project file.

**Tests.** `OnboardingCopyTests`, registered: every title, body, step,
role button and figure label, at thresholds 1 to 3 and key holder counts
1 to 3, real and default numbers, with a price and without, has no em
dash, no "custodian", no whole word "will", no double space, no "1 days"
or "0 days"; every path has at least three screens and ends on steps
(sealer paths) or keep (key holder, recipient); ids are unique and do
not move with the numbers; the price sentence reads right with a price
and with nil and never leaks to a key holder or recipient; at a
threshold of 1 no key holder screen says "does nothing" or "cannot open
anything"; above 1 it does.

**Most likely to fail to compile**, in order:

1. `@Environment(SealPurchase.self) private var purchase: SealPurchase?`.
   If the compiler rejects the optional form, make it non-optional and
   inject `.environment(SealPurchase())` in the four `#Preview` blocks.
2. `OnboardingScreen.Figure` now has an associated value case AND plain
   cases with `isSteps` / `isKeep` written as one-line `if case`. If it
   complains, expand them to a `switch`.
3. `String + Substring` in `OnboardingScript.word(_:capital:)`; it is
   wrapped in `String(...)` already, but if it still complains, build it
   with `.capitalized`.
4. In the tests, `for price in [fakePrice, nil]` infers `[String?]`; if
   not, write `[String?]` explicitly.
5. `TwoPhonesFigure` uses `.position` inside a `GeometryReader`; if the
   phones overlap oddly at Bigger text, the figure height (170) is the
   knob.

**How to test on a phone.** Delete the app (or clear `seal.welcomeSeen` by
signing out and reinstalling). Launch. The onboarding shows before
registration. Walk all four paths from "Which one are you?", then open
Chapters and jump into the middle of each. Then register, and check the
backup key prompt still appears after sign-up (untouched, but the copy
now promises it). Then You, Help, "How Seal works" (opens at the front).
Then on a key holder's phone, For others, "See how it opens" (opens on
the key holder path with that estate's real numbers; with a threshold of
1 the titles change). Turn on Bigger text in You and open it again from
Help: every screen scrolls, nothing drags sideways, the role buttons and
Next are tall. Turn on Reduce Motion in Settings, Accessibility, Motion,
and page through: every figure shows its finished picture at once.

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

## DELETING AN ACCOUNT THAT HAS ENVELOPES (2026-09-16 afternoon, UNCOMPILED)

Jason asked what happens to Karen's envelopes when she deletes her account.
The answer was: it depended on an accident. If her delete managed to flip
her live record, every key holder's and recipient's phone failed the owner
lookup, "What has happened" froze, and a release could never be accepted
(stuck forever). If the flip failed (record created by another iCloud
account), everything carried on as a plain silence and the envelopes
opened, although the delete screen promised "ALL data is destroyed".
Nobody was ever told she left. Jason chose: **ask the owner**, and **sign
the delete marker**.

What was built:

- **The question.** `ProfileView`'s delete dialog, when anything is sealed,
  offers "Delete, and keep my envelopes for my family" or "Delete, and
  cancel my envelopes forever". Deleting now takes one tap of the key.
  `ProfileView` takes `urgentEngine` (HomeView passes it) so both sets are
  covered.
- **The entry.** New owner event kind `ownerDeparted`, body
  `DepartureBody { keepEnvelopes, departedAtEpoch }`, written by
  `EstateEngine.announceDeparture` straight to the directory (and stamped)
  before the marker and the wipe. Admitted as an owner kind by
  `EstateLogVerifier`; `ReleaseFeed` passes over it (it still moves the
  silence anchor like any owner entry); `ReleaseMachine` untouched;
  `RecordEvent`, `RecordView`, `tools/verify_capsule.py`,
  `docs/CAPSULE.md` know the kind. Old builds drop the entry unread.
- **What it means.** `Seal/Estate/DepartureRules.swift` (new). Keep: the
  rule runs its course; the key holder's screen shows the earliest claim
  date (entry + silence) and the earliest opening (plus warnings and
  grace). Cancel: the owner's phone deletes every sealed blob it uploaded,
  and `EstateEngine.openClaim`, `authorize` and `release` refuse. A cancel
  beats a keep. A later owner heartbeat voids the entry (the delete did not
  finish). A release that already happened stays opened.
- **The screens.** `GuardedEstateView`: an orange card first, "Karen
  deleted her Seal account", with the dates or "They can never be opened";
  the status, custody and action cards hide when cancelled; the history
  line reads "Karen deleted their Seal account and kept the envelopes for
  their family." (or "cancelled the envelopes."). "A custodian" in that list
  is now "A key holder". The For others row says the same in one line.
- **The record no longer freezes.** `deleteIdentity` flips the tier but no
  longer scrubs device endorsements. `SyncEngine.fetchIdentityForHistory`
  reads a deleted record only when this phone pinned that key, and
  `EstateEngine.refresh` falls back to it (`ownerForHistory`). Owners
  deleted by an older build (Karen's test) had their endorsements scrubbed,
  so their record stays frozen on other phones; delete and re-test.
- **Signed delete marker.** `Seal/Identity/TombstoneProof.swift` (new): the
  owner's tap over SHA256("seal.identity.delete.v1" || nonce), stored in
  the marker's existing `revocations` field. `isTombstoned` and the
  directory scan count a marker only when the proof verifies under the
  pinned key or the live record's key (or when no identity exists to
  protect). `CeremonyManager.signDeletion` makes the tap; the retire
  ceremony's tap now uses the same challenge and is stored as the proof.
  Unsigned markers from older builds count only on the phone that wrote
  them, or where the live tier was flipped. No schema change.
- **Tests:** `Seal/SelfTest/DepartureTests.swift`, registered: only the
  owner's key makes a marker count (stranger, wrong hash, other challenge,
  other website all refused); only the owner can write the entry; keep,
  cancel wins, garbled reads as cancel, a later check-in voids it; the
  dates follow the rule and the machine is unchanged.
- Docs: `docs/RELEASE.md` section 11 (old 11 is now 12), `docs/GOTCHAS.md`.

Most likely to fail to compile: `markers.updateValue(... as? Data, forKey:)`
on a `[String: Data?]` in `BackupDirectory.swift`; the `Text(departure.map {
... } ?? ...)` in `EstateHomeView.forOthersRow`; `for n in 1...e.epoch` with
`UInt64`.

How to test: two phones on this build. Mom seals an envelope for you with
you as key holder. On Mom's phone: You, Delete identity, pick keep, tap
Face ID. On yours: For others, Mom's row says she deleted her account and
kept them; open it and see the orange card with two dates and the new
line in "What has happened". Repeat with cancel on a fresh identity:
the card says they can never be opened and the claim button is gone.
Time Travel past the silence on the keep case and the claim button appears.

## TWO BUGS: REVOKE AND DELETED PEOPLE (2026-09-16 midday, UNCOMPILED)

Written through the file bridge (the Mac shell would not start). Nothing
here has been built. Not committed.

### Bug 1: "Revoke device" in You did nothing

Causes found, all fixed:

1. `CeremonyManager.revokeDevice` sent both providers in one request, so a
   passkey owner got the security key sheet and cancelled. Now one
   provider by the owner's tier (the earlier session's edit, confirmed on
   disk and read through). `revokeBackupCredential` in
   `BackupKeyCeremony.swift` had the same two-provider bug; fixed the same way.
2. `ProfileView` swallowed errors with `try?`. Now do/catch with a "Could not
   revoke" alert (earlier session's edit, confirmed). A cancelled tap shows
   no alert.
3. **Creator-only write.** `SyncEngine.publishRevocation` saved into the
   Identity record, which only the iCloud account that created it may
   modify. It now always writes a side record: type `GroupInvite`, random
   name `rvk.<hash>.<uuid>`, `recipient` = `revoke.<hash>`, `payload` = the
   `DeviceRevocation` JSON. It still also tries the Identity record's own
   list (works for the creator; older builds read only that). Random name
   on purpose: a predictable name could be created first by a stranger and
   block the revocation. `fetchSideRevocations` reads every page (capped at
   20 pages). `fetchIdentity` and `fetchDeviceList` merge the side list in.
   Every revocation still has to verify under the ROOT key
   (`revokedDevicePublicKeys`), so junk records do nothing. The unsigned
   `revokedAt` field stays gone. No new record type, no new field; it
   relies on the `recipient` QUERYABLE index that invites already need.
   `fetchIdentity` now throws if that query fails (fail closed).
4. `revokeDevice` now verifies the tap against the root key before
   publishing, and if the saved root has no `rawCredentialID` it asks the
   directory once before throwing `missingCredentialID`. On a phone that
   signed in normally the ID is there: `fetchIdentity` reads the
   `credentialID` field and sign-in saves that root.
5. The Profile list could still say "not revoked" for a few seconds
   (query index lag). `ProfileView.revokedHere` shows it revoked at once.

Known limit, not fixed: `publishIdentity` has the same creator-only rule,
so a phone signed into a DIFFERENT iCloud account than the one that first
published the identity cannot add its own endorsement. That phone would not
be in the device list to begin with.

### Bug 2: a deleted person still showed in People

- `Friendship.tombstonedAt: Date?` with a hand-written `init(from:)` in
  `Models.swift` (decodeIfPresent for every later field).
- `FriendStore`: `markGone`, `goneMarks`, `goneDate`, `lastGoneCheck`, and a
  small ledger (`seal.gone.<hash>`) so the mark outlives "Remove from
  People" and covers key holders with no friendship. `FriendStore.wipe`
  clears both new keys.
- `Seal/Identity/GoneCheck.swift` (new): `SyncEngine.accountState` (the live
  record's tier flag first, then the `tomb.<hash>` marker; throws when
  offline, so nobody is marked by a blip), `FriendStore.refreshGone`
  (friends plus the key holders and recipients of BOTH slots; at most once
  a day unless forced; the day only resets after a full pass), and the pure
  estate helpers: `Envelope.isUndeliverable(gone:)`,
  `Estate.undeliverableEnvelopes`, `Estate.goneCustodians`,
  `CustodyConfirmation.goneStanding` and `.unresponsive`,
  `EstateEngine.custodyStanding(for:gone:)`, `.unresponsiveKeyHolders`,
  `.reassignEnvelope`.
- People (`FriendsView`): pull to refresh, plus the daily check on appear.
  A gone row loses the badge, greys out, says "Deleted their Seal account.
  Found <date>." Its press-and-hold menu has "Remove from People" (the
  friendship only). The ordinary Remove now clears the key holder from both
  slots. Role text says "Key holder".
- `PersonView`: an orange banner at the top; the key holder card becomes
  one line and "Stop being a key holder" (both slots); no handover, no
  printed page, no "make them a key holder"; "Remove from People" with a
  confirmation. Leftover "custodian" copy there is now "key holder".
- Envelopes inbox: an undeliverable row says "Karen deleted their Seal
  account. This envelope cannot be delivered." Press and hold: "Give it to
  someone else" (the existing picker, gone people hidden) or "Delete this
  envelope" (with a confirmation). A seal with such an envelope still
  fails until the owner deals with it; that is the old behavior.
- Keys tab: an orange box above the rows counts unresponsive key holders
  (overdue or gone), says how many are gone, and warns when fewer can
  help than the rule needs. The row greys out and uses the gone line.
  `ReleasePolicy` is never changed by any of this.
- Also runs once a day from `EstateHomeView.task`, for both slots.
- Not touched: ReleaseMachine, ReleaseFeed, EstateLogVerifier. No new
  CloudKit record types. `docs/CLOUDKIT_DEPLOY.md` step 7 notes that
  revocations now use the `GroupInvite` index too.
- Tests: `Seal/SelfTest/GoneAccountTests.swift`, registered. Old JSON
  decodes and is not gone; the mark survives a reload and a removal; a
  gone recipient makes the envelope undeliverable; a gone key holder is
  counted.

Most likely to fail to compile: `catch CeremonyManager.CeremonyError.cancelled`
in ProfileView (if it complains, use `catch let e as CeremonyManager.CeremonyError where e == .cancelled`,
the enum has no payloads); the `let role: String? = switch` expression in
FriendsView; `init(from:)` in the `Friendship` extension.

### How to test

Bug 1: on a phone with two devices on the identity, You, the minus next to
the other device, Revoke device, Face ID or key. Expect the row to strike
through at once and stay struck through after reopening You.
Bug 2: on the owner phone, pull down on People after the other phone
deletes its identity. Expect the row to grey out and say the account was
deleted.

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

## FOR OTHERS: a fourth tab (2026-09-16, UNCOMPILED)

Jason's call: what this phone holds for other people is its own tab,
"For others", shown only when `lettersEngine.guarded` is not empty. One
compact row per person (name, the part held, the state line, lit when
the state needs this person), tap for `GuardedEstateView`, one "See how
it opens" button. `guardedSection` and its cards are gone from the Keys
tab. A phone that only holds things for others opens on that tab.

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
