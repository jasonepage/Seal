# Software Design Specification: Seal, sealed envelopes

**Version:** 1.0 · **Date:** 2026-09-15 · **Companions:** [SRS.md](SRS.md) · [PRODUCT.md](PRODUCT.md) · [RELEASE.md](RELEASE.md) · [CAPSULE.md](CAPSULE.md) · [RECORD.md](RECORD.md)

The messenger-era specification (v0.1, 2026-06-11) is in `git log`; its
identity, ceremony and backup credential sections still describe the code
and are carried forward below.

## 1. Architecture

CloudKit-first, serverless. The only non-Apple infrastructure is a static
domain serving the WebAuthn app site association file.

```
┌──────────────── iPhone (owner, custodian, recipient: same app) ───────────────┐
│ SwiftUI                                                                        │
│ ├─ EstateHomeView / EnvelopeEditor / Policy / Person / GuardedEstate / Reveal  │
│ ├─ IdentityManager  ── NFC/USB-C ──► FIDO2 key or passkey (root, signs only)   │
│ ├─ CeremonyManager  (WebAuthn via ASAuthorizationServices, + release tap)      │
│ ├─ EstateEngine ──► EstateKeys (Shamir, hybrid wraps), EstateLog, ReleaseFeed, │
│ │                   ReleaseMachine (pure), Clock (injected)                    │
│ ├─ TimestampService (RFC 3161, digest only leaves the phone)                   │
│ └─ SyncEngine + EstateDirectory ──► CloudKit public DB                         │
└──────────────────────────────┬─────────────────────────────────────────────────┘
                               │ ciphertext, signed events, public keys only
              ┌────────────────▼────────────────┐   ┌───────────────────────────┐
              │ CloudKit public DB              │   │ sealmessenger.com         │
              │ Identity, EstateEvent,          │   │ /.well-known/apple-app-   │
              │ MediaAsset (blobs), GroupInvite │   │ site-association (RP only)│
              └─────────────────────────────────┘   └───────────────────────────┘
              Transport. NOT the archive of record: that is the capsule on disk.
```

**Trust model in one sentence:** a hardware key's FIDO2 credential is a
person's root; it endorses Secure Enclave device keys; device keys sign every
event; the root key of anyone you rely on is pinned at the ceremony where they
proved it; every client verifies the full chain and trusts nothing the server
says.

## 2. Key hierarchy

```
Root identity (FIDO2 key or passkey, P-256, signs only, PINNED after ceremony)
└─ endorses → Device signing key (Secure Enclave P-256)           seal.endorse.v3
     ├─ signs → every EstateEvent, custody receipts
     └─ certifies → Device KEM bundle: X25519 + ML-KEM-768 (KEMBundle)
          └─ unwraps → what is wrapped to this device (HybridWrap):

Envelope Content Key   random 256 bit, AES-256-GCM, one per envelope
    listed in
Key Table              one per RECIPIENT, under a random Key Table Key
    Key Table Key reachable two ways
    ├─ wrapped to the OWNER's devices
    └─ AES-GCM under the Estate Key, THEN wrapped to the RECIPIENT's devices
Estate Key             one per owner per epoch
    reachable two ways
    ├─ wrapped to the OWNER's devices
    └─ Shamir over GF(256), threshold M of N, each share wrapped to one
       custodian's devices; SHA-256 commitments in the signed record
```

- **Hybrid wrap** (`Crypto/KEMBundle.swift`): X25519 ephemeral agreement and
  ML-KEM-768 encapsulation feed one HKDF-SHA256 with every public value in
  the salt; AES-256-GCM with a domain separated AAD naming estate, epoch and
  purpose. A device that predates the lattice key gets the classical suite
  and the envelope says which. This replaces the never-true claim in the old
  docs that `HybridKEM` was hybrid; the legacy X25519 path survives for
  custody receipts and reads either bundle form.
- **Shamir** (`Crypto/Shamir.swift`): the AES field, index ‖ bytes shares,
  Lagrange at zero, vectors from an independent Python implementation. Bad
  shares are caught by commitment and attributed to a custodian before any
  combine.
- **Recipient isolation**: a key table names its recipient nowhere and is
  found by trial decryption. The claimant's Estate Key opens the inner layer
  of every table and the outer layer of none. What leaks: recipient count,
  blob count and sizes, and that a hash has some part in an estate.
- **Rotation**: new epoch when custodians or threshold change. New Estate
  Key, shares, owner wraps and per table inner ciphertexts. Blobs untouched.
- **The Estate Key is published in the clear at release**, because on its own
  it opens nothing. This is what lets recipients open their own tables
  without the claimant ever learning who they are.

## 3. Modules

| Module | Responsibility |
|---|---|
| `Identity/IdentityManager` | Root identity, Secure Enclave device key, X25519 and ML-KEM-768 keys, endorsement verification (v3 framed, v2 canonical only), root-signed revocation |
| `Identity/KeyPinStore` | Root key pinning: pinned at proof, enforced on every directory fetch, dropped only on removing a person |
| `Identity/BackupCredential`, `Ceremony/BackupKeyCeremony` | FR-3 backup credentials, unchanged |
| `Ceremony/CeremonyManager` | Registration, sign-in, the in-person ceremony, custody receipts, the release tap |
| `Crypto/Shamir`, `Crypto/KEMBundle`, `Crypto/HybridKEM` | The primitives above |
| `Estate/EstateModels` | Estate, Envelope, Custodian, Recipient, ReleasePolicy, EstateStore |
| `Estate/EstateKeys` | The hierarchy: epochs, tables, content |
| `Estate/EstateLog` | Signed, hash linked events; bodies; verifier; local store |
| `Estate/ReleaseMachine`, `Estate/ReleaseFeed` | Pure state machine and events-to-snapshot |
| `Estate/EstateEngine` | Every side effect: keychain, CloudKit, timestamps, ceremony |
| `Estate/Capsule` | The export |
| `Record/RecordEvent`, `Record/TimestampService` | The record projection and RFC 3161 |
| `Sync/SyncEngine`, `Sync/EstateDirectory`, `Sync/BackupDirectory` | CloudKit |
| `Time/Clock` | `Clock`, `SystemClock`, `SimulatedClock`, `Clocks.current` |
| `SelfTest/*` | The in-target test suites (no test target exists) |

