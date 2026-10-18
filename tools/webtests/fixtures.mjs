// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  fixtures.mjs
//
//  The WRITING side, for tests only: what the owner's phone, a key holder's
//  phone and a security key would produce, rebuilt in JavaScript so the
//  page's reading side can be exercised end to end in Node. Mirrors the
//  Swift (HybridWrap.wrap, EstateCrypto.seal, EstateEventBuilder,
//  IdentityManager.endorsementCommitment, a WebAuthn assertion). These are
//  not checked against Swift here; vectors and tools/vectors do that.

import { ml_kem768 } from "../../site/open/vendor/noble-mlkem.js";
import { utf8, concat, sha256, toB64, toB64url, framed, toHex, subtle, APPLE_EPOCH } from "../../site/open/js/bytes.js";
import { estateAAD, encodeBundle, hkdf } from "../../site/open/js/crypto.js";
import { eventDigest, releaseChallenge } from "../../site/open/js/estatelog.js";

export const random = (n) => crypto.getRandomValues(new Uint8Array(n));
export const b64 = toB64;

// ---------------------------------------------------------------- symmetric

/** CryptoKit AES.GCM combined form. */
export async function aesSeal(key, plain, aad) {
  const iv = random(12);
  const k = await subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad, tagLength: 128 }, k, plain));
  return concat(iv, ct);
}

// ---------------------------------------------------------------- KEM

const X25519_PKCS8 = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20]);

/** A device's KEM keys: raw X25519 private, ML-KEM seed, and the public bundle. */
export async function makeKem({ hybrid = true } = {}) {
  const x = random(32);
  const seed = hybrid ? random(64) : null;
  const priv = await subtle.importKey("pkcs8", concat(X25519_PKCS8, x), { name: "X25519" }, true, ["deriveBits"]);
  const jwk = await subtle.exportKey("jwk", priv);
  const xPub = Uint8Array.from(atob(jwk.x.replace(/-/g, "+").replace(/_/g, "/") + "="), (c) => c.charCodeAt(0));
  const ml = seed ? ml_kem768.keygen(seed) : null;
  return { x, seed, xPub, mlPublic: ml?.publicKey ?? null, bundle: encodeBundle(xPub, ml?.publicKey ?? null) };
}

/** HybridWrap.wrap to one public bundle. Returns the Envelope JSON object. */
export async function hybridWrap(secret, kem, aad) {
  const eph = await subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
  const ephPub = new Uint8Array(await subtle.exportKey("raw", eph.publicKey));
  const peer = await subtle.importKey("raw", kem.xPub, { name: "X25519" }, false, []);
  const ss1 = new Uint8Array(await subtle.deriveBits({ name: "X25519", public: peer }, eph.privateKey, 256));
  let ss2 = new Uint8Array(0), ct = new Uint8Array(0);
  if (kem.mlPublic) {
    const r = ml_kem768.encapsulate(kem.mlPublic);
    ss2 = r.sharedSecret; ct = r.cipherText;
  }
  const salt = concat(ephPub, kem.xPub, await sha256(kem.mlPublic ?? new Uint8Array(0)), await sha256(ct));
  const key = await hkdf(concat(ss1, ss2), salt, utf8("seal.kem.hybrid.v1"));
  return {
    suite: kem.mlPublic ? "x25519+mlkem768" : "x25519",
    ephemeralPublicKey: toB64(ephPub),
    mlkemCiphertext: kem.mlPublic ? toB64(ct) : null,
    ciphertext: toB64(await aesSeal(key, secret, aad)),
  };
}

// ---------------------------------------------------------------- ECDSA

/** Raw r ‖ s to DER, as CryptoKit and security keys write it. */
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

export async function p256Key() {
  const pair = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const x963 = new Uint8Array(await subtle.exportKey("raw", pair.publicKey));
  return { pair, x963, raw64: x963.slice(1) };
}
export async function signDER(key, message) {
  const raw = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.pair.privateKey, message));
  return rawToDer(raw);
}

// ---------------------------------------------------------------- WebAuthn

/** A security key's assertion over `challenge`, as a WebAuthnAssertion JSON object (base64 fields). */
export async function assertion(rootKey, credentialID, challenge, { rpId = "sealmessenger.com", flags = 0x01, type = "webauthn.get" } = {}) {
  const authData = concat(await sha256(utf8(rpId)), Uint8Array.of(flags), Uint8Array.of(0, 0, 0, 7));
  const clientData = utf8(JSON.stringify({ type, challenge: toB64url(challenge), origin: `https://${rpId}` }));
  const sig = await signDER(rootKey, concat(authData, await sha256(clientData)));
  return { credentialID: toB64(credentialID), clientDataJSON: toB64(clientData), authenticatorData: toB64(authData), signature: toB64(sig) };
}

