# The Seal Capsule, format version 1

**Date:** 2026-09-15 · **Verifier:** `tools/verify_capsule.py` · **Builder:** `Seal/Estate/Capsule.swift`

This document is written for someone who has never seen Seal, has a capsule
file and a laptop, and needs to know what the file proves and how to check it.
If the company behind Seal no longer exists, this page and the verifier
script are meant to be enough.

## 1. What a capsule is

A capsule is one JSON file. It carries everything needed to check the signed
record of one person's sealed envelopes, and, once the envelopes have been
released, everything needed to open them with the recipient's own key:

- every public key involved: the owner, every custodian, every recipient who
  appears, and each of their endorsed device keys;
- the full signed record of events (heartbeats, claims, objections, key taps,
  the release), each event signed and linked to the one before it, with RFC
  3161 timestamp tokens where they were obtained;
- the epoch material: the Estate Key wrapped to the owner's devices, and each
  custodian's Shamir share wrapped to that custodian's devices, with
  commitments;
- the key tables, one per recipient, encrypted;
- optionally the encrypted envelopes themselves.

Nothing in a capsule is readable without private keys that live in people's
phones. A capsule can be posted on a public website without harm. That is the
point: it is the archive of record and it must survive being copied around.

## 2. Encoding conventions

- The file is UTF-8 JSON. Keys are sorted. Whitespace is not significant.
- `...Hex` fields are lowercase hexadecimal bytes.
- `...Base64` fields are standard base64 with padding.
- Inside `payloadBase64` and the blobs, byte fields appear as **base64
  strings** (that is how Swift's JSONEncoder writes `Data`). Where this
  document says a nested field is bytes, decode it from base64.
- `...Epoch` fields are whole seconds since 1970-01-01 UTC as integers.
- Hashes are SHA-256. Signatures are ECDSA over P-256 with SHA-256, in DER.
- Root public keys are the raw 64 byte `x ‖ y`. Device public keys are the 65
  byte X9.63 form `0x04 ‖ x ‖ y`.
- "Length framed" means: `domain string bytes`, then for each field a 4 byte
  big-endian length followed by the field bytes.

## 3. Top level

```
format            "seal.capsule"
version           1
relyingPartyID    "sealmessenger.com"
exportedAtEpoch   when the file was built, exporter's clock
exportedBy        root hash of the identity that built it
estateID          the estate
ownerHash         root hash of the owner
identities        map of root hash to Identity (section 4)
events            array of Event (section 5)
epochBlobsBase64  map of epoch number (as a string) to the epoch material blob
tableBlobsBase64  map of table id to the key table wrap blob
contentBlobsBase64 map of blob id to encrypted content (may be empty)
stateAtExport     the exporter's reading of the release state; informational
```

A **root hash** is `SHA256(credentialID)` of a WebAuthn credential, in hex.
It is the identity's name everywhere in Seal.

## 4. Identities and device endorsements

```
rootHash, publicKeyHex (64 bytes), displayName, tier
deviceEndorsements: [
  devicePublicKeyHex (65 bytes), kemBundleHex, createdAtEpoch,
  assertion: { credentialIDHex, clientDataJSONBase64, authenticatorDataHex, signatureHex }
]
```

A device endorsement is a WebAuthn **assertion** made by the identity's root
credential (a hardware security key or a passkey) whose challenge commits to
the device's signing key and its KEM bundle:

```
commitment = SHA256( framed("seal.endorse.v3", [devicePublicKey, kemBundle]) )
```

Older endorsements used `SHA256("seal.endorse.v2" ‖ devicePublicKey ‖ kemBundle)`
without framing and are accepted **only** when the device key is exactly 65
bytes and the bundle exactly 32 bytes.

Verifying an assertion means all of:

1. `authenticatorData[0..32] == SHA256(relyingPartyID)`;
2. `authenticatorData[32] & 0x01 != 0` (a human touched the authenticator);
3. `clientDataJSON` parses, its `type` is `"webauthn.get"`, and its
   `challenge` is the base64url (no padding) of the commitment;
4. the ECDSA signature verifies under the root public key over
   `authenticatorData ‖ SHA256(clientDataJSON)`.

A device key that passes is an **endorsed device** of that identity. Only
endorsed devices may sign events.

The `kemBundleHex` is either a 32 byte X25519 public key or `"SKB1"` ‖ X25519
(32) ‖ ML-KEM-768 public key (1184). It is not needed for verification; it is
what the wrapped shares were encrypted to.

## 5. Events

```
id, estateID, kind, actorHash, actorDevicePublicKeyHex, occurredAtEpoch,
previousDigestHex, payloadBase64, signatureHex, timestampTokenBase64 (or null),
digestHex
```

The digest of an event is:

```
digest = SHA256( framed("seal.estate.event.v1", [
    id, estateID, kind, actorHash,           (as UTF-8 bytes)
    actorDevicePublicKey,                    (65 bytes)
    decimal string of occurredAtEpoch,       (as UTF-8 bytes)
    previousDigest,                          (32 bytes, or empty)
    payload ]) )                             (raw payload bytes)
```

`signatureHex` is the actor's device key's ECDSA signature over `digest`.
`digestHex` is redundant and is recomputed by the verifier.

`previousDigest` is the digest of the newest event the writer had seen. The
record is therefore a hash linked graph, not one strict chain, because the
owner and several custodians write to it concurrently with no server to order
them. A verifier checks that every `previousDigest` names an event in the
capsule. What it cannot check is that no event was hidden by whoever assembled
the capsule; the timestamp tokens (section 8) are the defence against that
for the events that matter.

Kinds and who may write them:

| kind | actor | payload |
|---|---|---|
| `estateCreated` | owner | `{ policy, createdAtEpoch }` |
| `epochPublished` | owner | `{ epoch, threshold, custodianHashes[], custodianPublicKeys[] (base64, 64 bytes each), shareCommitments[] (base64), estateKeyCommitment (base64), materialDigest (base64) }` |
| `policyChanged` | owner | `{ policy }` |
| `vaultUpdated` | owner | `{ blobCommitment (base64), tableIDs[] }` |
| `heartbeat` | owner | empty |
| `cancellation` | owner | `{ claimID or null }` |
| `silenceObserved` | custodian | `{ lastHeartbeatDigest, lastHeartbeatAtEpoch }` |
| `releaseClaimed` | custodian | `{ claimID, epoch, lastHeartbeatAtEpoch, reason }` |
| `objection` | custodian | `{ claimID, withdrawn: false, note }` |
| `objectionWithdrawn` | custodian | `{ claimID, withdrawn: true, note }` |
| `authorization` | custodian | `{ claimID, epoch, recordHeadDigest, assertion, shareForClaimant[] }` |
| `released` | custodian | `{ claimID, epoch, shareIndexes[], estateKey (base64, 32 bytes) }` |

A "custodian" is any root hash listed in `custodianHashes` of an earlier
`epochPublished` event by the owner. An event by anyone else, or an owner
event of a custodian kind or the reverse, is invalid and must be ignored.

`policy` is `{ silenceDays, warningDays, graceDays, threshold, objectionBehavior }`
with `objectionBehavior` either `"pause"` or `"veto"`.

## 6. Epoch material

`epochBlobsBase64[epoch]` decodes to JSON:

```
estateID, epoch, threshold,
ownerWraps:      [ Envelope ]          the Estate Key, wrapped to owner devices
custodianShares: [ { custodianHash, shareIndex, envelopes: [ Envelope ], commitment } ]
estateKeyCommitment                    SHA256(Estate Key)
```

An `Envelope` is a hybrid public key encryption of some secret to one device:

```
suite               "x25519" or "x25519+mlkem768"
ephemeralPublicKey  32 bytes
mlkemCiphertext     1088 bytes, hybrid suite only
ciphertext          AES-256-GCM combined form: nonce (12) ‖ ciphertext ‖ tag (16)
```

The AES key is `HKDF-SHA256(ikm = ss1 ‖ ss2, salt = ephemeralPublicKey ‖
recipientX25519 ‖ SHA256(recipientMLKEM or empty) ‖ SHA256(mlkemCiphertext or
empty), info = "seal.kem.hybrid.v1", 32 bytes)` where `ss1` is the X25519
shared secret and `ss2` the ML-KEM-768 shared secret (empty for the classical
suite). The additional authenticated data is
`"seal.estate.v1|<estateID>|<epoch>|<purpose>"` with purpose
`estatekey.owner` for owner wraps and `share.<index>` for a share.

The checks a verifier makes, without any private key:

- `SHA256(blob bytes) == materialDigest` from the signed `epochPublished` event;
- the list of `commitment` values equals `shareCommitments` in that event, in
  order, and `custodianHash` order equals `custodianHashes`;
- `estateKeyCommitment` matches the event.

A **share** is `index (1 byte) ‖ 32 bytes`, and its commitment is
`SHA256(index ‖ bytes)`. Shares are Shamir secret sharing over GF(2^8) with
reducing polynomial 0x11B, threshold `threshold`, one polynomial per secret
byte, share `index` being the polynomial evaluated at `x = index`. Recovery is
Lagrange interpolation at `x = 0`. `tools/shamir_vectors.py` is a reference
implementation.

## 7. Key tables and content

`tableBlobsBase64[tableID]` decodes to JSON:

```
tableID, epoch, ownerWraps [Envelope], releaseWraps [Envelope], ciphertext
```

`ciphertext` is the recipient's key table under a random Key Table Key (AAD
purpose `table.<tableID>`, epoch 0). `ownerWraps` carry that key to the
owner's devices (purpose `tablekey.owner.<tableID>`, epoch 0).
`releaseWraps` carry `AES-GCM(EstateKey, tableKey)` (purpose
`tablekey.inner.<tableID>`, at `epoch`) wrapped to the recipient's devices
(purpose `tablekey.release.<tableID>`, at `epoch`). So the recipient needs
their own private key **and** the Estate Key, and the custodian who recovers
the Estate Key needs a private key they do not have. A table names its
recipient nowhere; recipients find theirs by trying to open each one.

