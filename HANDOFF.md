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
Types: Identity (publicKey, tier, displayName, credentialID, deviceEndorsements, revocations*, perks*), Message (ciphertext, devicePub, signature, sentAt, recipients[List, queryable]), KeyEnvelope (envelope), GroupInvite (recipient[queryable], payload), MediaAsset (blob Asset), PerkGrant* (grant Bytes), PerkClaim* (claim Bytes).
*Added in code AFTER last deploy — **must exercise in dev + re-deploy before next TestFlight build** (revocations + perks fields, PerkGrant/PerkClaim types, recordName QUERYABLE index on Identity). PerkClaim security role must stay default (creator-only write) — first-create-wins depends on it; PerkGrant needs World read.

## Feature status vs SRS
DONE: registration both tiers, directory, friend ceremony (QR + tap, fingerprint phrases "🦭 noon jade pebble"), E2EE text+photos (camera tab, encrypted CKAssets, key inside payload), groups + invites, disappearing messages (TTL inside ciphertext), push, transcript chain, epoch rotation/removal (admin = creator, UI in verification drawer), device revocation + device list UI, sign-in, forge log, app icon (brass wax seal), drawn vector seal mascot + colony bar (member count in chat header → taps into verification drawer).
PARTIAL: FR-5/6 mutuality not enforced + friendships local-only; FR-11 (no video/reactions/replies, no 64 cap). Offline outbox DONE 6/12 (ChatEngine.flushOutbox — wire records queued in keychain, chain committed pre-save so retries never reuse keys/indices, "already exists" = delivered, clock icon until flushed; limitation: first message of a NEW epoch still needs the directory reachable for recipient KEM keys).
TODO: FR-3 backup keys, ML-KEM spike, review video (FR-24), FR-22 review-account demo gating, key transparency gossip, shared-zone migration (SDS §8), offline outbox.
DONE 6/12 (late): founder perks / PerkGrant system (SDS §10) — PerkAuthority (founder-key verification, fail-closed, founder № hard-capped 1–100), PerkRedeemer (code → grant verify → device-signed claim → first-create-wins pclaim record → publish to Identity.perks), RedeemPerkView (profile row + post-registration prompt), founder edition lines (drawer/profile/forge log, brass text, edition-not-tier), tools/mint_perks.py (keygen/mint/cktool output; tested end-to-end incl. Python↔Swift message-format cross-check). **Status: DORMANT by choice (6/12)** — `PerkAuthority.founderPublicKeyHex` is empty, so all perk UI (redeem row, post-registration prompt, badge lines) is hidden via `PerkAuthority.isConfigured` and verification fails closed. Schema (PerkGrant/PerkClaim/Identity.perks) IS deployed. To activate later: (1) `tools/mint_perks.py keygen`, paste pubkey hex into PerkAuthority line ~16; (2) mint codes, push grant records (verify cktool flags in push.sh); (3) test redemption in dev first. Nathan's first test "didn't work" — likely pubkey not pasted or grant record not in the right env; untriaged.
DONE 6/12 (later): account deletion (App Review 5.1.1(v)) — "Delete identity" in ProfileView: deletes the Identity record from the public directory (SyncEngine.deleteIdentity, idempotent), THEN runs the existing local wipe; network failure keeps local state for retry. Leftover Message/KeyEnvelope ciphertext is unreadable once keys are wiped (documented in code). Demo mode skips the network call. NOTE: sign-out after deletion was the existing onReset — friends' cached chats/forge-log entries on THEIR devices are untouched (their data, their signatures).
DONE 6/12 PM: demo mode (launch-arg), 1-key-1-identity excludedCredentials, group-invite push (ensureInviteSubscription), Face ID app lock (AppLock.swift — per-identity keychain flag, deviceOwnerAuthentication w/ passcode fallback, toggle in ProfileView, NSFaceIDUsageDescription added to pbxproj INFOPLIST_KEYs), screenshot disclosure (MessagePayload/ChatMessage `kind:"screenshot"` through normal E2EE pipeline; centered orange notice in ChatView; builds ≤4 render it as an empty bubble — harmless, family updates together), forge log share card (ForgeShareCard + ImageRenderer @3x, ShareLink in ForgeLogView toolbar).

## Known issues / gotchas
- PIN'd security keys: "wrong PIN" failures were from discoverable-credential creation (CTAP2 clientPIN over NFC); fixed by residentKey .discouraged. Root cause unconfirmed — wanted: USB-C test + Yubico Authenticator retry count.
- iOS caches failed AASA checks: delete+reinstall app if WebAuthn errors immediately (code 1001).
- TestFlight = Production CloudKit env; Xcode builds = Development. Separate worlds.
- Two-device E2EE receive path VALIDATED 2026-06-12 (TestFlight/Production, Nathan ↔ Karen): inbound text + encrypted photo decrypted, verified, and displayed. Test used TWO identities minted from ONE YubiKey 5Ci (pre-exclusion build) — that setup stops working once excludedCredentials ships; future tests need passkeys or a second key. Round 2 (6/12 evening): passkey↔passkey friending VALIDATED both directions via QR/nearby-device flow (mainstream onboarding works!); push-with-app-closed works (encrypted/static alerts); screenshot notices work both sides; Face ID lock works; TTL "i think it works". Photo-offline failed → fixed (media now outboxed under a pre-reserved record name, sender's own photos served from imageCache); offline polling noise → friendlier "Offline" notice that self-clears. Group-invite push: no banner on group creation — RETEST with recipient's app fully closed (foreground suppresses banners by design; both phones must have launched the build once so the subscription registers). 1-key-1-account exclusion still untested (needs queryable index deployed).
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
