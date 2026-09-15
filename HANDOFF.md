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

## STATUS 2026-09-15 1:42 PM: it builds, it launches, it shows a blank white screen

The build succeeded after three rounds of fixes (see git log). Run on a
phone from Xcode, the app shows a plain white screen and stays there. Not
diagnosed yet. The two most likely causes, in order:

1. `SelfTest.runAtLaunchIfDebug()` in `SealApp.init` runs every self-test on
   the main thread before the first frame. A test that hangs, or an `assert`
   that fires with the debugger attached, would look exactly like this.
   Comment that one line out first. If the app then shows the dark screen,
   the problem is in a test (run them from the Time Travel screen instead,
   or read the `selftest` os-log line in the Xcode console).
2. `ContentView` renders nothing until `setupEngines()` has run in
   `.onAppear`; a blank Group may not fire `onAppear`. If step 1 does not
   fix it, move `setupEngines()` into `ContentView`'s `init` or wrap the
   Group's else-branch in a `Color(SealTheme.ink)` so something is on screen.

Also check the Xcode console for a purple runtime warning or a crash log.

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
  `SyncEngine`** were left in place as dead code rather than deleted, to keep
  the phase 7 diff to what the brief listed. Safe to remove later.

## Known UI debt: the You screen is cluttered

Raised 2026-09-15 after the first screenshots, and agreed. Flattening the
Advanced drawer into one screen was right, but every row kept its full weight,
so the screen is now a wall of paragraphs. The fix is not to hide things
again. It is to make each row one line and put the explanation behind an
info button the person taps when they want it.

The specific work, none of it done:

1. **Setting rows are a title and a switch.** If the subtitle runs past about
   six words it goes behind an (i) that expands in place. "Independent
   timestamps" is five lines of standing text today. "Bigger text" is three.
2. **The Seal, Directory and This device card goes behind a closed
   disclosure** called something like "Technical details". Nobody reads a
   truncated hex hash, and the fingerprint phrase at the top of the same
   screen ("juniper evergreen dell") is already the readable form of it. Show
   the phrase, put the hex behind the disclosure with a copy button.
3. **The backup keys card is two long paragraphs.** Both go behind the (i).
   The card becomes a heading and "Add a backup key".
4. **The no-backup-key alarm and the backup keys section now say the same
   thing twice** on one screen, which they did not when one of them was a
   drawer away. Keep the alarm, shrink the section.

The rest of the app reads clean. This is one screen.

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