A decrypted key table is `{ recipientHash, entries: [ { envelopeID,
contentKey, title, revealOrder, blobIDs[] } ] }`. Each blob in
`contentBlobsBase64` is AES-256-GCM under `contentKey` with AAD purpose
`blob.<blobID>` at epoch 0. The first blob id of an entry is the envelope's
payload JSON (`title, letter, secrets[], photos[], voiceNote, revealOrder,
writtenAtEpoch`, and since 2026-09-16 an optional `firstSteps[]`, each
`{ id, title, note, secretIndex }`, the owner's ordered "what to do first"
list, where `secretIndex` is an index into `secrets` or null); the rest are
photos and the voice note, whose SHA-256 the payload records. A reader that
does not know `firstSteps` ignores it; a payload without it has none. This
is additive and did not bump the version (section 11).

## 8. Timestamps

`timestampTokenBase64` is the complete RFC 3161 `TimeStampResp` from a
timestamp authority, byte for byte, obtained by sending only the event's
digest. A verifier checks:

1. the `PKIStatus` at the top is 0 (granted) or 1 (granted with mods);
2. the event digest appears in the token (inside `TSTInfo.messageImprint`);
3. `genTime` (the GeneralizedTime following the serial number after the
   digest) is read; it is the authority's clock and is preferred over
   `occurredAtEpoch` by the app;
