# Where Seal stands

**Updated:** 2026-09-15 · **Owner:** Nathan (Jason Page) · natepage67@gmail.com
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

## THE FIRST THING TO DO: BUILD IT

**Nothing written on 2026-09-15 has been compiled.** The conversion was done
in an environment with no Xcode and no Swift toolchain of any kind. It was
written carefully, but a job this size without a compiler will have typos and
a few API mismatches. Expect an hour of fixing before it runs.

1. `xcodebuild -project Seal.xcodeproj -scheme Seal -destination 'generic/platform=iOS' build`
2. Fix what it reports, in place. The design does not hinge on any of it.
3. Run a DEBUG build on a phone. The self-tests run at launch and `assert`
   on failure (`Seal/SelfTest`). Read the `selftest` os-log category.
4. Open the Time Travel screen (clock icon, DEBUG only) and run the story:
   seal, travel 91 days, claim from a custodian phone, travel 21 and 14, tap
   keys, combine. The owner opening the app at any point must cancel.

Where compile errors are most likely, in order:

- `Seal/Crypto/KEMBundle.swift` and `IdentityManager.mintMLKEMIfMissing`:
  the CryptoKit `MLKEM768` API (`encapsulate()`, `decapsulate(_:)`,
  `seedRepresentation`, `EncapsulationResult` member names). Confined there.
- `Seal/Sync/EstateDirectory.swift`: the labelled tuple returned by
  `CKDatabase.records(matching:resultsLimit:)` and `records(continuingMatchFrom:)`.
- `Seal/Views/*`: SwiftUI view builder edge cases (`#if DEBUG` inside a
  toolbar, `switch` over an optional enum in a `VStack`).
- `Seal/Time/Clock.swift`: the module `Clock` protocol shadows Swift's. If
  anything complains, it wants `Swift.Clock`.

## What is blocking (besides the build)

1. **The CloudKit schema.** `EstateEvent` (with `estate` QUERYABLE) must
   exist in Development and be deployed to Production.
   [docs/CLOUDKIT_DEPLOY.md](docs/CLOUDKIT_DEPLOY.md). Only Nathan can do this.
2. **Every phone must sign in once** on the new build so its endorsement is
   republished with the hybrid KEM bundle.
3. **The site and the store listing** still describe a messenger
   (`site/*.html`, `docs/archive/STORE_COPY.md`). Not rewritten in this pass.
4. **A timestamp authority** is still FreeTSA, chosen for being free. See
   [docs/RECORD.md](docs/RECORD.md) section 13.

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
  `SyncEngine`** were left in place as dead code rather than deleted, to keep
  the phase 7 diff to what the brief listed. Safe to remove later.

## Before you debug anything

[docs/GOTCHAS.md](docs/GOTCHAS.md), including the new section at the bottom.

## Working style

Numbered steps for ops tasks. Concise replies. No em dashes anywhere. Commit
after each working milestone, and check `git status` first. Mom is a tester.