## 4. CloudKit data model

Public database, all world readable, all signed or encrypted:

- `Identity` (unchanged): `publicKey`, `tier`, `displayName`, `credentialID`,
  `deviceEndorsements` (Bytes, `[DeviceEndorsement]`), `backupEndorsements`,
  `revocations`.
- `EstateEvent` **(new)**: name `eev.<estateID>.<eventID>`; `estate` (String,
  **queryable**), `kind`, `actor`, `payload` (Bytes, the signed event JSON).
  Immutable except that `timestampToken` is added later.
- `MediaAsset` (reused): every encrypted blob, as a `CKAsset`. Names
  `est.<estateID>.epoch.<n>`, `est.<estateID>.table.<tableID>`,
  `est.<estateID>.blob.<blobID>`.
- `GroupInvite` (reused): `estinv.<hash>.<estateID>`, `recipient` queryable,
  `payload` an encrypted `EstateInvite`.

One subscription per estate on `EstateEvent` (content available, static
alert), plus the existing invite subscription. See
[CLOUDKIT_DEPLOY.md](CLOUDKIT_DEPLOY.md) for the schema deploy.

## 5. Core flows

**Seal (owner).** Validate the rule → look up own devices, custodians and
recipients through pinned fetches → new epoch if needed (Estate Key, shares,
owner wraps, `epochPublished` with commitments and each custodian's root key)
→ encrypt and upload every unsealed envelope's payload and media → build,
encrypt and upload one key table per recipient → `vaultUpdated` → encrypted
invites → subscription → heartbeat. Idempotent; the estate records progress.

**Heartbeat (owner).** On every launch and foreground: refresh, post
`cancellation` if a claim is live, post `heartbeat`, stamp both.

**Refresh (custodian, recipient).** Invites → for each estate: fetch events →
admit the owner's events via the pinned owner key → take the newest epoch
statement, pin fellow custodians from it → admit custodian events → merge →
snapshot → state → subscription → post `silenceObserved` if overdue and none
in 24 hours.

**Claim, object, tap, release, open.** [RELEASE.md](RELEASE.md) sections 3
and 6; `EstateEngine` methods of the same names.

## 6. WebAuthn

RP ID `sealmessenger.com`. Challenges are generated and verified on device by
whoever needs the proof. `WebAuthnAssertion.verify` enforces the RP hash, user
presence and `clientData.type == webauthn.get`; user verification is
optional per call. All four security key requests use `.preferred` UV.

## 7. Threat model

| Threat | Defence |
|---|---|
| Apple or anyone reads an envelope | Content keys inside encrypted tables; tables need recipient's device key plus Estate Key; Estate Key needs owner device or M shares |
| Directory swaps a friend's, custodian's or claimant's root key | Pinned at proof; enforced on every fetch; fellow custodians pinned from the owner's signed epoch statement |
| Directory forges or hides events | Every event device signed, device endorsement re-verified; hiding is detectable only through capsules held by several custodians and by timestamp tokens |
| Directory un-verifies a device | Unsigned `revokedAt` removed; only root-signed revocations count |
| A signature from another site or a registration replayed | RP hash, UP and type enforced |
| A re-split endorsement evades revocation | v3 framing; v2 accepted only at canonical lengths |
| A custodian submits a bad share | Per share commitment in the signed record names them |
| Custodians collude early | Cannot: shares are useless until the machine reaches claimOpen, and the claimant's phone enforces that; more to the point, M of N colluding custodians is the trust the owner chose. The record shows exactly who tapped when. |
| Owner declared dead while alive | Silence, warnings on every channel, grace, one-tap cancel without the hardware key, objections |
| A custodian's phone clock lies | Timestamp tokens on heartbeats, claims, taps, releases; the feed prefers the authority's time |
| Stolen phone, unlocked | Secrets shown only after Face ID; SE keys device bound; a stolen owner phone can heartbeat (a thief keeping you "alive" is a known limit) |
| Harvest now, decrypt later | ML-KEM-768 in every estate wrap |
| The company disappears | The capsule and `tools/verify_capsule.py` |

Accepted and documented: metadata (who has a part in whose estate, counts and
sizes), one key one identity being deterrence only, and everything in
PRODUCT.md section 8.

## 8. Backup credentials (FR-3)

Unchanged from v0.1 section 11 and still in force: two-sided
`seal.backup.v1` / `seal.backup.accept.v1` statements, the root-or-backup
authority set in `verifiedDevices`, asymmetric revocation. A phone recovered
with a backup key gets fresh KEM keys and therefore needs the owner to seal
again (owner) or the owner to re-seal for it (custodian or recipient) before
it can open anything wrapped to the lost phone. The UI says so.

## 9. Tech stack

SwiftUI, iOS 26.5, AuthenticationServices, CryptoKit (P-256, X25519,
ML-KEM-768, AES-GCM, HKDF), CloudKit public database, keychain JSON stores,
AVFoundation for the voice message. No third party dependencies. No backend.
