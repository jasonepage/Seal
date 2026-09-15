# Software Requirements Specification: Seal, sealed envelopes

**Version:** 1.0 · **Date:** 2026-09-15 · **Companion:** [SDS.md](SDS.md)

## 1. Purpose

Let one person seal letters and secrets for named people, hand physical keys
to trusted custodians, and have the envelopes open only after a long silence,
weeks of warnings and a threshold of physical key taps. Nobody, including the
vendor, can open one early.

## 2. Users

- **Owner**: writes, seals, and keeps the envelopes closed by opening the app.
- **Custodian**: holds a key; may claim, object, tap.
- **Recipient**: reads after release.
- Half of all users are over sixty. Bigger text mode and plain language are
  requirements, not options.

## 3. Functional requirements

Identity and people (carried forward from v0.1):

- FR-1 Register with a FIDO2 security key or a platform passkey.
- FR-2 Add a person only in person, by a ceremony in which they tap their key
  on the owner's phone. The proven root key is pinned.
- FR-3 Backup credentials, two-sided, root-revocable.
- FR-4 Publish the identity to the directory; verify every chain on read.

Envelopes:

- FR-30 Write an envelope for one recipient: title, letter, photos, one voice
  message, and secrets sealed exactly as written.
- FR-31 Secrets are shown again only after Face ID.
- FR-32 Set the reveal order among a recipient's envelopes.
- FR-33 Seal: encrypt everything on the phone, publish, and tell the
  custodians and recipients they have a part.
- FR-34 Editing an envelope un-seals it; sealing again republishes only what
  changed and never touches media that did not.

Custodians and the rule:

- FR-40 Make a person a custodian; remove one.
- FR-41 Record the key handover with the two-sided custody receipt.
- FR-42 Set silence (30, 90, 180, 365 days), warning days, grace days,
  threshold M of N, and objection behaviour (pause or veto).
- FR-43 Changing custodians or threshold rotates the epoch on the next seal.

The release:

- FR-50 The owner's phone writes a signed, timestamped heartbeat on every
  launch and foreground; it never needs the hardware key.
- FR-51 Custodian phones compute the state from the record and a clock; every
  transition in [RELEASE.md](RELEASE.md) section 3.
- FR-52 A claim can open only when the estate is overdue; every custodian is
  notified; the owner is warned daily for the warning period.
- FR-53 One heartbeat or cancellation from the owner stops any live claim.
- FR-54 A custodian may object; pause slides deadlines, veto kills the claim.
- FR-55 Authorising requires a physical key tap over a challenge bound to
  estate, epoch, claim and record head, and delivers that custodian's share
  to the claimant.
- FR-56 The claimant combines M shares, each checked against its commitment,
  and publishes the Estate Key.
- FR-57 A recipient opens only their own envelopes, in reveal order, and can
  copy a secret byte for byte with the pasteboard read back.

The record and the archive:

- FR-60 Every event is device signed, hash linked, and re-verifiable against
  the directory.
- FR-61 Heartbeats, claims, taps, cancellations and releases carry RFC 3161
  tokens obtained from the digest alone.
- FR-62 Any party can export a capsule; a standalone script verifies it.
- FR-63 The record screen shows every line with what Seal can honestly say
  about its time.

Testing:

- FR-70 A `Clock` protocol is injected everywhere; a simulated clock and a
  debug Time Travel screen run the whole machine in under two minutes.
- FR-71 The state machine, Shamir, the key hierarchy and the security fixes
  have executable tests that run at DEBUG launch.

## 4. Non-functional requirements

- NFR-1 No backend, no third party dependencies, CryptoKit only.
- NFR-2 No new cryptographic primitives beyond Shamir over GF(256).
- NFR-3 Metadata that leaks is written down, not hidden (PRODUCT.md section 8).
- NFR-4 Every screen readable at the largest Dynamic Type size with Bigger
  text on; every button at least 52 points.
- NFR-5 No em dashes anywhere in the repository.
- NFR-6 The relying party, bundle identifier, team and container never change.

## 5. Constraints

C1 FIDO2 keys sign only, so the root never encrypts. C2 The RP ID needs a
domain serving the app site association file. C3 CloudKit schema changes are
additive and deploy only by hand (CLOUDKIT_DEPLOY.md). C4 A recipient must be
a Seal identity with published KEM keys.
