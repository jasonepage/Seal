# Changelog

Dates are the day the work landed in the repository. Anything marked
"not built yet" has been written but never compiled or run on a phone.

## Unreleased

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

### Added

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
