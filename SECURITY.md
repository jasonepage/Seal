# Reporting a vulnerability

Email **support@sealmessenger.com** with "Seal security" in the subject. A
person reads it, usually the same day.

If that bounces for any reason, open an issue saying only that you have a
security report and how to reach you. Do not put the detail in a public
issue.

Please include what you found, how to reproduce it, and what you think it lets
somebody do. If you would rather encrypt the report, say so in a first message
with no detail in it and you get a key back.

There is no bounty. There is one developer and no company behind this, so
there is no budget to pretend otherwise. What you get is a fast answer, credit
in the fix commit if you want it, and a straight account of what was wrong.

## What you can expect

A first reply within three days, usually the same day. If it is real, you get
told what the fix is and when it ships, and credit in the fix commit if you
want it. If it is already known, you get pointed at where it is written down,
which is usually `docs/PRE_AUDIT.md` or `docs/PRODUCT.md` section 8.

Test against your own identities and your own envelopes. Do not touch other
people's records in the shared directory, do not run denial of service against
Apple's infrastructure, and do not keep anything you happen to see. Work that
way and there is nothing to forgive: no legal action, ever, from this project.

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

`docs/PRE_AUDIT.md` is written for you: what this has to get right, where to
attack it in order, and the weak spots already accepted. Read that first.


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
