# Security-Key Interop Test Matrix

Goal: turn "the crypto is buggy everywhere, some keys work and some don't" into a
precise per-model failure table. The code now logs structured WebAuthn telemetry;
this sheet is where you record one controlled pass over all 7 keys.

## How to read the logs

All telemetry goes to the unified log:

- **Subsystem:** `io.github.jasonepage.Seal`
- **Category:** `webauthn`

On device, open **Console.app** on the Mac (with the iPhone attached), select the
phone, and filter on `subsystem:io.github.jasonepage.Seal category:webauthn`.
In Xcode, the same lines print to the console while running.

No secrets are logged, only algorithm IDs, curve, flag names, and byte lengths.

### What the lines mean

- `register: fmt=… ES256(P-256) P-256 flags=AT|UP|UV credIdLen=… xLen=32 yLen=32`
  a registration parsed. Watch for:
  - `alg(...)` other than `ES256(P-256)` → key ignored the ES256 pin (will now
    fail loud with "unsupportedAlgorithm" instead of a generic error).
  - `xLen`/`yLen` not 32 → the key emits non-standard coordinate padding. This
    is now auto-normalized, so it should still succeed, note it anyway.
  - `flags` missing `UV` on a PIN'd key → the key did not user-verify.
- `verify: OK (flags=…)`, an assertion verified against the directory key.
- `verify: signature did not parse as DER ECDSA (...)`, the key returned a
  signature shape CryptoKit can't read. Record sigLen.
- `verify: signature parsed but did NOT match ...`, signature is well-formed but
  doesn't match the published public key (key/identity mismatch, or the wrong
  credential answered).

## The matrix

Fill one row per physical key. Run all three ceremonies for each.

| # | Key model | Firmware | PIN set? | NFC/USB | Register: result | Register: alg / crv / xLen / yLen | Sign-in: result | Friend tap: result | verify line seen | Notes |
|---|-----------|----------|----------|---------|------------------|-----------------------------------|-----------------|--------------------|------------------|-------|
| 1 |           |          |          |         |                  |                                   |                 |                    |                  |       |
| 2 |           |          |          |         |                  |                                   |                 |                    |                  |       |
| 3 |           |          |          |         |                  |                                   |                 |                    |                  |       |
| 4 |           |          |          |         |                  |                                   |                 |                    |                  |       |
| 5 |           |          |          |         |                  |                                   |                 |                    |                  |       |
| 6 |           |          |          |         |                  |                                   |                 |                    |                  |       |
| 7 |           |          |          |         |                  |                                   |                 |                    |                  |       |

Result = ✅ works / ⚠️ works sometimes / ❌ fails. For ❌ and ⚠️, copy the exact
`webauthn` log line into Notes.

## What each failure pattern points to

- **Fails at register, `alg(...)` ≠ ES256** → key won't do ES256; decide whether
  to broaden `credentialParameters` (and the parser/verify) to EdDSA, or exclude
  the model. (Currently ES256-only by design.)
- **Register OK but xLen/yLen ≠ 32 and it now works** → the old `== 32` guard was
  the bug for that model; the normalization fix covers it. Confirm and move on.
- **`verify: signature did not parse`** → CTAP signature encoding quirk; capture
  sigLen and the model, this is a parser-level issue worth a focused fix.
- **`verify: ... did NOT match`** → not a crypto-format bug: wrong credential
  answered, or directory public key mismatch. Check the one-key-one-identity
  exclusion and the directory record.
- **Register/sign needs a PIN and fails over NFC** ("wrong PIN" though the PIN
  is right) → the CTAP clientPIN / UV path, not the parser. ROOT CAUSE (6/26):
  modern FIDO2.1 keys enable `always_uv` once a PIN is set and force UV no matter
  what the RP asks; requesting `.discouraged` conflicts with that and iOS drives
  the PIN path in a broken state. FIXED by `userVerificationPreference =
  .preferred` (CeremonyManager, all 4 security-key requests) so iOS and the key
  agree. If a PIN'd key STILL fails over NFC after this, suspect transport
  flakiness (multi-round-trip clientPIN over NFC), retest over USB-C to isolate.

## After the pass

You'll have a table that says, per model, exactly which stage breaks and which log
line fired. That collapses "buggy everywhere" into a short list of named issues, 
bring it back and we fix them one at a time.

## The sponsored key (added 2026-09-16)

`Seal/Ceremony/CeremonyManager+Sponsored.swift` registers a spare key AS
somebody else and asks the key for its PRF secret (CTAP `hmac-secret`). Two
more columns for the table, per model:

| Model | PRF at register (`checkForSupport`) | PRF at endorse (`inputValues`) | Sign-in on a second iPhone unlocks | Notes |
|---|---|---|---|---|
| YubiKey 5 NFC (5.4+) | | | | expected to work |
| YubiKey 5C NFC | | | | expected to work |
| Security Key NFC by Yubico | | | | may lack hmac-secret |
| Feitian / others | | | | unknown |

What each failure points to:

- **`prfUnsupported` on the first tap** → the key has no `hmac-secret`.
  Nothing was published. Use a different key.
- **`prfMissing` on the second tap** → iOS did not return a PRF output for
  a security key assertion. Check the PIN is set (some keys gate
  hmac-secret on UV), and that the build is iOS 26.4 or later.
- **`wrongKey` at sign-in on the second phone** → the key answered PRF
  differently than at registration (a reset key, or a different key with
  the same credential ID, which cannot happen). The identity is intact in
  the directory; the envelope is unreachable with this key.
