// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  worker/index.js
//
//  THE RELAY (PRODUCT.md section 15, 1.2b). sealmessenger.com is a
//  Cloudflare Worker serving the static site. This adds one route,
//  POST /relay/event, because a browser cannot write to CloudKit's public
//  database without an Apple account, and a key holder on Android has none.
//
//  What it does with an entry a key holder's browser signed:
//    1. checks it is a well formed record entry of a key holder's kind,
//       signed by a device the actor's own root key endorsed (the same
//       checks every phone makes; the phones still make them all again);
//    2. for a claim, a tap or a release, asks FreeTSA for a timestamp
//       token, the same authority the phones use, and attaches it only if
//       it verifies under the pinned certificate (the token sits outside
//       the signature, so it cannot change what was signed);
//    3. creates the record, never replaces one.
//
//  What it cannot do: forge or change an entry, because it holds no
//  key holder's key and every phone checks the signature. What it can do,
//  and the site says so: fail to deliver an entry, or, because CloudKit
//  lets a record's creator write it, delete one it delivered. It keeps
//  nothing and logs nothing about what passes through.
//
//  Everything else is the static site, unchanged.

import { CloudKitServer, importPrivateKey } from "./cloudkit-s2s.js";
import { parseEvent, signatureIsValid, custodianKinds } from "../site/open/js/estatelog.js";
import { verifiedDevices, parseAssertion, verifyAssertion, clientDataChallengeMatches, DELETED_TIER } from "../site/open/js/identity.js";
import { verifiedGenTime } from "../site/open/js/timestamp.js";
import { fetchIdentity, names } from "../site/open/js/estate.js";
import { utf8, toB64, fromB64, toHex, sha256, same, concat } from "../site/open/js/bytes.js";

const MAX_BODY = 256 * 1024;
const STAMPED = new Set(["releaseClaimed", "authorization", "released"]);

const reply = (status, body) => new Response(JSON.stringify(body), {
  status,
  headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
});
const refuse = (status, message) => reply(status, { ok: false, message });

// ---------------------------------------------------------------- RFC 3161

const der = (tag, body) => {
  const len = body.length;
  const head = len < 0x80 ? Uint8Array.of(tag, len) : len < 0x100 ? Uint8Array.of(tag, 0x81, len) : Uint8Array.of(tag, 0x82, len >> 8, len & 0xff);
  return concat(head, body);
};
const SHA256_OID = Uint8Array.of(0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01);

/** TimestampDER.request: version 1, SHA-256 imprint, a random nonce, certReq true. */
export function timestampRequest(digest) {
  const nonce = crypto.getRandomValues(new Uint8Array(8));
  nonce[7] |= 1;
  const n = nonce[0] & 0x80 ? concat(Uint8Array.of(0), nonce) : nonce;
  const imprint = der(0x30, concat(der(0x30, concat(SHA256_OID, Uint8Array.of(0x05, 0x00))), der(0x04, digest)));
  return der(0x30, concat(Uint8Array.of(0x02, 0x01, 0x01), imprint, der(0x02, n), Uint8Array.of(0x01, 0x01, 0xff)));
}

