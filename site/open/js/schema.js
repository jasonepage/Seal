// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  schema.js
//
//  Decoding JSON the way Swift's JSONDecoder does for Seal's types: a
//  required field that is missing or of the wrong type fails the whole
//  value, optional fields may be missing or null, unknown keys are
//  ignored. The phone treats a body that fails to decode as if it said
//  nothing (ReleaseFeed's `.other`), so the page must fail on exactly the
//  same inputs or the two would judge the same log differently.
//
//  Each decoder returns the value or throws. `tryDecode` turns a throw
//  into null, which is how the Swift call sites use `try?`.

import { fromB64, fromUtf8 } from "./bytes.js";

class DecodeError extends Error {}
const fail = (what) => { throw new DecodeError(what); };

export const str = (v) => (typeof v === "string" ? v : fail("string"));
export const bool = (v) => (typeof v === "boolean" ? v : fail("bool"));
/** Swift Int / Int64: a JSON number with no fractional part. */
export const int = (v) => (typeof v === "number" && Number.isSafeInteger(v) ? v : fail("int"));
/** UInt64 epochs. Real ones are small; one past 2^53 is refused rather than rounded. */
export const uint = (v) => (int(v) >= 0 ? v : fail("uint"));
export const uint8 = (v) => (int(v) >= 0 && v <= 255 ? v : fail("uint8"));
export const data = (v) => fromB64(str(v));
export const arr = (each) => (v) => (Array.isArray(v) ? v.map(each) : fail("array"));
export const opt = (each) => (v) => (v === undefined || v === null ? null : each(v));
export function obj(shape) {
  return (v) => {
    if (typeof v !== "object" || v === null || Array.isArray(v)) fail("object");
    const out = {};
    for (const [k, each] of Object.entries(shape)) out[k] = each(v[k]);
    return out;
  };
}
export const oneOf = (...allowed) => (v) => (allowed.includes(v) ? v : fail("enum"));

export function tryDecode(decoder, value) {
  try { return decoder(value); } catch (e) { if (e instanceof DecodeError || e instanceof SyntaxError || e instanceof TypeError || /base64|UTF|decod/i.test(String(e?.message))) return null; throw e; }
}
/** JSON bytes, strictly UTF-8, then the decoder. Null on any failure. */
export function decodeJSONBytes(decoder, bytes) {
  try { return decoder(JSON.parse(fromUtf8(bytes))); } catch { return null; }
}

// ---------------------------------------------------------------- Seal types

/** ReleasePolicy, with its hand-written decoder (custodyConfirmMonths optional). */
export const releasePolicy = obj({
  silenceDays: int,
  warningDays: int,
  graceDays: int,
  threshold: int,
  objectionBehavior: oneOf("pause", "veto"),
  custodyConfirmMonths: opt(int),
});

export const hybridEnvelope = obj({
  suite: str,
  ephemeralPublicKey: str,         // kept as base64 text: crypto.js decodes it
  mlkemCiphertext: opt(str),
  ciphertext: str,
});
/** Checks the base64 too, as Swift would, while keeping the text for crypto.js. */
export const hybridEnvelopeStrict = (v) => {
  const e = hybridEnvelope(v);
  data(e.ephemeralPublicKey); data(e.ciphertext);
  if (e.mlkemCiphertext !== null) data(e.mlkemCiphertext);
  return e;
};

export const webAuthnAssertion = obj({
  credentialID: data,
  clientDataJSON: data,
  authenticatorData: data,
  signature: data,
});

export const bodies = {
  estateCreated: obj({ policy: releasePolicy, createdAtEpoch: int }),
  epochPublished: obj({
    epoch: uint,
    threshold: int,
    custodianHashes: arr(str),
    custodianPublicKeys: arr(data),
    shareCommitments: arr(data),
    estateKeyCommitment: data,
    materialDigest: data,
  }),
  policyChanged: obj({ policy: releasePolicy }),
  vaultUpdated: obj({ blobCommitment: data, tableIDs: arr(str) }),
  releaseClaimed: obj({ claimID: str, epoch: uint, lastHeartbeatAtEpoch: opt(int), reason: str }),
  objection: obj({ claimID: str, withdrawn: bool, note: str }),
  objectionWithdrawn: obj({ claimID: str, withdrawn: bool, note: str }),
  authorization: obj({
    claimID: str,
    epoch: uint,
    recordHeadDigest: data,
    assertion: webAuthnAssertion,
    shareForClaimant: arr(hybridEnvelopeStrict),
  }),
  released: obj({ claimID: str, epoch: uint, shareIndexes: arr(uint8), estateKey: data }),
  ownerDeparted: obj({ keepEnvelopes: bool, departedAtEpoch: int }),
  // Read by nothing in the release judgment (ReleaseFeed ignores both);
  // decoded so the relay can check a key holder's entry is well formed.
  custodyConfirmed: obj({ epoch: uint, recordHeadDigest: data, assertion: webAuthnAssertion }),
  silenceObserved: obj({ lastHeartbeatDigest: opt(data), lastHeartbeatAtEpoch: opt(int) }),
  cancellation: obj({ claimID: opt(str) }),
};

export const eventKinds = [
  "estateCreated", "epochPublished", "policyChanged", "vaultUpdated", "heartbeat",
  "silenceObserved", "releaseClaimed", "objection", "objectionWithdrawn", "cancellation",
  "authorization", "released", "custodyConfirmed", "ownerDeparted",
];

/** EstateEvent. Throws when it would not decode on the phone. */
export const estateEvent = obj({
  id: str,
  estateID: str,
  kind: oneOf(...eventKinds),
  actorHash: str,
  actorDevicePublicKey: data,
  occurredAtEpoch: int,
  previousDigest: data,
  payload: data,
  signature: data,
  timestampToken: opt(data),
});

/** EstateInvite, inside the wrapped invite record. */
export const estateInvite = obj({ estateID: str, ownerHash: str, ownerName: str, role: oneOf("custodian", "recipient") });

/** KeyTable and its entries (EstateKeys.swift). */
export const keyTable = obj({
  recipientHash: str,
  entries: arr(obj({ envelopeID: str, contentKey: data, title: str, revealOrder: int, blobIDs: arr(str) })),
});

/** MediaItem (EstateModels.swift). */
export const mediaItem = obj({
  blobID: str,
  kind: oneOf("photo", "voice", "video", "file"),
  sha256: data,
  byteCount: int,
  localName: str,
  fileName: opt(str),
});

/** SealedCard (Cards/SealedCard.swift). */
export const sealedCard = obj({
  cardType: oneOf("cryptoAddress", "paymentInstructions", "statement", "password", "seedPhrase", "combination", "location"),
  title: str,
  value: str,
  asset: opt(str),
  note: opt(str),
  fallbackText: str,
});

/** FirstStep (Estate/FirstSteps.swift). */
export const firstStep = obj({ id: str, title: str, note: str, secretIndex: opt(int) });

/** Envelope.Payload with its hand-written decoder (EstateModels.swift). */
export const envelopePayload = obj({
  title: str,
  letter: str,
  secrets: arr(sealedCard),
  photos: arr(mediaItem),
  voiceNote: opt(mediaItem),
  revealOrder: int,
  writtenAtEpoch: int,
  firstSteps: opt(arr(firstStep)),
  videoNote: opt(mediaItem),
  openNoEarlierThanEpoch: opt(int),
  files: opt(arr(mediaItem)),
});
