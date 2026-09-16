# Reporting a vulnerability

Email **jasonepage@gmail.com** with "Seal security" in the subject. A person
reads it, usually the same day.

Please include what you found, how to reproduce it, and what you think it lets
somebody do. If you would rather encrypt the report, say so in a first message
with no detail in it and you get a key back.

There is no bounty. There is one developer and no company behind this, so
there is no budget to pretend otherwise. What you get is a fast answer, credit
in the fix commit if you want it, and a straight account of what was wrong.

## What counts

Anything that lets somebody read an envelope they were not written, act as
somebody they are not, release an estate early, or stop a release that should
happen. Also anything in the record that can be forged, hidden or replayed.

The limits below are known and documented, so they are not findings, but a
concrete way to make one of them worse than described very much is:

- Metadata leaks: how many people an estate has, roughly how much was written,
  and that a given identity has a part in some estate. `docs/PRODUCT.md` §8.
- One key, one identity is deterrence only. A FIDO2 reset gets around it.
  `docs/SDS.md` §7.
- A thief with the owner's unlocked phone can keep sending heartbeats.
- A threshold of one means one key holder can release alone. That is the
  owner's choice and the app says so to that person.

## What this project has not done

No independent audit. Nobody outside this project has reviewed the
cryptography or the code. That is stated on the website too, and it is the
reason the site tells people with hardware wallets not to put a live seed
phrase in yet.

## Where to look first

If you want the fastest route to the parts that matter:

| File | Why |
|---|---|
| `docs/SDS.md` | Security design, key hierarchy, threat model |
| `docs/CAPSULE.md` | The archive format, written for an outsider |
| `Seal/Estate/EstateKeys.swift` | Every wrap and unwrap in the estate |
| `Seal/Crypto/KEMBundle.swift` | X25519 plus ML-KEM-768 |
| `Seal/Crypto/Shamir.swift` | The key split, over GF(256) |
| `Seal/Estate/ReleaseMachine.swift` | The countdown, as a pure function |
| `Seal/Crypto/WebAuthnParsing.swift` | Assertion checks: RP hash, user presence, type |
| `tools/verify_capsule.py` | The standalone verifier |

`docs/GOTCHAS.md` is the list of things that already went wrong and what they
turned out to be. It is written for whoever debugs this next, and it is
deliberately unflattering.
