# Software Design Specification — Seal

**Version:** 0.1 · **Date:** 2026-06-11 · **Companion doc:** [SRS.md](SRS.md)

## 1. Architecture Overview

CloudKit-first, serverless. The only non-Apple infrastructure is a static domain serving the WebAuthn AASA file.

```
┌─────────────── iPhone ───────────────┐
│ SwiftUI App                          │
│ ├─ ChatUI / CameraUI                 │
│ ├─ IdentityManager  ──── NFC/USB-C ──┼──► FIDO2 Hardware Key
│ ├─ CeremonyManager  (WebAuthn via    │     (root identity, signs only)
│ │   ASAuthorizationServices)         │
│ ├─ CryptoEngine ──► Secure Enclave   │
│ │   (device keys, group sender keys) │
│ └─ SyncEngine ──► CloudKit           │
└──────────────────┬───────────────────┘
                   │ ciphertext + signed records only
        ┌──────────▼──────────┐      ┌────────────────────┐
        │ CloudKit            │      │ Static host        │
        │ public DB: identity │      │ sealmessenger.com/.well- │
        │ directory           │      │ known/apple-app-   │
        │ shared zones: groups│      │ site-association   │
        │ APNs: push          │      │ (RP ID only)       │
        └─────────────────────┘      └────────────────────┘
```

**Trust model in one sentence:** a hardware key's FIDO2 credential is a user's root public key; it endorses Secure Enclave device keys; device keys sign everything else (messages, invites, membership changes); every client verifies the full chain and trusts nothing the server says.

## 2. Key Hierarchy & Cryptography

```
Root identity (FR-21 tiers)
├─ Verified: FIDO2 hardware key (P-256, signs only)
└─ Passkey:  platform passkey (Face ID, same WebAuthn path)
   └─ endorses → Device signing key (Secure Enclave P-256, non-exportable)
        ├─ signs → messages, profile, membership log, KEM keys
        └─ certifies → Device KEM bundle (X25519 + ML-KEM-768, software)
             └─ unwraps → Group sender keys (per-member symmetric ratchets)
                  └─ derives → per-message AES-256-GCM keys
```

- **Root identity:** the WebAuthn credential ID + public key created at registration (FR-1/FR-21). Assertions over app-generated challenges prove key presence. Verified and Passkey tiers differ only in authenticator; all downstream crypto is identical.
- **Device endorsement:** registration produces a root-key assertion whose `clientDataHash` commits to the new device's signing public key — a verifiable "this root vouches for this device" certificate. Same mechanism for friend ceremonies (challenge commits to a friendship statement).
- **Hybrid post-quantum wrapping:** the Secure Enclave only does P-256, so each device also carries a software **KEM bundle** — X25519 **and** ML-KEM-768 (CryptoKit), combined HPKE-style: both shared secrets feed one HKDF, so an attacker must break both classical ECDH and the lattice KEM ("harvest-now-decrypt-later" resistance). The bundle's public keys are signed by the SE device key, so its authenticity is still enclave-rooted even though the KEM private keys live in the keychain (`.afterFirstUnlockThisDeviceOnly`, non-synchronized).
- **Group messaging — MLS-informed sender keys:** each member maintains a per-group symmetric **sender chain**; per-message keys are ratcheted forward (`chainKey ← HKDF(chainKey)`) and deleted after use, giving per-message forward secrecy. Chains are distributed wrapped to every member device via the hybrid KEM. Membership changes advance the **epoch**: removal forces fresh chains wrapped only to remaining devices (post-compromise secrecy at epoch granularity). This is deliberately sender-keys-with-epochs rather than full RFC 9420 MLS — same security goals at 64-member scale, a fraction of the implementation surface, with a documented upgrade path to MLS if groups grow.
- **Transcript integrity:** every message signature covers `(groupID, epoch, sender chain index, prev-message hash)`, making per-sender transcripts tamper-evident and reorder-evident — the server (or a member) can't silently drop or reorder a sender's messages.
- **Key transparency, peer-to-peer:** clients gossip the head hash of each friend's `Identity` record (endorsements + revocations form an append-only hash chain). If Apple ever served two friends different versions of your identity, their clients detect the fork on next contact. No transparency log server needed.
- **Deniability note:** messages are device-signed, so transcripts are cryptographically attributable — the *opposite* of Signal's deniability. This is a deliberate product choice (hardware-rooted accountability); documented so it's never an accident.
- **1:1 chats** are 2-member groups — one code path.
- **Why not encrypt with the hardware key:** FIDO2/CTAP2 exposes sign-only operations (C1). Some keys offer PIV/OpenPGP applets but iOS lacks practical CCID access over NFC; out of scope.

## 3. Module Design

