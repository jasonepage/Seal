# Changelog

Dates are the day the work landed in the repository. Anything marked
"not built yet" has been written but never compiled or run on a phone.

## 1.2 (build 2, with Passwords; build 1 was on TestFlight 2026-10-17)

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
