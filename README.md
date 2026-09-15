# Seal

**Sealed envelopes for the people you leave behind.**

You write a small number of envelopes. Each holds a letter, a few photos, a
voice message, and the things you never told anybody: the passwords, where
the safe deposit key is, the combination, the seed phrase. You hand physical
security keys to a few people you trust. You set the rule for how the
envelopes open after you are gone.

Nobody can open one early. Not Apple, not us. It takes your custodians'
physical keys, after a long silence from you, after weeks of warnings you can
stop with one tap.

## How it works

1. **Register** with a security key or Face ID. Your key is your identity.
2. **Meet people in person.** You add someone by standing next to them, once.
   That is how their key becomes trusted, and it is the only way.
3. **Write envelopes.** One for your wife with every password. One for each
   child. One for your business partner with the registrar login.
4. **Hand out keys.** Three keys, say: wife, brother, attorney. Each tap on
   your phone is a signed receipt that the key changed hands.
5. **Set the rule.** Any two of the three, after 90 days of silence, then 21
   days of warnings, then 14 quiet days. Those are the defaults; you choose.
6. **Tap Seal.** Everything is encrypted on your phone before it leaves.
7. **Open the app now and then.** That is the whole job. Opening it is the
   check-in that keeps the envelopes closed.

If you go quiet, a custodian can start a claim. You are warned every day for
three weeks. Everyone who holds a key is told. If you open Seal once, it stops
cold, and you do not need your key to do it. If you never do, and enough
custodians tap their keys, the envelopes open on the phones of the people
they were written for, in the order you chose, and nobody else's.

## What it promises

- An envelope cannot be opened early by anyone, including us.
- Stopping a release is one tap. Starting one is hard.
- The people holding keys learn nothing about what is in the envelopes or
  who they are for.
- The record of what happened, and the encrypted envelopes themselves, live
  in a file you and your custodians keep. It can be checked with a small
  script and no Seal, no Apple and no account: [docs/CAPSULE.md](docs/CAPSULE.md).

## What it does not promise

Seal cannot tell whether you are dead. Silence is silence, which is why the
warnings exist. It proves that a specific key did a specific thing; it does
not know who the legal person is. Once the envelopes are released, that
cannot be undone. The full list is in [docs/PRODUCT.md](docs/PRODUCT.md).

## For developers

- Start with [HANDOFF.md](HANDOFF.md), then [docs/GOTCHAS.md](docs/GOTCHAS.md).
- Design: [docs/SDS.md](docs/SDS.md). Requirements: [docs/SRS.md](docs/SRS.md).
- The release state machine: [docs/RELEASE.md](docs/RELEASE.md).
- The signed record and timestamps: [docs/RECORD.md](docs/RECORD.md).
- The export format and verifier: [docs/CAPSULE.md](docs/CAPSULE.md),
  `tools/verify_capsule.py`.

Seal is SwiftUI on iOS 26.5, CryptoKit only, no backend, no dependencies.
Team `8C4BM6A82T`, bundle `io.github.jasonepage.Seal`, relying party
`sealmessenger.com`. A seal is wax on a letter the wrong person must not open,
and breaking one is a ceremony. The name did not change.
