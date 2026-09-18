# Before the audit

Written by the developer, for whoever reviews this next. Nobody independent
has looked at Seal yet. This page says where to point a review, what is
already known to be weak, and what is deliberately not promised, so that a
reviewer spends their time on the parts that could actually hurt somebody.

Last updated: 2026-09-17.

## What Seal has to get right

One sentence: **nothing opens early, and what opens later opens only for the
person it was written for.**

That rests on four things, and everything else is furniture:

1. The key hierarchy in `Seal/Estate/EstateKeys.swift`, which decides who can
   unwrap what.
2. The key split in `Seal/Crypto/Shamir.swift`, which decides what one key
   holder learns on their own (nothing).
3. The signed record in `Seal/Estate/EstateLog.swift` plus the countdown in
   `Seal/Estate/ReleaseMachine.swift`, which decide when a release is allowed.
4. The WebAuthn checks in `Seal/Crypto/WebAuthnParsing.swift`, which decide
   whether a key was really tapped, for Seal, by a present human.

## Where to attack first

In the order a reviewer would get the most out of:

1. **Domain separation.** Every signed statement is a SHA-256 over a domain
   string and length framed fields. Twenty-seven domains exist. The
   interesting question is whether any two can be made to produce the same
   bytes, so a tap for one purpose replays as another. The pairs that matter
   most: `seal.release.authorize.v1` (a release tap),
   `seal.custody.confirm.v1` (the yearly "I still have my key"),
   `seal.identity.delete.v1` (a delete marker) and `seal.revoke.v1`.
2. **The record, as an attacker who owns the database.** The public CloudKit
   database is world readable and any signed-in account can create records.
   Records can be added, withheld or reordered. Seal answers that with
   signatures, hash links and optional RFC 3161 timestamps. The open question
   is what an attacker gains by HIDING an event rather than forging one, and
   the app cannot detect that on its own.
3. **The release machine, as a hostile key holder.** `ReleaseMachine` is a
   pure function with tests in `Seal/SelfTest/ReleaseMachineTests.swift`.
   Try: taps during a paused objection, a claim opened too early, a claim
   reopened after a veto, clock skew between phones, and a heartbeat that
   arrives after a claim.
4. **The wrapping.** `EstateKeyHierarchy` wraps to X25519 plus ML-KEM-768
   (`Seal/Crypto/KEMBundle.swift`, `HybridKEM.swift`). Check the additional
   authenticated data on every wrap, that a wrap for one estate or epoch
   cannot be replayed into another, and that the owner's own wrap and the
   recipient's wrap cannot be confused.
5. **Directory trust.** Keys are pinned on the phone the day people meet
   (`Seal/Identity/KeyPinStore.swift`). Everything else about the directory is
   untrusted. Check the paths that BYPASS a pin: sign-in through a backup
   credential, the "history" read of a deleted identity
   (`SyncEngine.fetchIdentityForHistory`), and device revocations, which since
   2026-09-16 may arrive as separate records anyone can create and which are
   therefore checked by signature, not by position.
6. **The sponsored key** (`Seal/Identity/SponsoredKey.swift`). This is the one
   place where private key material leaves a phone: locked under a secret only
   a physical security key can compute, through the WebAuthn PRF extension,
   and stored in the public database. It is new, it has never run against real
   hardware, and it deserves the hardest look of anything here.

## Known weak spots, already accepted

None of these are findings. They are choices, and each one is written down in
the product documents too.

- **The field arithmetic is not constant time.** `Shamir.mul` loops over the
  bits of its second operand and branches on them. Shares are handled only on
  the holder's own device, and there is no remote timing channel into it, so
  this was accepted rather than rewritten into a table free constant time
  form. If a reviewer disagrees, this is a contained change with test vectors
  already in place.
- **Metadata leaks by design.** The number of recipients, roughly how much was
  written, who the key holders are (by account hash), the rule, and the times
  of every check-in and claim are all readable in the public database.
  `docs/PRODUCT.md` section 8.
- **Claim reasons and objection notes are stored in the clear.** A key holder
  types them; they are signed but not encrypted.
- **One key, one identity is deterrence only.** A FIDO2 reset gets around the
  exclusion list. `docs/SDS.md` section 7.
- **A thief with the owner's unlocked phone can keep checking in**, which
  keeps the envelopes closed forever. Seal cannot tell that apart from the
  owner being alive.
- **A threshold of one means one key holder can release alone.** The owner
  chooses it and that person is told.
- **Anybody can write junk into the public database.** Records addressed to a
  hash can be spammed; every reader verifies signatures and drops the rest,
  and the revocation reader stops after twenty pages. The cost of the spam is
  fetch time, not correctness.
- **Most of the app's tests run at launch in DEBUG builds only.** There is no
  test target, because a passkey needs a real app to live in, so the suites in
  `Seal/SelfTest` run on a phone. `docs/TESTS.md` lists them by name. The
  pieces that need no app, today the key split and the release countdown, are
  compiled straight from the same source files and run by
  `sh tools/run_core_tests.sh`, so those suites can be watched by a stranger.
  Everything above them still rests on tests only the developer sees run.

## What is deliberately not promised

`docs/PRODUCT.md` section 8 is the full list. The short version: Seal cannot
know somebody died, only that they went quiet; it cannot prove a recipient is
the human the owner had in mind; it does not hide that an estate exists; and
once a release happens it cannot be undone.

## Reproducing everything without a phone

```
pip install cryptography
python3 tools/shamir_vectors.py                          # field and split vectors
python3 tools/make_test_capsule.py > /tmp/capsule.json   # a synthetic, real-signature capsule
python3 tools/verify_capsule.py /tmp/capsule.json        # every signature checked
python3 tools/make_test_capsule.py --tamper > /tmp/bad.json
python3 tools/verify_capsule.py /tmp/bad.json            # must fail
python3 tools/check_imports.py                           # no third party code
python3 tools/check_house_rules.py                       # copy and hygiene rules
python3 tools/list_tests.py --check                      # the test list is current
```

On a Mac, with Xcode's command line tools:

```
sh tools/run_core_tests.sh    # Seal's own suites for the key split and the countdown
```

The Python commands are what continuous integration runs on every push, so a
green check on the repository means exactly what running them yourself means.
The Mac one runs there too, on a Mac runner.

## The documents worth reading first

| File | Why |
|---|---|
| `docs/SDS.md` | Security design: key hierarchy, threat model, the four security fixes |
| `docs/RELEASE.md` | The countdown, state by state, including what a departure does |
| `docs/CAPSULE.md` | The archive format, written for an outsider |
| `docs/RECORD.md` | What the signed record holds and what it deliberately does not |
| `docs/GOTCHAS.md` | Everything that has already gone wrong, unflattering on purpose |
| `docs/REVIEW.md` | The pre-release design review and what it changed |
