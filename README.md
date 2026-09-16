# Seal

**Sealed envelopes for the people you leave behind.**

A will filed for probate becomes a public court record. So the password to
your bank, the phrase that opens your wallet, where the safe deposit key is,
the combination, the thing you never told anybody: none of it can go in one.

Seal is where those things go instead. You write a small number of envelopes,
one per person. You choose a few people you trust, face to face. You set the
rule for how the envelopes open after you are gone. Then you open the app now
and then, and that is the whole ongoing job.

Nobody can open one early. Not Apple, not us.

> **If you own a hardware wallet, do not put a live seed phrase in this yet.**
> Nobody independent has audited it, and it is a TestFlight beta. What your
> family cannot reconstruct without you is *where the steel plate is, which
> wallet it belongs to, and who to call first*, and none of that needs the
> twelve words. Start there.

- Website: <https://sealmessenger.com>
- How it works, in full: <https://sealmessenger.com/how-it-works.html>
- What it does **not** do: <https://sealmessenger.com/limits.html>
- Reporting a vulnerability: [SECURITY.md](SECURITY.md)

## Status, plainly

| | |
|---|---|
| Stage | TestFlight beta. Not on the App Store. |
| Audit | **None.** Nobody outside this project has reviewed it. |
| Team | One developer. No company, no funding, no investors. |
| Platform | iPhone, iOS 26. No Android. One owner device. |
| Dependencies | None. No third party code, no analytics, no backend of ours. |

`docs/GOTCHAS.md` is the running list of things that went wrong and what they
actually were. It is unflattering on purpose, and it is the first thing to
read before debugging anything.

## How it works

1. **Register** with a passkey or a security key. That credential is your
   identity. There is no password, no email and no recovery code, so there is
   nothing a phishing message could ask you for.
2. **Meet people in person.** You add somebody by standing next to them, once.
   Each phone records the other's public key in that moment and refuses any
   different key served under that name afterwards, forever.
3. **Write envelopes.** One per person: a letter, photos, a voice message, and
   the secrets. You can start before you have added anybody, by typing a name.
   Seal can also interview you and draft it, entirely on the phone.
4. **Choose who can open them** and **set the rule.** Any two of three, after
   90 days of silence, then 21 days of warnings, then 14 quiet days, by
   default. You choose all four numbers.
5. **Tap Seal.** Everything is encrypted on the phone before it leaves.
6. **Open the app now and then.** That is the check-in that keeps it closed.

If you go quiet past your limit, somebody you chose can start a claim. You are
warned every day for weeks, then a quiet period runs. One tap from you ends all
of it, and that tap never needs your hardware key: a living person who lost a
key must not be declared dead by their own software. Only after all of that can
keys be tapped, and each envelope then opens on the phone of the person it was
written for. Nobody reads anybody else's, including the people who released it.

## The key hierarchy

```
Envelope Content Key   random 256 bit, AES-256-GCM, one per envelope
    listed in
Key Table              one per RECIPIENT, under its own random Key Table Key
    reachable two ways
    ├─ wrapped to the OWNER's devices
    └─ encrypted under the Estate Key, then wrapped to the RECIPIENT's devices
Estate Key             one per owner per epoch
    reachable two ways
    ├─ wrapped to the OWNER's devices
    └─ split by Shamir into N shares, threshold M, each wrapped to one
       key holder's devices
```

The people who release an estate recover the Estate Key and **nothing else**.
It opens no envelope on its own: each key table still needs the phone of the
person it was written for.

## Cryptography

All from Apple's CryptoKit and AuthenticationServices. Nothing rolled by hand.

| | |
|---|---|
| Identity | WebAuthn, P-256 ECDSA with SHA-256, in a security key or a passkey |
| Device keys | P-256 in the Secure Enclave, non-exportable, endorsed by the identity |
| Wrapping | X25519 ECDH plus ML-KEM-768, combined through HKDF-SHA256 |
| Content | AES-256-GCM with a domain separated AAD naming estate, epoch and purpose |
| Key split | Shamir over GF(256), checked against independent Python vectors |
| Time | RFC 3161 tokens, optional, off until you turn it on |
| Storage | CloudKit public database: ciphertext and public keys. No Seal server. |

## Check it without trusting us

Anybody holding part of an estate can export a **capsule**: one JSON file with
the whole signed record. `tools/verify_capsule.py` is a single Python file with
no Seal in it and no network access, and it checks every signature, every
endorsement, every hash link and every timestamp token.

```sh
python3 tools/verify_capsule.py seal-capsule-XXXX.json --strict
```

`tools/make_test_capsule.py` builds a synthetic one, so you can watch it pass,
change a byte, and watch it fail. The format is documented in
`docs/CAPSULE.md` in enough detail to write a fresh verifier from scratch,
deliberately, in case this project is not here.

## Documentation

| | |
|---|---|
| `docs/PRODUCT.md` | What it is, who it is for, and §8: what is not promised |
| `docs/SDS.md` | Security design, key hierarchy, §7 threat model |
| `docs/RELEASE.md` | The countdown and the release state machine |
| `docs/CAPSULE.md` | The archive format, for an outsider with a file and a laptop |
| `docs/RECORD.md` | The signed record and timestamping |
| `docs/GOTCHAS.md` | What already went wrong, and what it turned out to be |
| `HANDOFF.md` | Where this stands today, including what is blocking |

## Building

Xcode, an iPhone on iOS 26, and an Apple Developer account for the CloudKit
container and the WebAuthn associated domain. New Swift files under `Seal/`
join the target automatically. The `EstateEvent` record type needs its
`estate` field queryable in CloudKit, and `Identity` needs `recordName`
queryable, in both the development and production environments.

## License

[Mozilla Public License 2.0](LICENSE). File level copyleft: you may read,
audit, run and fork this, and you may build something larger around it under
whatever terms you like, but changes to Seal's own files have to be published
under the same license.

MPL rather than GPL or AGPL on purpose. GPL family licenses conflict with the
App Store's terms, which is why VLC was pulled in 2011 and why VideoLAN
relicensed to MPL to come back. An estate product that cannot ship on the App
Store is not a product.

Every source file carries the notice from Exhibit A, because MPL is decided
per file and a file without the notice is arguably not covered.
