// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  estatelog.js
//
//  The signed estate record, as the page reads it. Ports of EstateEvent
//  (digest, signature check, body decoding), ReleaseChallenge (the tap a
//  key holder's security key signs) and EstateLogVerifier.admitted (which
//  events to believe). Swift: Seal/Estate/EstateLog.swift.

import { utf8, framed, sha256, same } from "./bytes.js";
import { verifyP256 } from "./ecdsa.js";
import { bodies, estateEvent, decodeJSONBytes, tryDecode } from "./schema.js";
import { verifiedDevices, verifyAssertion, clientDataChallengeMatches } from "./identity.js";

const DOMAIN = "seal.estate.event.v1";

/** EstateEvent.digest: domain, then each field length-framed. */
export async function eventDigest(e) {
  return sha256(framed(DOMAIN, [
    utf8(e.id), utf8(e.estateID), utf8(e.kind), utf8(e.actorHash),
    e.actorDevicePublicKey, utf8(String(e.occurredAtEpoch)), e.previousDigest, e.payload,
  ]));
}

/**
 * An EstateEvent from its CloudKit payload bytes, or null if the phone
 * would not decode it either. Adds `digest`, `body` (the decoded payload,
 * or null for a kind with no body or a payload that does not decode, the
 * phone's `.other`) and `occurredAt` (seconds).
 */
export async function parseEvent(payloadBytes) {
  const e = decodeJSONBytes(estateEvent, payloadBytes);
  if (!e) return null;
  e.digest = await eventDigest(e);
  e.occurredAt = e.occurredAtEpoch;
  const decoder = bodies[e.kind];
  e.body = decoder ? decodeJSONBytes(decoder, e.payload) : null;
  return e;
}

/** EstateEvent.signatureIsValid: DER ECDSA by the device key over the digest. */
export const signatureIsValid = (e) => verifyP256(e.actorDevicePublicKey, e.signature, e.digest);

/** ReleaseChallenge.challenge */
export const releaseChallenge = (estateID, epoch, claimID, recordHeadDigest) =>
  sha256(framed("seal.release.authorize.v1", [utf8(estateID), utf8(String(epoch)), utf8(claimID), recordHeadDigest]));

/** ReleaseChallenge.tapVerifies: the key holder's ROOT key signed this exact claim. */
export async function tapVerifies(body, estateID, rootPublicKey) {
  if (!body) return false;
  const expected = await releaseChallenge(estateID, body.epoch, body.claimID, body.recordHeadDigest);
  return (await verifyAssertion(body.assertion, rootPublicKey))
    && clientDataChallengeMatches(body.assertion.clientDataJSON, expected);
}

export const ownerKinds = new Set(["estateCreated", "epochPublished", "policyChanged", "vaultUpdated", "heartbeat", "cancellation", "ownerDeparted"]);
export const custodianKinds = new Set(["silenceObserved", "releaseClaimed", "objection", "objectionWithdrawn", "authorization", "released", "custodyConfirmed"]);

/**
 * EstateLogVerifier.admitted. `directory` maps a root hash to
 * { root, endorsements }, already fetched and, for key holders, checked
 * against the keys the owner's epoch statement names (the phone's pins).
 */
export async function admitted(events, ownerHash, custodianHashes, directory) {
  const trustedCache = new Map();
  const trustedOf = async (hash) => {
    if (!trustedCache.has(hash)) {
      const entry = directory.get(hash);
      trustedCache.set(hash, entry ? await verifiedDevices(entry.root, entry.endorsements) : null);
    }
    return trustedCache.get(hash);
  };
  const out = [];
  for (const e of events) {
    if (!(await signatureIsValid(e))) continue;
    if (e.actorHash === ownerHash) {
      if (!ownerKinds.has(e.kind)) continue;
    } else if (custodianHashes.has(e.actorHash)) {
      if (!custodianKinds.has(e.kind)) continue;
    } else {
      continue;
    }
    const entry = directory.get(e.actorHash);
    if (!entry) continue;
    const trusted = await trustedOf(e.actorHash);
    if (!trusted || !trusted.some((d) => same(d.devicePublicKey, e.actorDevicePublicKey))) continue;
    if (e.kind === "authorization") {
      if (!(await tapVerifies(e.body, e.estateID, entry.root.publicKey))) continue;
    }
    out.push(e);
  }
  return out;
}

/** Sort by (occurredAtEpoch, id), the order the phone keeps its log in. */
export const byLogOrder = (a, b) =>
  a.occurredAtEpoch !== b.occurredAtEpoch ? a.occurredAtEpoch - b.occurredAtEpoch : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

/** The newest by (occurredAtEpoch, id), as Swift's `max(by:)` picks it (first of equals). */
export function newest(events) {
  let best = null;
  for (const e of events) if (best === null || byLogOrder(best, e) < 0) best = e;
  return best;
}

export { tryDecode };
