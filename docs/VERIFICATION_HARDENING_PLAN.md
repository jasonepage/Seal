# Verification hardening — plan, not yet started

**Written:** 2026-08-25 · **Status:** 1–4 DONE 2026-08-25 (uncompiled). Item 5 deliberately NOT done — see why below. One follow-up action remains: flip `WebAuthnAssertion.enforceContextChecks` after reading the logs (item 2).
**Origin:** adversarial review of the FR-3 backup-key work (HANDOFF, 8/25). None of these four were introduced by FR-3; all four sit in or beside the paths it widened.

**Sequencing:** items 1 → 4 in order. All four before any TestFlight build carrying backup keys. Item 3 has a deadline of its own: it must land **before** custody receipts ship any records, because retrofitting a domain prefix after records exist forks verification.

---

## 1. `DeviceEndorsement.revokedAt` is an unsigned field that gates verification

**Where:** `Seal/Identity/IdentityManager.swift` — first condition of `verifiedDevices`, `guard e.revokedAt == nil`.

**What's wrong.** `revokedAt` is a plain `var Date?` inside the JSON blob the directory hands us. No signature covers it. It is the *first* thing verification checks.

**The attack.** Anyone who can write an `Identity` record sets `revokedAt` on every endorsement in it. Every device on that identity now fails verification on every peer — no root key, no revocation record, no signature required. The victim's messages are dropped everywhere, and the symptom ("signed by a device not among the sender's endorsed devices") is *identical to the 6/26 desync*, so it would likely be misdiagnosed as a regression rather than an attack.

**The fix.** Delete the condition. The only trustworthy revocation channel is `revokedDevicePublicKeys` — root-signed, domain-separated, already applied in `SyncEngine.fetchIdentity` before anything reaches `verifiedDevices`.

**Blast radius: none.** Verified by grep: the app never writes a non-nil `DeviceEndorsement.revokedAt`. Both construction sites (`CeremonyManager.swift:139`, `:326`) pass `nil`; the `.now` values at `:530` and `BackupKeyCeremony.swift:206` belong to `DeviceRevocation`, a different type. The field is dead weight that only an attacker can use. No wire change, no schema change, no compat window.

**Verify.** In dev CloudKit, hand-edit an Identity record's `deviceEndorsements` blob to set `revokedAt` on every entry; confirm messages from that identity still verify on a second phone. Then confirm a genuine root-signed revocation still kills the device.

**Effort:** one line plus the test.

---

## 2. `WebAuthnAssertion.verify` checks the signature and nothing else

**Where:** `Seal/Crypto/WebAuthnParsing.swift` — `WebAuthnAssertion.verify(with:)`.

**What's wrong.** It confirms that a DER ECDSA signature over `authenticatorData ‖ SHA256(clientDataJSON)` matches a public key. It does **not** check the RP ID hash (first 32 bytes of `authenticatorData`), the User Present / User Verified flags, or `clientData.type`. `clientDataChallengeMatches` reads only the `challenge` field.

**What that means.** "A Seal assertion" is currently just *a P-256 signature over a chosen message*. Two consequences: a directory-side forgery needs no authenticator at all (only a software keygen), and a signature the same key produced for **another relying party** — or in a `webauthn.create` rather than `webauthn.get` context — is accepted here if the bytes line up. This is table-stakes WebAuthn verification that the codebase skipped, and every ceremony in the app rests on it.

**The fix.** Inside `verify`, assert: `authenticatorData[0..<32] == SHA256("sealmessenger.com")`; the UP bit (`flags & 0x01`) is set; and `clientDataJSON["type"] == "webauthn.get"` (with the registration path checking `"webauthn.create"`). Log the specific failure, as `verify` already does for parse-vs-crypto.

**Blast radius: every ceremony, and historical records.** Endorsements, friendships and revocations already stored were all produced against our RP with UP set, so they *should* pass — but "should" is doing work there, and a wrong guess silently un-verifies real friendships. **Ship it in two steps:** build one where a violation is logged (`WebAuthnDiag`) but still accepted, run the family on it for a few days and read the logs; then a build that enforces. Do not enforce blind.

**Verify.** Both tiers, both directions: register, friend-forge, sign in, revoke, and re-verify an existing stored friendship on a device that has been running since before the change.

**Effort:** small change, deliberately slow rollout.

---

## 3. `signReceipt` is an unconstrained root-key signing oracle

**Where:** `Seal/Ceremony/CeremonyManager.swift` — `signReceipt(commitment:counterparty:)`.

