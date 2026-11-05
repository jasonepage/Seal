# Changelog

Dates are the day the work landed in the repository. Anything marked
"not built yet" has been written but never compiled or run on a phone.

## 1.3, Harbor mascot (in development)

### Added

- A rule now says when it opens (PRODUCT.md section 17): **When I go quiet**
  (as before, now with 7 and 14 day silences for people who need a short
  fuse), **Break glass** (instant: any M key holders together, on any day, open it
  the moment they tap; the owner is told and cannot stop it), or **Right away** (a message
  in a bottle: opens for its recipient the moment it is sealed, on the phone
  and at sealmessenger.com/open, with no key holders). Right away rules seal
  for free. Builds in the simulator; not yet run end to end on a phone. (`ReleasePolicy.Kind`, `EstateKeys.wrapTableDirect`,
  `EstateEngine.sealAndPublish`, `PolicyView`, `site/open/js`)
- Harbor, an old and patient seal drawn entirely in SwiftUI. Harbor breathes,
  blinks, listens, protects a sealed envelope and can release one carefully.
  Reduce Motion always gets a complete still pose, and each animation settles
  instead of running forever. (`Seal/Views/SealMascot.swift`)
- Harbor now welcomes an empty envelope list, appears on the final onboarding
  steps, and protects the envelope in the confirmation shown after a successful
  seal. He remains absent from key, identity and release decision screens.
  (`EstateHomeView.swift`, `SealOnboardingView.swift`)
- The Harbor motion studies, placement sheet and native animation rules live in
  `docs/design/harbor/`.
- Harbor shows the one next step on the quiet home screen, once everything is
  sealed: a key handover nobody recorded, then a key holder whose yearly check
  is overdue, then a backup key. One at a time, and nothing while something is
  unsealed. He also sits in the corner of the setup card.
  (`EstateHomeView.nextStep`, PRODUCT.md section 16)
- "Read it to me" under an opened letter: the phone's own voice reads the title
  and the letter, never the secrets. It plays with the ring switch on silent,
  follows the Spoken Content voice and speed when one is set, and stops on a
  page change, on close and when the app leaves the foreground.
  (`Seal/Views/LetterReader.swift`, `RevealView.swift`)
- An "I'm still here" button on every check-in reminder. It opens the app,
  exactly like the Siri and widget check-in, and asks for Face ID or the
  passcode first on a locked phone. A plain tap on the reminder now also ends
  with "You are checked in." (`OwnerNotices.registerCategories`, `SealApp.swift`)
- "See what your family sees" in plain sight: under the envelope list, and on
  the sealed confirmation. It was only in the "..." menu before.

- The owner is now really warned every day during a claim. Every screen told
  key holders this, and nothing on the owner's phone did it. When a refresh
  finds a live claim on one of the owner's own rules, the phone says so at once
  and schedules one line a day until keys can be tapped (at most 21), each with
  the "I'm still here" button. A heartbeat takes them off. Separately, seven
  daily lines are scheduled for the week after the quiet period ends, so a
  claim is loud even if its push never wakes the app.
  (`OwnerNotices.postClaimWarnings`, `OwnerNotices.afterSilenceLine`)
- Harbor's next step puts a key holder who deleted their account first:
  "Next: replace [name] as a key holder."

- Kit first: "Use a key from your kit" is now the first button when adding a
  key holder, from the setup card. It opens the sponsored key screen, and once
  the key is registered the flow goes straight on to "Make them a key holder?".
  An owner with a kit can finish setup alone in one evening.
  (`AddKeyHolderFlow.swift`, `SponsoredKeyView.onRegistered`)

### Fixed

- A silent push no longer checks the owner in. Before, a push that woke the app
  in the background signed a heartbeat, which cancels a claim, on any unlocked
  phone and always on a phone with no passcode, with nobody looking and around
  the app lock. Now only a foreground refresh checks in; a background one only
  reads the record. (`HomeView.refreshEverything`)
- The owner's button to take someone off their key holders said "Stop being a
  key holder", which reads like the owner quitting. It now says "Take [name]
  off your key holders". (`PersonView.swift`)

### Changed