| Module | Responsibility | Key APIs |
|---|---|---|
| `IdentityManager` | Root identity, device keys, endorsement chain storage/verification | `ASAuthorizationSecurityKeyPublicKeyCredentialProvider`, `SecKeyCreateRandomKey` (Secure Enclave) |
| `CeremonyManager` | UX + protocol for registration, friend, and device ceremonies | `ASAuthorizationController`, NFC coaching UI |
| `CryptoEngine` | Sender keys, ratchets, wrap/unwrap, sign/verify | CryptoKit (`AES.GCM`, `HKDF`, `P256`) |
| `SyncEngine` | CloudKit zones, CKShare lifecycle, subscriptions, conflict handling, outbox queue | `CKSyncEngine` |
| `VerificationGate` | Validates every inbound record's signature chain before it reaches the model layer | — |
| `ChatStore` | Local persistence (encrypted SQLite/SwiftData), message TTL enforcement | — |
| `ChatUI` | SwiftUI: camera-forward capture, chat list, group screens, ceremony flows (see [UI.md](UI.md)) | — |
| `DemoFixtures` | FR-22/23: seeded demo identity, synthetic friends/groups, demo watermark; compiled in but inert without the flagged review account | — |

## 4. CloudKit Data Model

**Public DB** (discoverability, all records signed):
- `Identity` — rootPublicKey (record name = key hash), displayName, avatar, deviceEndorsements[], backupKeyEndorsements[], revocations[]

**Private DB, custom zone per group, shared via `CKShare`:**
- `Group` — groupID, name, signed `MembershipLog` (append-only: add/remove/role records, each signed by actor)
- `KeyEnvelope` — senderKey wrapped to (memberDevice), epoch number
- `Message` — ciphertext, senderDeviceKeyRef, signature, epoch, ttl, replyRef
- `MediaAsset` — CKAsset (encrypted blob), contentKey wrapped in parent message

Group transport = CloudKit **shared zones**: creator owns the zone, members accept a `CKShare`. Membership in the share is *transport-level only*; cryptographic membership is the signed `MembershipLog` + key epochs — a zone participant without valid keys reads nothing.

## 5. Core Flows

**Registration (U1):** create FIDO2 credential (tap key) → generate SE device key → second tap signs endorsement → write `Identity` to public DB → prompt backup key (FR-3).

**Friend ceremony (U2, both in person):**
1. A's phone generates challenge `c_A` committing to `(A.root, B.claimed_root, timestamp)`.
2. B taps **B's key** on A's phone → assertion proves B controls B.root. A stores signed friendship attestation.
3. Roles swap on B's phone (B can scan a QR from A's screen to prefill A's identity, then A taps A's key).
4. Both write mutual `Friendship` attestations; clients verify both directions before allowing invites.

**Group invite (U3):** admin signs `add(member)` into MembershipLog → CKShare invitation via CloudKit sharing → invitee accepts + verifies log → each member wraps current sender key to the new member's devices (new epoch optional; required only on removal).

**Message send:** ratchet chain key → AES-GCM encrypt → sign with device key → `CKSyncEngine` outbox → push fan-out via CKSubscription. Receive: verify signature chain (`VerificationGate`) → decrypt → store → schedule TTL deletion if ephemeral.

**Member removal (FR-13):** admin signs `remove` → all remaining members generate fresh sender keys (new epoch) wrapped only to remaining devices → removed member's share participation revoked (transport) — but security never depends on the transport revocation.

**New device (U4):** new device generates SE key → displays QR → hardware key tap on new device signs endorsement → existing device co-signs → endorsement appended to `Identity` → friends' clients accept it on next verify; group members re-wrap sender keys to the new device.

**Revocation (FR-19/U5):** signed revocation record in `Identity`; clients treat revoked device keys as invalid from the revocation's signed timestamp; groups rotate epochs.

## 6. WebAuthn / RP Notes
- RP ID requires a domain (e.g., `sealmessenger.com`) serving `/.well-known/apple-app-site-association` with a `webcredentials` entry — static file, zero backend logic (C2).
- Challenges are generated and verified **on-device by peers** (no server ceremony). This is non-standard WebAuthn but sound: the verifier is whoever needs the proof (the friend's phone), and challenges are fresh + context-bound to prevent replay.
- Attestation: request `direct` attestation at registration if you later want to enforce genuine-key policies; don't enforce in v1.

## 7. Threat Model (abridged)
| Threat | Defense |
|---|---|
| Server (Apple) reads messages | E2EE; CloudKit holds ciphertext only |
| Server forges membership/identity | All records signed; clients verify chains; server is untrusted for integrity |
| Stolen phone (unlocked) | SE keys gated by `biometryCurrentSet` access control; hardware key absent → no new endorsements |
| Stolen hardware key | Key alone can't read messages (no SE device key); victim revokes via backup key |
| Replay of ceremony assertions | Fresh challenges bound to identities + timestamps |
| Removed member reads on | Epoch rotation on removal |
| Metadata exposure | Accepted residual risk: Apple sees who talks to whom and when. Document honestly (NFR-3). |

## 8. Migration Path (if CloudKit outgrown)
Add a thin Vapor/Cloudflare-Workers backend for: standard WebAuthn ceremonies, an identity directory not tied to iCloud, and Android/web clients. The signature-chain design is transport-agnostic — records move to any store without redesigning trust.

## 9. Tech Stack Summary
SwiftUI + iOS 17, AuthenticationServices (FIDO2), CryptoKit + Secure Enclave, CKSyncEngine (CloudKit), SwiftData (encrypted local store), static AASA hosting. Zero recurring server cost.
