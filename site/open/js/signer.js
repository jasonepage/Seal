// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  signer.js
//
//  Writing signed record entries from a browser (1.2b). Ports of
//  EstateEventBuilder.make and EstateLogStore.headDigest
//  (Seal/Estate/EstateLog.swift). The signing key is the sponsored
//  virtual device's P-256 half, unlocked into memory by the key's PRF
//  secret: an endorsed device of the key holder, exactly as a phone is.
//
//  The private key never leaves this tab. The relay only ever sees the
//  finished, signed entry.

import { utf8, toB64, toB64url, fromB64url, concat, subtle } from "./bytes.js";
import { eventDigest } from "./estatelog.js";

/** WebCrypto signing key from a raw 32 byte d and its x963 public point. */
export async function signingKeyFrom(d, devicePublicKeyX963) {
  if (d.length !== 32 || devicePublicKeyX963.length !== 65 || devicePublicKeyX963[0] !== 4) throw new Error("bad device key");
  const jwk = {
    kty: "EC", crv: "P-256", ext: false,
    d: toB64url(d),
    x: toB64url(devicePublicKeyX963.subarray(1, 33)),
    y: toB64url(devicePublicKeyX963.subarray(33, 65)),
  };
  const key = await subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  // Prove the pair matches before anything is signed with it.
  const probe = utf8("seal.web.keycheck");
  const pub = await subtle.importKey("raw", devicePublicKeyX963, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const sig = await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, probe);
  if (!(await subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, sig, probe))) throw new Error("the device key does not match its public half");
  return { key, devicePublicKey: devicePublicKeyX963 };
}

/** Raw r ‖ s to DER, as CryptoKit writes `derRepresentation`. */
export function rawToDer(raw) {
  const half = raw.length / 2;
  const int = (b) => {
    let i = 0;
    while (i < b.length - 1 && b[i] === 0) i++;
    let v = b.subarray(i);
    if (v[0] & 0x80) v = concat(Uint8Array.of(0), v);
    return concat(Uint8Array.of(0x02, v.length), v);
  };
  const body = concat(int(raw.subarray(0, half)), int(raw.subarray(half)));
  return concat(Uint8Array.of(0x30, body.length), body);
}

/** An uppercase UUID, as Swift's `UUID().uuidString` writes it. */
export const newID = () => crypto.randomUUID().toUpperCase();

/**
 * EstateLogStore.headDigest: the digest of the newest event by
 * (occurredAtEpoch, id), or empty. `events` are the admitted ones.
 */
export function headDigest(events) {
  let best = null;
  for (const e of events) {
    if (!best || e.occurredAtEpoch > best.occurredAtEpoch || (e.occurredAtEpoch === best.occurredAtEpoch && e.id > best.id)) best = e;
  }
  return best ? best.digest : new Uint8Array(0);
}

/**
 * EstateEvent.encodeBody: JSON with sorted keys. Bytes become base64,
 * nested objects are sorted too, null optionals are left out (Swift's
 * encodeIfPresent). Numbers must already be integers.
 */
export function encodeBody(value) {
  const norm = (v) => {
    if (v instanceof Uint8Array) return toB64(v);
    if (Array.isArray(v)) return v.map(norm);
    if (v && typeof v === "object") {
      const out = {};
      for (const k of Object.keys(v).sort()) if (v[k] !== null && v[k] !== undefined) out[k] = norm(v[k]);
      return out;
    }
    if (typeof v === "number" && !Number.isSafeInteger(v)) throw new Error("not an integer");
    return v;
  };
  return utf8(JSON.stringify(norm(value)));
}

/**
 * EstateEventBuilder.make. Returns { event, wire }: `event` in the page's
 * parsed shape (with digest), `wire` the EstateEvent JSON a phone decodes.
 */
export async function makeEvent({ kind, estateID, actorHash, signer, previousDigest, body, now }) {
  const id = newID();
  const payload = body === null || body === undefined ? new Uint8Array(0) : encodeBody(body);
  const occurredAtEpoch = Math.floor(now);
  const e = { id, estateID, kind, actorHash, actorDevicePublicKey: signer.devicePublicKey, occurredAtEpoch, previousDigest, payload };
  const digest = await eventDigest(e);
  const raw = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer.key, digest));
  const signature = rawToDer(raw);
  const wire = {
    id, estateID, kind, actorHash,
    actorDevicePublicKey: toB64(signer.devicePublicKey),
    occurredAtEpoch,
    previousDigest: toB64(previousDigest),
    payload: toB64(payload),
    signature: toB64(signature),
  };
  return { event: { ...e, signature, digest, occurredAt: occurredAtEpoch, timestampToken: null }, wire };
}

/**
 * A security key tap over `challenge`, as the WebAuthnAssertion JSON the
 * phones verify (CeremonyManager.signReleaseAuthorization).
 */
export async function tapKey(credentialID, challenge, rpId) {
  const cred = await navigator.credentials.get({
    publicKey: {
      rpId, challenge,
      allowCredentials: [{ type: "public-key", id: credentialID, transports: ["usb", "nfc"] }],
      userVerification: "preferred",
      timeout: 120_000,
    },
  });
  const r = cred.response;
  return {
    credentialID: new Uint8Array(cred.rawId),
    clientDataJSON: new Uint8Array(r.clientDataJSON),
    authenticatorData: new Uint8Array(r.authenticatorData),
    signature: new Uint8Array(r.signature),
  };
}

export { fromB64url };