async function stamp(digest, fetchImpl) {
  try {
    const res = await fetchImpl("https://freetsa.org/tsr", {
      method: "POST",
      headers: { "Content-Type": "application/timestamp-query" },
      body: timestampRequest(digest),
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) return null;
    const token = new Uint8Array(await res.arrayBuffer());
    return (await verifiedGenTime(token, digest)) !== null ? token : null;
  } catch {
    return null;   // no token is fine: the phones date it by Apple's clock instead
  }
}

// ---------------------------------------------------------------- the relay

export async function relayEvent(request, env, { server, fetchImpl = fetch } = {}) {
  const allowed = env.ALLOWED_ORIGIN ?? "https://sealmessenger.com";
  if (request.headers.get("Origin") !== allowed) return refuse(403, "This only takes entries from sealmessenger.com.");
  const text = await request.text();
  if (text.length > MAX_BODY) return refuse(413, "That entry is too large.");
  let wire;
  try { wire = JSON.parse(text).event; } catch { return refuse(400, "That was not a record entry."); }
  if (!wire || typeof wire !== "object") return refuse(400, "That was not a record entry.");
  delete wire.timestampToken;   // only a token this relay fetched and checked is attached

  const event = await parseEvent(utf8(JSON.stringify(wire)));
  if (!event) return refuse(400, "That entry did not read correctly.");
  if (!custodianKinds.has(event.kind)) return refuse(400, "Only a key holder's entries go through here.");
  if (!event.body) return refuse(400, "That entry did not read correctly.");
  if (!(await signatureIsValid(event))) return refuse(400, "That entry's signature does not check out.");

  const ck = server ?? new CloudKitServer({
    container: env.CLOUDKIT_CONTAINER, environment: env.CLOUDKIT_ENVIRONMENT, keyID: env.CLOUDKIT_KEY_ID,
    privateKey: await importPrivateKey(env.CLOUDKIT_PRIVATE_KEY), fetchImpl,
  });
  // The signing device must be one the actor's own root key endorsed.
  // A lookup Apple refuses is said as such, never as "not endorsed".
  let actor;
  try {
    actor = await fetchIdentity(ck, event.actorHash);
  } catch (e) {
    return refuse(502, `Apple refused the relay's lookup (${String(e?.message ?? e).slice(0, 200)}). Nothing was saved.`);
  }
  if (!actor) return refuse(403, "This key holder's identity could not be found in Seal's directory.");
  const devices = await verifiedDevices(actor.root, actor.endorsements);
  if (!devices.some((d) => same(d.devicePublicKey, event.actorDevicePublicKey))) {
    return refuse(403, `That entry was not signed by a device this key holder's key endorsed (${devices.length} endorsed device(s) found).`);
  }

  if (STAMPED.has(event.kind)) {
    const token = await stamp(event.digest, fetchImpl);
    if (token) wire.timestampToken = toB64(token);
  }
  const recordName = names.event(event.estateID, event.id);
  try {
    const result = await ck.create("EstateEvent", recordName, {
      estate: { value: event.estateID, type: "STRING" },
      kind: { value: event.kind, type: "STRING" },
      actor: { value: event.actorHash, type: "STRING" },
      payload: { value: toB64(utf8(JSON.stringify(wire))), type: "BYTES" },
    });
    return reply(200, { ok: true, recordName, existed: !!result.exists, stamped: !!wire.timestampToken });
  } catch (e) {
    return refuse(502, `Apple's server did not save it (${String(e?.message ?? e).slice(0, 200)}). Nothing was saved.`);
  }
}

// ---------------------------------------------------------------- retire a key

/** TombstoneProof.challenge: SHA256("seal.identity.delete.v1" || nonce). */
export const retireChallenge = (nonce) => sha256(concat(utf8("seal.identity.delete.v1"), nonce));

/**
 * POST /relay/retire. The web version of the app's "An old key is in the
 * way? Retire it" (RetireKeyCeremony.swift), for a key whose identity was
 * made on a phone the person no longer has. Added 2026-10-20 after a
 * YubiKey holding an old identity ("Karen", made on another iPhone) kept
 * answering the page's sign-in instead of the identity just registered on
 * it, and the iPhone in hand could not retire it.
 *
 * What proves the right: one tap on the key over the delete challenge,
 * exactly the proof the phone stores (TombstoneProof). The relay checks it
 * against the root key published under that credential's hash before it
 * writes anything, and every phone checks it again when it reads the
 * marker, so the relay cannot retire anyone on its own: a marker without a
 * proof that verifies is ignored (TombstoneProof.markerCounts).
 *
 * What it writes: the same write-once "tomb.<hash>" Identity record the
 * phone writes, tier "deleted", the proof in "revocations". It cannot flip
 * the live record (only its creator can), and does not need to: the marker
 * is what every reader trusts.
 *
 * Refused: a key with no live identity under its own hash. That covers a
 * backup key, which has no record of its own, so the same trap the phone
 * refuses (retiring the backup's hash while the identity lives on) cannot
 * happen here.
 */
export async function relayRetire(request, env, { server, fetchImpl = fetch } = {}) {
  const allowed = env.ALLOWED_ORIGIN ?? "https://sealmessenger.com";
  if (request.headers.get("Origin") !== allowed) return refuse(403, "This only takes requests from sealmessenger.com.");
  const text = await request.text();
  if (text.length > 16 * 1024) return refuse(413, "That request is too large.");
  let wire;
  try { wire = JSON.parse(text).retire; } catch { return refuse(400, "That was not a retire request."); }
  const a = wire?.assertion;
  if (!wire || typeof wire.nonce !== "string" || !a || typeof a !== "object") return refuse(400, "That was not a retire request.");
  let nonce, assertion;
  try {
    nonce = fromB64(wire.nonce);
    const clean = { credentialID: a.credentialID, clientDataJSON: a.clientDataJSON, authenticatorData: a.authenticatorData, signature: a.signature };
    assertion = parseAssertion(utf8(JSON.stringify(clean)));
  } catch { return refuse(400, "That tap did not read correctly."); }
  if (!assertion || nonce.length < 16 || nonce.length > 64) return refuse(400, "That tap did not read correctly.");
  if (!clientDataChallengeMatches(assertion.clientDataJSON, await retireChallenge(nonce))) {
    return refuse(400, "That tap was not made for retiring a key.");
  }
  const hash = toHex(await sha256(assertion.credentialID));
  const tombName = `tomb.${hash}`;

  const ck = server ?? new CloudKitServer({
    container: env.CLOUDKIT_CONTAINER, environment: env.CLOUDKIT_ENVIRONMENT, keyID: env.CLOUDKIT_KEY_ID,
    privateKey: await importPrivateKey(env.CLOUDKIT_PRIVATE_KEY), fetchImpl,
  });
  let identity;
  try {
    if (await ck.record(tombName)) return reply(200, { ok: true, hash, existed: true });
    identity = await fetchIdentity(ck, hash);
  } catch (e) {
    return refuse(502, `Apple refused the relay's lookup (${String(e?.message ?? e).slice(0, 200)}). Nothing was changed.`);
  }
  if (!identity) {
    return refuse(404, "This key has no Seal identity of its own. If it is a backup key, the identity it backs up is deleted from that identity's own phone. Nothing was changed.");
  }
  if (!(await verifyAssertion(assertion, identity.root.publicKey))) {
    return refuse(403, "That tap does not match the identity published under this key. Nothing was changed.");
  }
  const proof = { nonce: toB64(nonce), assertion: {
    credentialID: toB64(assertion.credentialID), clientDataJSON: toB64(assertion.clientDataJSON),
    authenticatorData: toB64(assertion.authenticatorData), signature: toB64(assertion.signature),
  } };
  try {
    const result = await ck.create("Identity", tombName, {
      tier: { value: DELETED_TIER, type: "STRING" },
      revocations: { value: toB64(utf8(JSON.stringify(proof))), type: "BYTES" },
    });
    return reply(200, { ok: true, hash, existed: !!result.exists });
  } catch (e) {
    return refuse(502, `Apple's server did not save it (${String(e?.message ?? e).slice(0, 200)}). Nothing was changed.`);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/relay/event") {
      if (request.method !== "POST") return refuse(405, "POST only.");
      try {
        return await relayEvent(request, env);
      } catch (e) {
        return refuse(500, `The relay could not handle that (${String(e?.message ?? e).slice(0, 200)}). Nothing was saved.`);
      }
    }
    if (url.pathname === "/relay/retire") {
      if (request.method !== "POST") return refuse(405, "POST only.");
      try {
        return await relayRetire(request, env);
      } catch (e) {
        return refuse(500, `The relay could not handle that (${String(e?.message ?? e).slice(0, 200)}). Nothing was changed.`);
      }
    }
    return env.ASSETS.fetch(request);
  },
};
