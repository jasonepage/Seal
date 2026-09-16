# Where Seal stands

**Updated:** 2026-09-16 · **Owner:** Nathan (Jason Page) · natepage67@gmail.com
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

## STATUS 2026-09-16: it builds and runs on a phone

The 2026-09-15 blank white screen is gone; the build at `02ec1ee` ran clean.
Everything committed after it on 2026-09-16 (fourteen commits, listed below)
is **uncompiled again** and needs the same loop: build in Xcode, paste the
errors, fix in place. Nothing in that batch is architectural, so expect
typos and API spellings, not redesign.

Where the 2026-09-16 batch is most likely to fail to compile, in order:

- `Seal/Views/Interview/LetterReview.swift`: `@Generable` with an array
  property (`[ReviewedGap]`). The drafter only ever used flat structs.
- `Seal/Cards/Wordlists/*.swift`: twenty three large `Set<String>` literals.
  Each is typed explicitly. If the type checker still times out on one, the
  fix is `Set(["..."] as [String])`, not a project setting.
- `Seal/Views/RevealView.swift`: `RevealPage` stores an `async throws`
  closure in a struct that is `Identifiable`. Should be fine in Swift 5 mode.
- `Seal/Estate/OwnerNotices.swift` and `NotificationsOffCard.swift`:
  `UNTimeIntervalNotificationTrigger` and
  `UIApplication.openNotificationSettingsURLString` (iOS 16+).

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
