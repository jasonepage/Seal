# Seal

Group chat where friendships are forged in person. Your identity is rooted in a physical FIDO2 hardware key — to become friends, you tap your key on their phone. No usernames, no phone numbers, no password resets.

## How it works
- **Identity:** a FIDO2 hardware key (Verified tier) or platform passkey (standard tier) is your root credential. It endorses non-exportable Secure Enclave device keys; device keys sign everything else.
- **Friendship:** an in-person tap ceremony. Your friend's key signs a challenge on your phone — cryptographic proof, no trust-on-first-use.
- **Messaging:** E2EE group chat (1:1 is a 2-member group). Ratcheted sender keys with hybrid post-quantum wrapping (X25519 + ML-KEM-768), epoch rotation on member removal.
- **Backend:** none. CloudKit shared zones carry ciphertext and signed records; every client verifies the full signature chain. The only external dependency is a static AASA file on `sealmessenger.com` (WebAuthn RP ID).

## Docs
| Doc | Contents |
|---|---|
| [docs/SRS.md](docs/SRS.md) | Requirements: identity tiers, ceremonies, groups, demo/review mode, risks |
| [docs/SDS.md](docs/SDS.md) | Architecture: key hierarchy, crypto design, CloudKit data model, core flows, threat model |
| [docs/UI.md](docs/UI.md) | "Vault Warmth" design language, screen specs, ceremony choreography |

## Project structure
```
Seal/
├─ SealApp.swift            # entry point
├─ Identity/                # root identity, device keys, endorsement chains
├─ Ceremony/                # registration, friend, and device-add ceremonies
├─ Crypto/                  # sender chains, hybrid KEM wrapping, sign/verify
├─ Sync/                    # CloudKit zones, CKShare, outbox, verification gate
├─ Store/                   # local encrypted persistence, TTL enforcement
├─ Theme/                   # Vault Warmth palette, haptics, seal animations
└─ Views/                   # Chats, Camera, Circle, ceremony sheets
```

## Requirements
iOS 26+, Xcode 26, an iCloud account, and (for the Verified tier) a FIDO2 security key with NFC or USB-C.

## Status
Pre-alpha: docs complete, scaffold in place. First milestone: ceremony spike — real WebAuthn security-key registration + NFC UX on device.