- First run is three short cards: what Seal is (write it, choose when it
  opens, only the person you wrote to can read it), "Which one are you?",
  and three plain steps for the path picked. New painted artwork, faded
  into the dark background with a round mask so no box shows. The price
  screen is gone from the walkthrough; the price is shown at the purchase
  step. In the full guide ("How it works"), the warnings, backup key, key
  holder and recipient cards keep their fine print behind "Details".
  (`SealOnboardingView.swift`, `OnboardingCopyTests.swift`)
- The envelope editor is a list of short cards that open one at a time,
  each with a one line prompt and a check mark. A new envelope opens on the
  letter. The date card keeps its caveat under "A wish, not a lock".
  (`EnvelopeEditorView.swift`)
- The rule screen is a short wizard: one question per screen, then a
  summary and "Save rule". A quiet rule asks only how long you can go quiet
  and how many key holders must agree; warnings, the extra wait, objections
  and the key check keep their defaults unless you tap "More options". The 7 and
  14 day silence caution and the rule of one caution are still shown.
  (`PolicyView.swift`)
- Plain words where the copy still assumed every envelope opens after death:
  registration, the Keys tab help, the key holder screens, the role card for
  key holders and recipients, and the printed key holder page.
- People: "Invite someone who doesn't have Seal" moved to the You screen as
  "Tell someone about Seal", since it only shares the website. "Register a
  key for someone who is not here" is now "Set up a key for someone". The
  invitation text no longer says "for when I'm gone".
- One Face ID setting instead of two. Seal now always asks for Face ID or
  the passcode before it shows a password or seed phrase (it used to be a
  separate switch, off by default); "Require Face ID" only decides whether
  the whole app locks. (`AppLock.confirmSeal`, `ProfileView`)
- "Bigger text" is gone; iOS Text Size does the same job. A setting saved by
  an older build is ignored, so nobody is stuck with it. (`ParentMode`)
- "Set up with my partner" is gone from the Keys tab; it only sent people to
  People. Couples add each other under People and make each other key
  holders, and the couple walkthrough now says exactly that.
- "Set up a key for someone" and "Add a key holder" link to
  sealmessenger.com/give for people who need a Seal kit. The key screen no
  longer says the key opens nothing "before your key holders release
  everything", which is not true of a Right away rule.
- A profile photo: tap your ring on the You screen to pick one. It shows
  there and on the home screen button, stays on this phone only (keychain,
  this device only, wiped on sign-out), and is never uploaded. It is redrawn
  as a small square, which also drops the photo's location data.
  (`Seal/Identity/ProfilePhoto.swift`, `IdentityRing`, `ProfileView`)
- The You screen is rebuilt for someone who has never heard of keys:
  photo and name with one "Edit name and photo"; a "Protect your account"
  card when there is no backup key (or "Account recovery is ready"); then
  grouped Security, Help, Purchase ("Buy Seal", "Restore purchase"), a
  closed Advanced section (Record, History, timestamps, your words,
  devices, account details) and Account ("Sign out on this iPhone",
  "Delete account") with the consequences in the confirmation dialogs.
  Backup keys have their own page. No change to keys, deletion, purchase
  or sign-out behavior. (`ProfileView.swift`)
- "Already set up a key? Tap it" (People, and Add a key holder): brings back
  someone whose kit key you set up before, after a sign-out or on a new
  iPhone. One tap on their key, checked against their published key and
  this phone's pin. Same person, so envelopes already sealed for them still
  open for them. Before, the only way out was retiring their account, which
  would have locked them out of those envelopes.
  (`CeremonyManager+FindKey.swift`, `FindKeyOwnerView.swift`)
- Check-ins follow you. Before, a new iPhone or a sign-out meant the sets
  you had already sealed never heard from you again, so to your key holders
  you had gone quiet and a "When I go quiet" set could open while you were
  fine. Now every foreground also checks in on every set you sealed
  anywhere: found through a short list of set ids in your private iCloud
  database, and for older sets through the invites sent to your people.
  The contents stay sealed and still cannot be edited on the new phone;
  only the "I am here" line moves. The sign-out message says so.
  (`Seal/Estate/OwnedSets.swift`, `HomeView.refreshEverything`)
- Three rules, one of each kind, from the start: Break glass, Right away
  and When I go quiet (90, 21 and 14 days). Nobody makes or names a rule;
  they pick one for each envelope and change its numbers. Existing rules
  are kept and a missing kind is added while there is room. Rules are shown
  by their kind, the numbers screen no longer asks which kind, and an empty
  rule never counts as waiting to be sealed. A right away rule's card has
  no Numbers or Key holders buttons. (`RuleBook.ensurePresets`,
  `RuleSheet.swift`, `PolicyView.swift`, `Estate.hasUnsealedChanges`)