4. with OpenSSL: `openssl ts -verify -digest <hex> -in token -CAfile <cert
   embedded in the token>` proves the token was signed by that certificate.
   Whether the certificate's issuer deserves trust is a decision for the
   reader; the app ships pointed at a free public authority and
   `docs/RECORD.md` section 13 says why that is not yet a defensible choice.

A token proves the event existed no later than `genTime`. It cannot prove
that something else did not happen. In particular, a heartbeat's token proves
the owner was alive at that moment; the absence of later heartbeats in a
capsule is only as good as the completeness of the capsule.

## 9. What the record proves, and what it does not

It proves that specific credentials, held in specific hands at ceremonies
witnessed in person, did specific things in a specific order, and that the
shares those custodians hold were the ones the owner issued. It proves that M
physical keys were tapped over a challenge naming this exact claim and record.
It proves the Estate Key published at release is the one the owner committed
to.

It does not prove who the legal persons are. It does not prove the owner is
dead. It does not prove the contents of an envelope are true. It cannot show
an event that was never written. And a release, once made, cannot be undone
by any later event, including a heartbeat.

## 10. Running the verifier

```
pip install cryptography
python3 tools/verify_capsule.py seal-capsule-XXXXXXXX-NNNN.json
```

One line per check, `ok` or `FAIL`, exit status 0 only if everything passed.
`--strict` also fails on tokens whose signature could not be checked.
`--combine <share hex> ...` recovers the Estate Key from raw shares for a
family whose phones are gone. `tools/make_test_capsule.py` builds a synthetic
capsule with real signatures so the verifier can be exercised without a phone;
`--tamper` flips one signature byte to show a failure.

## 11. Versioning

`version` is bumped for any change a v1 verifier could not read. Additive
fields do not bump it. A verifier must refuse a version it does not know.
