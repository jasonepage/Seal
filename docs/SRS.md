# Software Requirements Specification — Seal

**Version:** 0.1 · **Date:** 2026-06-11 · **Author:** Nathan Page
**Platform:** iOS · **Companion doc:** [SDS.md](SDS.md)

## 1. Introduction

### 1.1 Purpose
Seal is an iOS group-messaging app where identity and trust are rooted in physical FIDO2 hardware security keys (YubiKey, etc.). Friendships are established by physically tapping a friend's hardware key on your phone — trust requires real-world presence, not usernames or phone numbers.

### 1.2 Scope
- 1:1 and group end-to-end-encrypted (E2EE) chat with a Snapchat-like UX (camera-forward, ephemeral options).
- Hardware key as the root of identity: sign-in, friend ceremonies, device endorsement, group invites.
- CloudKit-first backend: no custom server holds credentials; Apple infrastructure provides storage, sync, and push.

### 1.3 Definitions
| Term | Meaning |
|---|---|
| Hardware key | FIDO2/CTAP2 security key with NFC or USB-C (e.g., YubiKey 5C NFC) |
| Friend ceremony | In-person tap of a friend's hardware key to establish mutual trust |
| Device key | P-256 keypair in the iPhone's Secure Enclave, endorsed by the hardware key |
| Endorsement | Signature by a hardware key over a device key, binding device to identity |
| RP ID | WebAuthn Relying Party identifier (a domain you control) |

### 1.4 Constraints
- **C1:** FIDO2 keys sign assertions only; they cannot encrypt/decrypt. Message E2EE must use Secure Enclave keys gated by hardware-key endorsement.
- **C2:** iOS security-key APIs (`ASAuthorizationSecurityKeyPublicKeyCredentialProvider`) require an RP ID — a domain serving an `apple-app-site-association` file. Static hosting only; no backend logic required.
- **C3:** CloudKit: 1 MB/record, ~250 MB asset practical limit, no server-side code — all signature verification happens on-device.
- **C4:** All users need an iCloud account and a supported hardware key.
- **C5:** iOS 17+; NFC tap or USB-C insertion for key ceremonies.

## 2. Users and Use Cases
- **U1 New user:** registers an identity with their hardware key.
- **U2 Friend pair:** two people meet in person and tap keys to befriend.
- **U3 Group member:** creates/joins group chats, sends text, photos, video.
- **U4 Multi-device user:** adds an iPad by endorsing it with the hardware key.
- **U5 Key-loss victim:** recovers via a pre-registered backup key, or loses the identity.

## 3. Functional Requirements

### 3.1 Identity & Registration
- **FR-1:** User registers by creating a FIDO2 credential on their hardware key (NFC/USB-C); the credential public key is the user's root identity.
- **FR-2:** App generates a Secure Enclave device key; the hardware key signs an endorsement of it. Only endorsed devices can decrypt messages.
- **FR-3:** User may register up to 2 backup hardware keys at setup; any registered key can endorse new devices.
- **FR-4:** Profile (display name, avatar) is stored in the user's CloudKit private/public zone, signed by the device key.

### 3.2 Friend Ceremony
- **FR-5:** To befriend, user A taps user B's hardware key on A's phone. A's app issues a fresh challenge; B's key signs it; A now holds an authenticated copy of B's root public key. Repeat in reverse for mutuality (single combined flow in UI).
- **FR-6:** Friendship records (each party's signed attestation of the other's key) are stored in CloudKit and verified on-device by all clients.
- **FR-7:** Remote befriending (QR/link) MAY be offered later but is out of scope for v1 — physical presence is the product.
- **FR-8:** Users can remove friends; removal revokes their ability to invite the user to groups.

### 3.3 Group Chats
- **FR-9:** Any user can create a group; creator becomes admin. Membership changes are signed by the actor's device key and verified by all members.
- **FR-10:** Only friends (per FR-5) may be invited. Invitee accepts in-app; acceptance is signed.
- **FR-11:** Groups support 2–64 members, text, images, video ≤ 60 s, reactions, and replies.
- **FR-12:** Optional ephemeral mode: messages display a TTL and clients delete at expiry (client-enforced; see NFR-7 honesty requirement).
- **FR-13:** Admins can remove members; removal triggers group key rotation so removed members cannot read new messages.