- A new owner's first rule is Break glass instead of When I go quiet.
  Sets that already exist keep their kind. (`EstateEngine.createEstateIfNeeded`)
- The seal bar no longer shows a dimmed Seal button when a rule has no key
  holder. It says "Break glass needs a key holder first." and its button is
  "Add key holder", which opens the guided flow for that rule.
- A person's page looks across all three rules: their envelopes on any
  rule (each tagged with its rule), their key holder status, and taking
  them off removes them from every rule. Recording a key handover counts
  for every rule they hold a key for, since it is one physical key, so
  Harbor no longer asks to record a handover that was already recorded.
  (`PersonView.swift`, `EstateEngines.KeyHolderRow`)
- A photo of each person you meet: tap their picture on their page to take
  one with the camera or choose one from Photos. It shows on People, their
  page, the envelopes written to them and the key holder lists. It stays on
  this phone only, the person never sees it, and sign-out deletes it.
  (`Seal/Identity/PersonPhotos.swift`)
- "Make Dad a key holder?" no longer says the key opens things only after
  a long silence; it says "when this rule allows", true of Break glass too.
- "Protect your account" and Harbor's "add a backup key" now go away once a
  backup key exists. The phone never stores backup keys (FR-3), and nothing
  read them back after a launch or after adding one, so the prompt stayed
  forever. Every refresh and the backup key page now read them from the
  directory into memory. (`IdentityManager.adoptBackups`)
- Harbor's eyes are smaller and scale with his size.
- `tools/run_core_tests.sh` now compiles with `-default-isolation MainActor`,
  the same isolation the app target uses. Before, Swift 6 reported
  `Clocks.current` as unsafe global state, which it never is in the app.
- Privacy page: the relay paragraph now also says Apple lets the relay delete
  an entry it delivered, as the open page and How it works already did.
- Plain words for the lines that were still technical: "Revoke device" is
  "Remove device", "Delete identity" is "Delete my account", "identity" is
  "account" wherever a person reads it, "key shares" are "key pieces", and the
  record screen, the key holder rule card, the export sheet and the backup key
  screen were rewritten to be read aloud. 36 lines in 12 files.
- The sealed confirmation is a full sheet now, so its two buttons fit with
  Bigger text on a small phone.

## Web 1.2b, key holders on the web (live 2026-10-17)

### Added

- Key holders with a security key registered for them can confirm they
  still have their key, start a claim, object, withdraw, tap, and combine,
  at sealmessenger.com/open, Android included (PRODUCT.md section 15,
  1.2b). Same guards as the phone, signed by their own device key.
- The relay, `worker/index.js`, on the Worker that serves the site:
  checks each entry the way a phone would, stamps claims, taps and
  releases with FreeTSA, and saves with the server-to-server key
  (`worker/cloudkit-s2s.js`). The page reads Apple's copy back before it
  says saved. Secret `CLOUDKIT_PRIVATE_KEY`, key id in `wrangler.toml`.
- Tests: `tools/webtests/keyholder.test.mjs`, 32 checks.

### Changed

- Site copy, stage B of docs/WEB_COPY_1.2.md, plus one line it did not
  have: the relay can delete an entry it delivered.
- The recipient page's own copy now covers key holders.

## Web 1.2a, the recipient page (built 2026-10-17, live 2026-10-17)

Not deployed. It goes live with `npx wrangler deploy` only after the
CloudKit token is in `site/open/js/config.js`, the vectors pass on a Mac,
and one real security key has opened a released test estate in a browser.

### Added

- `site/open/`: open the envelopes written to you in any current browser,
  Android included, with a security key someone registered for you
  (PRODUCT.md section 15, 1.2a). Read only. Two taps: the first says which
  key it is, the second hands over the key's secret (WebAuthn PRF) that
  unlocks your private keys in memory. Nothing is stored in the browser.
- The page judges a release exactly as the phone does, not just the key
  against the commitment: signed events from endorsed devices only, key
  holders checked against the keys the owner's epoch statement names,
  RFC 3161 tokens verified under the pinned FreeTSA certificate, and
  ReleaseFeed rules 1 to 3 with ReleaseMachine. Dating follows the
  2026-10-17 decision: claims, taps, releases, objections and withdrawals
  are never earlier than Apple's record modification time.
