# Seal — Session Handoff

**Updated:** 2026-06-12 · **Owner:** Nathan (Jason Page) · `natepage67@gmail.com`
**Repo:** `~/Documents/GitHub/Seal` (mounted) · **App:** iOS 26.5+, SwiftUI, Xcode project with file-system-synced groups (new files under `Seal/` auto-join the target)

## What Seal is
E2EE group chat where friendships require an in-person ceremony: friend taps THEIR FIDO2 hardware key (or passkey via hybrid flow) on YOUR phone; you verify their signature against the CloudKit public directory. Wedge: "everyone is provably human and provably someone you've met" (anti-bot/anti-AI positioning — see docs/VISION.md). Zero servers: CloudKit public DB + one static AASA file.

## Key identifiers
- Team ID: `8C4BM6A82T` · Bundle: `io.github.jasonepage.Seal`
- WebAuthn RP ID: `sealmessenger.com` (Porkbun domain, Cloudflare zone, Worker "plain-darkness-c20d" serves static site incl. `/.well-known/apple-app-site-association` — live and verified)
- CloudKit container: `iCloud.io.github.jasonepage.Seal`
- App Store Connect: "Seal: Provably Human Chat", SKU seal001; TestFlight internal testing live (family = internal testers); export compliance = "None of the algorithms" (CryptoKit only)

## Architecture (docs/SDS.md is authoritative)
- Root identity = WebAuthn credential (hardware key "Verified" tier = brass; passkey = silver). Root endorses per-device Secure Enclave P-256 signing key + software X25519 KEM key via assertion whose challenge commits to BOTH keys (`seal.endorse.v2` — binding auth+encryption keys, MITM fix).
- Messages: per-sender chains, HKDF ratchet, AES-GCM; AAD binds group|epoch|sender|index|prev-ciphertext-hash (transcript tamper evidence; epoch 0 = legacy `seal.msg.v2` format, epoch ≥1 = `v3`). Sender chains wrapped to members via X25519 ephemeral-static (ML-KEM hybrid still TODO, spike needed).
- Transport: CloudKit public DB, deterministic record names (no queries except GroupInvite): `msg.<group>[.e<epoch>].<sender>.<idx>`, `kenv.<group>[.e<epoch>].<sender>.<recipient>`. Push = CKQuerySubscription on Message.recipients.
- Groups: signed GroupInvite records (kind nil=invite, "update"=membership change); creator = admin; removal bumps epoch → fresh chains exclude removed member (FR-13 done).
- Revocation (FR-19 done): root-key assertion committing to device pub (`seal.revoke.v1`), stored in Identity.revocations; fetchIdentity filters revoked endorsements.
- Sign-in: assertion w/ empty allowList → directory lookup by credentialID hash → verify vs published pubkey → endorse this device (appended, multi-device-ish; senders wrap to `.last` endorsement). NOTE: security-key sign-in disabled (residentKey back to `.discouraged` — discoverable creds forced CTAP2 PIN ceremony which failed on PIN'd keys over NFC; passkey sign-in works).
- Storage: all local state keychain-JSON namespaced per identity hash (`seal.chats.<hash>` etc.); Sign out wipes local, identity survives in directory.

## CloudKit schema (Production deployed)
Types: Identity (publicKey, tier, displayName, credentialID, deviceEndorsements, revocations*), Message (ciphertext, devicePub, signature, sentAt, recipients[List, queryable]), KeyEnvelope (envelope), GroupInvite (recipient[queryable], payload), MediaAsset (blob Asset).
*`revocations` field added in code AFTER last deploy — **must exercise in dev + re-deploy before next TestFlight build.**

## Feature status vs SRS
DONE: registration both tiers, directory, friend ceremony (QR + tap, fingerprint phrases "🦭 noon jade pebble"), E2EE text+photos (camera tab, encrypted CKAssets, key inside payload), groups + invites, disappearing messages (TTL inside ciphertext), push, transcript chain, epoch rotation/removal (admin = creator, UI in verification drawer), device revocation + device list UI, sign-in, forge log, app icon (brass wax seal), drawn vector seal mascot + colony bar (member count in chat header → taps into verification drawer).
PARTIAL: FR-5/6 mutuality not enforced + friendships local-only; FR-11 (no video/reactions/replies, no 64 cap); no offline outbox.
TODO: FR-3 backup keys, ML-KEM spike, demo mode + review video (FR-22/23/24, needed for App Store), key transparency gossip, FaceID app-lock, shared-zone migration (SDS §8).

## Known issues / gotchas
- PIN'd security keys: "wrong PIN" failures were from discoverable-credential creation (CTAP2 clientPIN over NFC); fixed by residentKey .discouraged. Root cause unconfirmed — wanted: USB-C test + Yubico Authenticator retry count.
- iOS caches failed AASA checks: delete+reinstall app if WebAuthn errors immediately (code 1001).
- TestFlight = Production CloudKit env; Xcode builds = Development. Separate worlds.
- Family testing in progress (passkey tier). Two-device E2EE receive path NOT yet verified end-to-end — top validation priority.
- Schema changes always: exercise in dev (or add manually in console) → Deploy to Production.
- UI rule: seal mascot only on social surfaces, never on security surfaces. Brass = trust moments only.

## Process notes
- User prefers numbered steps for ops tasks, concise replies. Mom is a tester + gave the mascot feedback.
- Commit cadence: after each working milestone. Current code may be uncommitted — check `git status`.