const endorseV3 = (devicePub, kemBundle) => sha256(framed("seal.endorse.v3", [devicePub, kemBundle]));

/**
 * A person: a root credential (security key or passkey) plus devices.
 * `addDevice` returns the device's signing key and KEM keys; `record()`
 * returns the Identity record fields as CloudKit would serve them.
 */
export async function person(name, { tier = "verified" } = {}) {
  const credentialID = random(16);
  const hash = toHex(await sha256(credentialID));
  const root = await p256Key();
  const endorsements = [];
  const devices = [];
  return {
    name, hash, credentialID, root, devices, endorsements, tier,
    async addDevice({ sponsored = null } = {}) {
      const sign = await p256Key();
      const kem = await makeKem();
      const a = await assertion(root, credentialID, await endorseV3(sign.x963, kem.bundle));
      const e = {
        devicePublicKey: toB64(sign.x963),
        kemBundlePublicKeys: toB64(kem.bundle),
        assertion: toB64(utf8(JSON.stringify(a))),
        createdAt: Date.now() / 1000 - APPLE_EPOCH,
      };
      if (sponsored) { e.lockedPrivate = toB64(sponsored.locked); e.prfSalt = toB64(sponsored.salt); }
      endorsements.push(e);
      const device = { sign, kem };
      devices.push(device);
      return device;
    },
    fields(overrides = {}) {
      return {
        publicKey: { value: toB64(root.raw64), type: "BYTES" },
        tier: { value: overrides.tier ?? tier, type: "STRING" },
        displayName: { value: name, type: "STRING" },
        deviceEndorsements: { value: toB64(utf8(JSON.stringify(endorsements))), type: "BYTES" },
        credentialID: { value: toB64(credentialID), type: "BYTES" },
      };
    },
  };
}

/**
 * A sponsored key: the virtual device's private halves locked under the
 * key's PRF secret (SponsoredKey.lock). Returns what the directory holds
 * and the PRF output a browser would get back from the key.
 */
export async function sponsoredHalves() {
  const kem = await makeKem();
  const sign = await p256Key();
  const jwk = await subtle.exportKey("jwk", sign.pair.privateKey);
  const d = Uint8Array.from(atob(jwk.d.replace(/-/g, "+").replace(/_/g, "/") + "="), (c) => c.charCodeAt(0));
  const halves = { signingKey: toB64(d), x25519: toB64(kem.x), mlkem768Seed: toB64(kem.seed) };
  const prf = random(32);
  const salt = random(32);
  const lockKey = await hkdf(prf, salt, utf8("seal.sponsored.lock.v1"));
  const locked = await aesSeal(lockKey, utf8(JSON.stringify(halves)), utf8("seal.sponsored.v1"));
  return { kem, sign, prf, salt, locked };
}

// ---------------------------------------------------------------- events

let seq = 0;
/** EstateEventBuilder.make, with a software device key. Returns the EstateEvent JSON object. */
export async function makeEvent({ kind, estateID, actorHash, device, at, body = null, previousDigest = new Uint8Array(0) }) {
  const id = `00000000-0000-4000-8000-${String(++seq).padStart(12, "0")}`;
  const payload = body === null ? new Uint8Array(0) : utf8(JSON.stringify(body));
  const e = { id, estateID, kind, actorHash, actorDevicePublicKey: device.sign.x963, occurredAtEpoch: Math.floor(at), previousDigest, payload };
  const digest = await eventDigest(e);
  const signature = await signDER(device.sign, digest);
  return {
    id, estateID, kind, actorHash,
    actorDevicePublicKey: toB64(device.sign.x963),
    occurredAtEpoch: Math.floor(at),
    previousDigest: toB64(previousDigest),
    payload: toB64(payload),
    signature: toB64(signature),
  };
}

/** An AuthorizationBody: the key holder's root key taps over the release challenge. */
export async function tapBody(holder, estateID, epoch, claimID, recordHeadDigest = random(32)) {
  const challenge = await releaseChallenge(estateID, epoch, claimID, recordHeadDigest);
  return {
    claimID, epoch, recordHeadDigest: toB64(recordHeadDigest),
    assertion: await assertion(holder.root, holder.credentialID, challenge),
    shareForClaimant: [],
  };
}

export { estateAAD };