- Shows the writer's three words (FingerprintPhrase) so a reader can
  compare them with "Your words" under the writer's seal in the app.
- Strict Content Security Policy for `/open/*` in `site/_headers`. One
  vendored library (ML-KEM-768, @noble/post-quantum 0.7.1), pinned, with
  `site/open/SHA256SUMS` for every served file (`tools/web_hashes.sh`).
- Tests, `sh tools/webtests/run.sh`: the timestamp check (143 checks), the
  identity checks (119), the phone's own release tests ported (189), and an
  end to end estate with an honest release and seven ways to cheat it (33).
- `tools/vectors/check.mjs` now tests the page's own crypto code.
  `tools/vectors/live-check.mjs` runs the page's checks over the real
  directory and, given estate ids, over real signed events.

### Changed

- Site copy, stage A of docs/WEB_COPY_1.2.md: how-it-works, objections,
  privacy, README.

## 1.2 (build 3: Passwords, and the key holder role fix)

### Added

- Passwords, for every day. A key button on the Envelopes screen (shown
  once there is a secret) opens every secret from every envelope and
  every rule in one list. One Face ID check opens it, always, whatever
  the card lock setting; it locks again when the app goes to the
  background. Search by name, note, kind or who it is for, never by the
  secret itself. Copy works without showing the value and goes through
  the same rules as the recipient's copy: this phone only, cleared in 90
  seconds, read back and shown. The same secret in two envelopes is one
  row naming both people. Nothing in the list writes: the pencil opens
  the envelope in the editor, where a change un-seals it as before.
  Secrets still live only in envelopes; there are no just-for-me secrets.
  (`PasswordsView.swift`, `EstateHomeView.swift`)

- Envelopes now reach a person's new device while the owner is alive
  (PRODUCT.md section 15, item 1). A recipient's key table was only ever
  wrapped to the devices they had at the last seal, so a new iPhone, a
  sponsored key or a browser opened nothing. Now every heartbeat compares
  each recipient's verified devices against the ones their table was
  wrapped to and, when they differ, wraps the table again to all of them
  in the background: same epoch, same Estate Key, the table itself and
  the owner's copy untouched, nothing unsealed published, no key tap. A
  key holder's new device still needs a new epoch, which is a seal, so
  that one waits for the owner: the Keys tab card now says "new device"
  and a notification names the person and opens the Keys tab.
  (`EstateEngine.swift`, `EstateModels.swift`, `OwnerNotices.swift`,
  `HomeView.swift`, `SealApp.swift`, `EstateHomeView.swift`, self-test
  `estatekeys.newDevice`)

### Changed

- The copy rules moved into one place, `SecretClipboard.swift`, which the
  recipient's reveal screen and the Passwords list both call, so the two
  cannot drift apart. (`RevealView.swift`)

### Fixed

- Someone who is both a key holder and a recipient could not act as a key
  holder. Both invites go to the same record name, and the seal writes the
  recipient one last, so the key holder role was overwritten. The phone
  now takes the key holder role from the writer's signed key list instead.
  (`EstateEngine.swift`; the web page has the same fix in `app.js`.)
- Opening an envelope and tapping Done without changing anything no
  longer un-seals it. Done always saved the envelope, and every save
  marked it unsealed, so just reading one brought the Seal button back.
  Now the save compares what would be sealed (title, letter, secrets,
  media, steps, open date, order, who it is for) against the stored copy
  and leaves it sealed when nothing differs. Any real edit still un-seals
  it. (`EstateEngine.swift`, `EstateModels.swift`, self-test
  `secretreview.unchangedEnvelope`)
- The three words after a scan. Each phone shows the OTHER person's words,
  but the screen said "say it out loud to each other, matching phrases,"
  so testers compared the two screens and the words never matched. Now
  your own words sit under your seal ("Your words: ..."), the screen after
  a scan names whose words it shows, and it says to check them against
  the words under the other person's seal. Adding a key holder also gets
  a "They don't match" button that stops before anyone is made a key
  holder. (`FriendsView.swift`, `AddKeyHolderFlow.swift`)
- A redeemed offer code now unlocks sealing without restarting Seal. The
  listener for purchases made outside the payment sheet was declared but
  never started, and the purchase was only checked at launch. Now the
  listener runs from launch and Seal checks again each time it comes back
  to the screen. (`SealPurchase.swift`, `SealApp.swift`)

