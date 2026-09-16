# Gotchas

Hard-won operational knowledge. **Read this before debugging anything**, because
most of what is in here cost a day to find and looks like a different problem
from the outside.

## Environments

- **TestFlight and the App Store use Production CloudKit. Xcode builds use
  Development.** Two separate worlds with separate data. Something that works on
  your desk can be completely broken in TestFlight.
- Schema changes are additive and one-directional: exercise them in Development,
  then Deploy Schema Changes to Production. You cannot delete a field once it is
  in Production. See [CLOUDKIT_DEPLOY.md](CLOUDKIT_DEPLOY.md).
- **iOS caches failed AASA checks.** If WebAuthn fails immediately with error
  1001, delete and reinstall the app before investigating anything else.

## Identity and keys

- **PIN'd security keys reported "wrong PIN" with a correct PIN.** Root cause
  found 2026-06-26: modern FIDO2.1 keys turn on `always_uv` once a PIN is set, so
  they force the CTAP2 clientPIN ceremony no matter what the relying party asks
  for. Our `.discouraged` user verification contradicted the key, iOS drove the
  PIN path in that contradictory state, and the result was a bogus failure. Fixed
  by switching all four security-key requests to `.preferred`. Pinless keys stay
  tap-only, per the FIDO spec. **Still unverified on a real device over both NFC
  and USB-C.** The earlier "fixed by residentKey .discouraged" theory was wrong:
  residentKey is orthogonal to the PIN.
- **Security-key sign-in needs the directory's published credential IDs as an
  allow list.** A non-resident key finds nothing on an empty list. This is why
  the `recordName` QUERYABLE index on `Identity` is not optional.
- **One key, one identity** is deterrence only. Registration passes every
  directory credential ID as `excludedCredentials`, so the authenticator refuses
  a second identity. A FIDO2 reset or a modified client evades it (SDS §7). Needs
  that same queryable index. Scale ceiling is about 1,000 identities.
- **Deleted accounts could once sign back in.** The tombstone used to be only a
  `tier="deleted"` flag, which the app cheerfully republished. Fixed 2026-06-26:
  deletion now also writes a write-once `tomb.<hash>` marker, `publishIdentity`
  refuses to publish a tombstoned identity, and sign-in throws
  `CeremonyError.identityDeleted`. **Deleting the Identity record by hand in the
  console leaves no marker and can be republished.** Retire a stuck account
  through Profile → Delete identity on a current build.
- Renaming is metadata only. A display name is in no signature, commitment or
  credential hash, so it never affects verification.

## Messaging

- **The cross-device desync of 2026-06-26** looked like two unrelated bugs:
  the sender saw "CryptoKit error 3" and the receiver saw "dropped a message
  that failed verification". One cause: the published endorsement did not match
  the keys actually in use, after rebuild churn. Three fixes shipped together and
  were verified on two phones on 2026-06-29.
  - The sender wraps the epoch key to **every** endorsed device KEM key rather
    than just the last one (`HybridKEM.wrapToAll`). **A new-build envelope is an
    array and an old build cannot read it. Both phones must run the new build.**
  - The receiver refetches a sender's identity once before dropping a message
    that fails to verify, which self-heals a stale directory cache.
  - The sender republishes its own endorsement once per launch if it is missing
    from the directory's verified set (`ensureSelfPublished`).
  - **Residual limit:** a phone whose current key was never published stays
    unreachable until it reopens the app or you re-add the person.
- There is a `messaging` os-log category on subsystem
  `io.github.jasonepage.Seal` that prints 8-hex key fingerprints on send, unwrap
  failure and verify failure. Start there for any future desync.
- **Expired messages are purged from the store outright** by
  `ChatEngine.purgeExpired()`. That is why record events need tombstones. See
  [RECORD.md](RECORD.md) §12.

## Layout

- **A vertical `ScrollView` does not constrain its content's width.** Any child
  that wants more room than the screen silently widens the content and the whole
  screen becomes draggable sideways. It showed up in Profile with Bigger text on.
  Fix is `.containerRelativeFrame(.horizontal)` on the scroll content. Thirteen
  other scroll views in the app have not been swept.