### 3.4 Messaging
- **FR-14:** All message content is E2EE; CloudKit stores only ciphertext, signed sender metadata, and routing data.
- **FR-15:** Messages are signed by the sender's device key; receivers verify the device key chains to a hardware-key endorsement of a known friend.
- **FR-16:** Delivery via CloudKit shared-zone sync + APNs push (CKSubscription). Offline messages sync on next launch.
- **FR-17:** Media is encrypted client-side and stored as CKAssets.

### 3.5 Device & Key Management
- **FR-18:** Adding a device requires a hardware-key tap on the new device (endorsement ceremony) plus existing-device approval.
- **FR-19:** User can revoke a device; revocation is signed by a hardware key and propagated; group keys rotate.
- **FR-20:** Losing all registered hardware keys = identity is unrecoverable (explicitly communicated at onboarding). No email/SMS reset exists by design.

### 3.6 Account Tiers, Review & Demo Mode
- **FR-21:** The app supports two identity tiers: **Passkey** (platform passkey via `ASAuthorizationPlatformPublicKeyCredentialProvider`, Face ID-backed) and **Verified** (FIDO2 hardware key). Both use the same WebAuthn code path; Verified identities display a distinct badge, and groups may be marked "Verified-only."
- **FR-22:** A **demo mode**, activated only by a designated App Review account (credentials in review notes), provides: passkey-based registration, a seeded identity with pre-established friends, and two active demo group chats with synthetic message history.
- **FR-23:** Demo mode is fully disclosed in App Review notes and visually watermarked ("Demo") in-app; demo identities cannot befriend or message real users.
- **FR-24:** A demo video showing the real hardware flow (NFC tap registration, two-phone friend ceremony) accompanies every submission per Guideline 2.1.

## 4. Non-Functional Requirements
- **NFR-1 Security:** E2EE for all content; forward secrecy on group key rotation events; no plaintext or private keys ever leave the device; Secure Enclave keys are non-exportable.
- **NFR-2 Trust:** No trust-on-first-use for friends — every friendship is rooted in a physical key tap and verifiable signature chain.
- **NFR-3 Privacy:** No phone numbers, emails, or contact upload. Apple (CloudKit) sees ciphertext + metadata only; document this honestly.
- **NFR-4 Performance:** Message send-to-push p50 < 2 s on LTE; ceremony tap-to-confirm < 5 s.
- **NFR-5 Availability:** Inherits CloudKit SLA; app must function read-only offline with queued sends.
- **NFR-6 Cost:** $0 server cost target (CloudKit free tier + static AASA hosting); Apple Developer Program only.
- **NFR-7 Honesty:** UI must not overclaim — ephemeral deletion is client-enforced and screenshots are possible; disclose like Snapchat does (screenshot detection best-effort).
- **NFR-8 Accessibility/UX:** Key ceremonies must have clear NFC coaching UI; support USB-C keys for devices/users where NFC fails.

## 5. Out of Scope (v1)
Android/web clients, stories/snap map, voice/video calls, remote friend adding, message search server-side, multi-iCloud-account support.

## 6. Risks
| Risk | Impact | Mitigation |
|---|---|---|
| CloudKit can't verify signatures server-side | Malicious client could write garbage records | All clients verify signature chains; unverifiable records dropped |
| Hardware key loss | Permanent identity loss | Mandatory backup-key prompt at onboarding (FR-3) |
| RP ID domain requirement | Need a domain + AASA file | One-time static hosting (GitHub Pages / CloudFront) |
| Apple account dependency | Excludes non-iCloud users | Accepted for v1; hybrid backend is the documented migration path (SDS §8) |
| Group key rotation complexity | Bugs → members locked out | Conservative sender-key design + extensive unit tests |