## 1.1, submitted to the App Store, 2026-10-14

### Added

- Add a key holder in one go (PRODUCT.md section 14). From the setup card
  or the Keys tab: who, scan, their key on this phone, the phrase, "make
  them a key holder," the handover, done. Same ceremony, no tab hopping.
  (`Seal/Views/AddKeyHolderFlow.swift`)
- Three cards before sign up instead of fifteen: why Seal, who you are,
  what you do tonight. The full set stays under "How it works."

- One question a week (PRODUCT.md section 13). Once a week the phone
  shows one notification that names nobody; tapping it opens one question
  about one person, with dictation and up to two on-device follow-ups.
  The answer becomes one paragraph in that person's envelope, with Seal
  right there. Opening it is the week's check-in, answered or skipped.
  Eight new letter questions. (`WeeklyQuestion.swift`,
  `WeeklyQuestionView.swift`, `WeeklyParagraph`)

### Security

- Delete markers are signed. A "tomb" record now carries the account's own
  WebAuthn tap over `seal.identity.delete.v1`, and every reader checks it
  against the pinned key or the live record's key. Before this, anybody
  could create a marker for anybody, which locked that person out of
  signing in and showed them as deleted on their friends' phones.
  (`Seal/Identity/TombstoneProof.swift`)
- Revoking a device works from any iCloud account. A revocation used to be
  appended to the identity record, which only its creator may modify, so on
  many phones it silently did nothing. It is now also published as its own
  record with a random name, found by query, and still honoured only when
  the root key signed it. (`SyncEngine.publishRevocation`)
- Revoking asked for the wrong key. The request bundled the passkey and
  security key providers, so a passkey owner got the security key sheet,
  cancelled, and the error was swallowed. One provider now, chosen by the
  owner's tier, and errors are shown.

- Deleting an account asks what happens to the sealed envelopes: keep them
  for the family, or cancel them. The answer is one signed entry in the
  record (`ownerDeparted`), which every key holder sees, with the dates that
  follow from the rule. Cancelling removes the sealed blobs the phone
  uploaded and stops every claim, tap and release.
  (`Seal/Estate/DepartureRules.swift`)
- People who deleted their Seal account are found and marked. Pull to
  refresh on People, plus a daily check. The row keeps the name, loses the
  verified badge and says so, envelopes to that person are marked
  undeliverable, and a key holder who is gone is counted with the
  unresponsive ones. (`Seal/Identity/GoneCheck.swift`)
- A deleted owner's record no longer freezes on other phones. Their device
  endorsements are kept, and a key holder reads them through the key they
  pinned when they met. (`SyncEngine.fetchIdentityForHistory`)
- Continuous integration: the Shamir vectors, a synthetic capsule built and
  verified end to end, a tampered capsule that must fail, a check that no
  third party code has appeared, and the house rules. All five run on every
  push and need no Mac.
- `docs/PRE_AUDIT.md`: where to attack this, and the weak spots already
  known, written before anybody asked.
- `docs/TESTS.md`: every test in the app by name, generated from the source
  by `tools/list_tests.py` and checked on every push.
- `tools/run_core_tests.sh`: compiles the parts of Seal that need no app
  (the key split and the release countdown) straight from the app's own
  source files and runs the same self-test suites, so those tests can run
  on a Mac runner where anybody can watch them pass. `ReleasePolicy` and the
  `Data` hex helpers moved into files of their own for it, and
  `SelfTest.runAll` no longer defaults to the whole registry.
- `CONTRIBUTING.md`, issue and pull request templates, and a
  `.well-known/security.txt` on the website.

### Changed

- "Custodian" is gone from every screen. The word is "key holder", and a
  check in continuous integration keeps it that way.
- The privacy policy now matches the code: what the record shows, the
  timestamp service, and the delete choice.

## 1.0, submitted to the App Store, September 2026

The first release. Sealed envelopes with a letter, photos, a voice message,
a video and the secrets; key holders met in person and handed a hardware
security key; a rule of silence days, warning days, grace days and M of N
key taps; a signed, hash linked record with optional RFC 3161 timestamps; a
standalone Python verifier; a second "bills and medical" set with its own
shorter rule; backup keys; the yearly key confirmation; the printed page for
the drawer; and no server, no dependency and no analytics.
