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
PARTIAL: FR-5/6 mutuality not enforced + friendships local-only; FR-11 (no video/reactions/replies, no 64 cap). Offline outbox DONE 6/12 (ChatEngine.flushOutbox — wire records queued in keychain, chain committed pre-save so retries never reuse keys/indices, "already exists" = delivered, clock icon until flushed; limitation: first message of a NEW epoch still needs the directory reachable for recipient KEM keys).
TODO: FR-3 backup keys, ML-KEM spike, review video (FR-24), FR-22 review-account demo gating, key transparency gossip, shared-zone migration (SDS §8), offline outbox.
DONE 6/12 PM: demo mode (launch-arg), 1-key-1-identity excludedCredentials, group-invite push (ensureInviteSubscription), Face ID app lock (AppLock.swift — per-identity keychain flag, deviceOwnerAuthentication w/ passcode fallback, toggle in ProfileView, NSFaceIDUsageDescription added to pbxproj INFOPLIST_KEYs), screenshot disclosure (MessagePayload/ChatMessage `kind:"screenshot"` through normal E2EE pipeline; centered orange notice in ChatView; builds ≤4 render it as an empty bubble — harmless, family updates together), forge log share card (ForgeShareCard + ImageRenderer @3x, ShareLink in ForgeLogView toolbar).

## Known issues / gotchas
- PIN'd security keys: "wrong PIN" failures were from discoverable-credential creation (CTAP2 clientPIN over NFC); fixed by residentKey .discouraged. Root cause unconfirmed — wanted: USB-C test + Yubico Authenticator retry count.
- iOS caches failed AASA checks: delete+reinstall app if WebAuthn errors immediately (code 1001).
- TestFlight = Production CloudKit env; Xcode builds = Development. Separate worlds.
- Two-device E2EE receive path VALIDATED 2026-06-12 (TestFlight/Production, Nathan ↔ Karen): inbound text + encrypted photo decrypted, verified, and displayed. Test used TWO identities minted from ONE YubiKey 5Ci (pre-exclusion build) — that setup stops working once excludedCredentials ships; future tests need passkeys or a second key. Still unvalidated: push with app fully closed; disappearing-message expiry on both ends; friend ceremony was one-directional (Nathan's USB-C-only key can't reach a Lightning iPhone — NFC or passkey needed for the reverse ceremony; passkey nearby-device friending path still untested).
- Schema changes always: exercise in dev (or add manually in console) → Deploy to Production.
- 1-key-1-identity: registration passes ALL directory credential IDs as `excludedCredentials` (both tiers); authenticator refuses a second identity → `.matchedExcludedCredential` → "sign in instead" error. Deterrence only (FIDO2 reset / modified client evade; SDS §7). **Requires `recordName QUERYABLE` index on Identity in CloudKit console** — add in dev + deploy WITH the revocations field. Scale ceiling ~1k identities.
- Demo mode (FR-22/23 partial): launch arg `-SealDemoMode` seeds local identity/friends/chats via DemoFixtures (fully local, non-destructive, watermarked; `-SealDemoHideWatermark` for marketing shots). Review-account gating still TODO.
- UI rule: seal mascot only on social surfaces, never on security surfaces. Brass = trust moments only.

## App Store status (2026-06-12)
- ASC metadata DONE: name/subtitle ("Provably human group chat"), promo text, description, keywords, support/marketing/privacy URLs (site pages live in jasonepage.github.io/seal/ — landing, privacy, support; push that repo), category Social Networking, age 4+ (honest answers; Signal precedent), content rights (no third-party), encryption exempt (CryptoKit only — consider ITSAppUsesNonExemptEncryption=NO in Info.plist), DSA non-trader.
- External TestFlight group "parents" created; build must be added via group → Builds → + (needs complete Test Information), triggers Beta App Review.
- App Review info: sign-in NOT required (passkey explained in notes — notes text drafted in session), reviewer phone needed, demo video (FR-24) still TODO — only real submission blocker. Release set to automatic — switch to manual if approval shouldn't mean instant launch.
- App Privacy: change "Data Not Collected" → Name / app functionality / not linked (display names in public directory count as collected).
- Demo mode is launch-arg only; reviewers can't trigger it. FR-22 review-account gating still TODO; v1 strategy is passkey registration + Note to self + video.

## Process notes
- User prefers numbered steps for ops tasks, concise replies. Mom is a tester + gave the mascot feedback.
- Commit cadence: after each working milestone. Current code may be uncommitted — check `git status`.