**What's wrong.** It takes **raw `Data`** and asks the counterparty's **root** credential to sign it, with no check that the bytes are a domain-prefixed receipt commitment. Whatever the caller passes, the root key signs.

**The attack.** If any caller-influenced input reaches those bytes, a tap the victim believes is "confirming I received the keys" becomes a root signature over a `seal.backup.v1` or `seal.endorse.v2` commitment — a permanent identity takeover from a single, socially-plausible tap at a handover.

**Checked, then re-checked — and the second reading corrected the first.** The file's header comment writes the commitment in shorthand as `SHA256("seal.receipt.v1" | giver | receiver | ...)`, which reads as an unframed concatenation, and this plan initially said so. **The implementation does not do that.** `CustodyReceipt.commitment` length-frames every field with a `UInt32` big-endian prefix and adds a presence byte so "no photo" and "empty photo" cannot collide. It is the most careful commitment construction in the codebase, and item 4 below now follows its lead rather than the other way round. Lesson recorded rather than quietly fixed: a shorthand comment is not the code.

So the domain prefix is present and the framing is right; the takeover path was never open. What remained was structural — `signReceipt` accepted raw `Data`, so safety rested on every present and future caller behaving rather than on the type system.

**The fix.** Change the signature so `signReceipt` takes the structured receipt fields and builds `SHA256("seal.receipt.v1" ‖ …)` itself. No API that hands a root key arbitrary bytes should exist. Same rule as every other commitment in the app: the function that gets the signature owns the domain string.

**Timing.** Before receipts ship any records. After that, changing the commitment means a version bump and a verification fork across builds.

**Verify.** A handover ceremony end to end, plus a unit-style check that the commitment for fixed inputs is byte-stable.

**Effort:** small, if done before receipts land. Growing after.

---

## 4. `seal.endorse.v2` concatenates two variable-length values with no framing

**Where:** `Seal/Identity/IdentityManager.swift` and `Seal/Ceremony/CeremonyManager.swift` — `SHA256("seal.endorse.v2" ‖ devicePublicKey ‖ kemBundlePublicKeys)`.

**What's wrong.** Neither length is validated before hashing, so `(D, K)` and `(D‖K[0..<n], K[n...])` produce the same commitment. One root signature authorises many splits.

**The attack.** Re-split a **revoked** endorsement as `devicePublicKey = D‖K`, `kemBundlePublicKeys = ∅`. The commitment still matches the original root signature, so it verifies — but the revocation filter compares exact bytes, so it no longer matches, and the dead device reappears as live. It also shifts which bytes `HybridKEM.wrapToAll` treats as a KEM key.

**Severity: real, but not key compromise.** `devicePublicKey` is always the prefix and only a 65-byte prefix parses as x963, so exactly one usable signing key exists per commitment. Impact is revocation evasion and wrap-list poisoning.

**Worth noting:** `BackupCredential` explicitly refuses to depend on encoding coincidence, and asserts its 64-byte key length. `seal.endorse.v2` depends on exactly that coincidence.

**The fix.** `seal.endorse.v3` = `SHA256(domain ‖ UInt32BE(devicePublicKey.count) ‖ devicePublicKey ‖ kemBundlePublicKeys)`. **This is a versioned migration, not a patch:** verify v3 OR v2 during a transition window, publish only v3, then drop v2 once the family is known to be on the new build. Plan it deliberately — an endorsement that stops verifying is a phone that can't talk to anyone.

**Also adopt the rule going forward:** any new commitment either length-frames its variable-length parts or ends with a fixed-length one, and says which in a comment.

**Effort:** the change is small; the migration is the work.

---

## 5. NOT DONE, and here is why: capping the security-key allow-list

The problem is real: `fetchDirectoryCredentials` feeds every published credential ID into `allowedCredentials` at sign-in, CTAP2 authenticators enforce `maxCredentialCountInList` (commonly 8–32), and a flooded directory therefore breaks security-key sign-in for **everyone**, including identities with no backup keys.

**But the obvious fix makes it worse.** Capping the list means a legitimate user whose credential falls outside the cap simply cannot sign in — and under a flood, "outside the cap" is almost everyone. Trading a directory-flood DoS for a self-inflicted one is not a fix, and "order by likeliest candidate" is not implementable when the whole point is that we do not yet know who is tapping.

The real fix is a design change, not a patch: narrow the candidate set *before* building the allow-list — let the person type their name, or remember the last identity that signed in on this phone, and query for that. Left undone deliberately, with the reasoning recorded, rather than shipped as a cap that breaks the thing it protects. Pairs with the ~1k directory ceiling in SDS §7; do both together.