- **`.parentTypeScale()` must be applied exactly once per presentation tree** or
  the type bumps twice. `ChatsView` and `HomeView` currently make opposite claims
  about whether a sheet inherits it. Unresolved, and the comments say so.

## Copy and docs that lie

Three times in one session, copy contradicted shipped code. Check for this
first when something reads oddly.

- The how-to card told people to run the ceremony twice, months after
  `ForgeHandshake` made the second run automatic.
- Onboarding said "nothing is recoverable" after backup keys shipped.
- Profile told people to leave Simplified mode to add someone, hours after
  "Add someone" landed in the chat list.

- The reveal screen showed a recipient the secrets in the clear while
  `site/limits.html` said "secrets are shown only after a Face ID check".
  Fixed 2026-09-16: `RevealPager` hides them behind "Show the secrets", which
  always runs `AppLock.confirmReveal`. The owner's preview uses the same view.
- The handoff of 2026-09-16 said a secret typed into the letter was caught by
  a BIP39 check, and it was, for English only. A Trezor Shamir share
  ("academic ...") sailed through. `Seal/Cards/Wordlists` now holds every
  BIP39 language, SLIP39, and Monero's lists; `LetterSecretScan.wordlists` is
  the one table.

ML-KEM-768 IS implemented (`Seal/Crypto/KEMBundle.swift`, behind an iOS 26
check). An older version of this section said it was a TODO; that was true
once and is not now. The em dashes inside user-visible strings are gone too
(grep for the character in `Seal/` before believing otherwise).

## Demo mode

- Type `SEALDEMO` as your name on the registration screen and tap **Set up with
  Face ID**, or type it and tap Sign in. Either drops into a fully local demo
  account with no key, no Face ID and no network. Session-scoped: force quit to
  leave. The App Review notes name that button by its exact label, so renaming
  it means updating them.
- The scheme's `-SealDemoMode` and `-SealDemoHideWatermark` arguments are
  disabled, so Xcode runs no longer install the demo identity. Turn them on only
  for marketing screenshots.

## House rules

- The seal mascot appears on social surfaces only, never on a security surface.
- Brass marks a trust moment only. Silver is for anything vouched for at a
  distance. Neither is decoration.
- All local state is keychain JSON namespaced by identity hash
  (`seal.chats.<hash>`, `seal.friends.<hash>`, and so on). Sign-out wipes local
  state and leaves the identity in the directory. Anything new that stores per
  identity must be added to `ContentView.wipeLocalAndEngines`.

## The sealed envelope conversion (2026-09-15)

- **Nothing in the conversion has been compiled.** It was written without
  Xcode. The first build will find typos. Fix them in place; the design does
  not depend on any of them.
- **`MLKEM768` API names are the most likely compile error.** Everything that
  touches ML-KEM is in `Seal/Crypto/KEMBundle.swift` and the two lines in
  `IdentityManager.mintMLKEMIfMissing`. If CryptoKit spells `encapsulate()`,
  `decapsulate(_:)` or `seedRepresentation` differently, the fix is local.
- **The `Clock` protocol shadows Swift's.** Write `Swift.Clock` if you ever
  need the standard library one. Nothing does today.
- **Tests live in the app target** (`Seal/SelfTest`) because there is no test
  target and the project file is not hand edited. They run at DEBUG launch
  and `assert`. A failing self-test therefore crashes a debug build on
  purpose. The Time Travel screen runs them on demand.
- **A phone that has not signed in since the conversion has no ML-KEM key**
  and gets classical-only wraps. Sign in once on every phone. The endorsement
  is republished with the hybrid bundle.
- **Removing a person drops their key pin.** That is the only way a pin goes
  away. If someone genuinely re-registers, remove and re-meet them.
- **`EstateEvent` needs its `estate` field QUERYABLE** in every environment,
  same class of silent failure as the `Identity` index.
- **Demo mode seeds a sealed estate but publishes nothing.** Every engine
  method checks `DemoFixtures.isActive` and returns; the buttons are disabled.
