// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  crypto.js
//
//  Opening what the owner sealed, with WebCrypto plus one vendored library
//  for ML-KEM-768. These are the functions tools/vectors/check.mjs tests
//  against the app's own Swift output (vectors set 1), moved here
//  unchanged in behavior. Ports of: EstateCrypto (aad, AES-GCM in
//  CryptoKit's combined form), HybridWrap.open, KEMBundle.parse,
//  SponsoredKey.unlock, EstateKeyHierarchy.openTableKeyAsRecipient,
//  openTable and openContent.

import { ml_kem768 } from "../vendor/noble-mlkem.js";
import { utf8, fromUtf8, fromHex, fromB64, concat, same, sha256, subtle } from "./bytes.js";

export async function hkdf(ikm, salt, info, length = 32) {
  const k = await subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, length * 8));
}

/** CryptoKit's combined form: 12 byte nonce, ciphertext, 16 byte tag. */
export async function aesOpen(key, combined, aad) {
  if (combined.length < 28) throw new Error("sealed box too short");
  const k = await subtle.importKey("raw", key, "AES-GCM", false, ["decrypt"]);
  const iv = combined.slice(0, 12);
  return new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv, additionalData: aad, tagLength: 128 }, k, combined.slice(12)));
}

/** EstateCrypto.aad. The epoch is kept as a decimal string so a UInt64 survives. */
export const estateAAD = (estateID, epoch, purpose) => utf8(`seal.estate.v1|${estateID}|${String(epoch)}|${purpose}`);

// X25519. WebCrypto will not import a raw private key, so it is wrapped in
// the fixed PKCS#8 header for X25519 (RFC 8410), which every browser takes.
const X25519_PKCS8 = fromHex("302e020100300506032b656e04220420");

async function x25519Private(raw) {
  return subtle.importKey("pkcs8", concat(X25519_PKCS8, raw), { name: "X25519" }, true, ["deriveBits"]);
}
async function x25519PublicOf(privateKey) {
  const jwk = await subtle.exportKey("jwk", privateKey);
  const b = jwk.x.replace(/-/g, "+").replace(/_/g, "/");
  return fromB64(b + "=".repeat((4 - (b.length % 4)) % 4));
}
async function x25519(privateKey, peerRaw) {
  const pub = await subtle.importKey("raw", peerRaw, { name: "X25519" }, false, []);
  return new Uint8Array(await subtle.deriveBits({ name: "X25519", public: pub }, privateKey, 256));
}

/** KEMBundle.parse */
const SKB1 = utf8("SKB1");
export function parseBundle(b) {
  if (b.length === 32) return { x25519: b, mlkem768: null };
  if (b.length === 4 + 32 + 1184 && same(b.slice(0, 4), SKB1)) return { x25519: b.slice(4, 36), mlkem768: b.slice(36) };
  return null;
}
export const encodeBundle = (x, ml) => (ml ? concat(SKB1, x, ml) : x);

/** A device's private KEM half, as the page holds it after unlocking. */
export async function loadPrivateBundle(x25519Raw, mlkemSeed) {
  const xPriv = await x25519Private(x25519Raw);
  const xPub = await x25519PublicOf(xPriv);
  const ml = mlkemSeed ? ml_kem768.keygen(mlkemSeed) : null;
  return { xPriv, xPub, mlSecret: ml?.secretKey ?? null, mlPublic: ml?.publicKey ?? null };
}

/** HybridWrap.open */
const HYBRID_INFO = utf8("seal.kem.hybrid.v1");
export async function hybridOpen(env, mine, aad) {
  const eph = fromB64(env.ephemeralPublicKey);
  const ss1 = await x25519(mine.xPriv, eph);
  let ss2 = new Uint8Array(0), ct = new Uint8Array(0), recipientML = new Uint8Array(0);
  if (env.suite === "x25519+mlkem768") {
    if (!mine.mlSecret || !env.mlkemCiphertext) throw new Error("hybrid envelope, no lattice key");
    ct = fromB64(env.mlkemCiphertext);
    ss2 = ml_kem768.decapsulate(ct, mine.mlSecret);
    recipientML = mine.mlPublic;
  } else if (env.suite !== "x25519") {
    throw new Error(`unknown suite ${env.suite}`);
  }
  // The salt names the bundle the sender wrapped to: a classical envelope
  // was wrapped to a bundle with no lattice key, even if this device has one.
  const salt = concat(eph, mine.xPub, await sha256(recipientML), await sha256(ct));
  const key = await hkdf(concat(ss1, ss2), salt, HYBRID_INFO);
  return aesOpen(key, fromB64(env.ciphertext), aad);
}
export async function hybridOpenAny(envs, mine, aad) {
  if (!Array.isArray(envs)) throw new Error("no copies");
  for (const env of envs) {
    try { return await hybridOpen(env, mine, aad); } catch { /* not this copy */ }
  }
  throw new Error("no copy opened");
}

/**
 * SponsoredKey.unlock: the PRF secret from the security key opens the
 * virtual device's private halves. Returns the KEM half and the public
 * bundle it makes, so the caller can check it against the endorsement.
 */
const SPONSORED_INFO = utf8("seal.sponsored.lock.v1");
const SPONSORED_AAD = utf8("seal.sponsored.v1");
export async function unlockSponsored(lockedPrivate, prfOutput, prfSalt) {
  const lockKey = await hkdf(prfOutput, prfSalt, SPONSORED_INFO);
  const plain = await aesOpen(lockKey, lockedPrivate, SPONSORED_AAD);
  const h = JSON.parse(fromUtf8(plain));
  if (typeof h.x25519 !== "string" || typeof h.signingKey !== "string") throw new Error("bad halves");
  const x = fromB64(h.x25519);
  const seed = h.mlkem768Seed ? fromB64(h.mlkem768Seed) : null;
  const kem = await loadPrivateBundle(x, seed);
  return { kem, kemBundle: encodeBundle(kem.xPub, kem.mlPublic) };
}

/**
 * EstateKeyHierarchy.openTableKeyAsRecipient, then openTable, returning the
 * table key and the table's plaintext bytes. Throws when it is not mine.
 */
export async function openTableRaw(wrap, estateID, estateKey, mine) {
  const epoch = wrap.epochText;   // kept as text by the caller, see parseTableWrap
  const inner = await hybridOpenAny(wrap.releaseWraps, mine, estateAAD(estateID, epoch, `tablekey.release.${wrap.tableID}`));
  const tableKey = await aesOpen(estateKey, inner, estateAAD(estateID, epoch, `tablekey.inner.${wrap.tableID}`));
  const plain = await aesOpen(tableKey, fromB64(wrap.ciphertext), estateAAD(estateID, 0, `table.${wrap.tableID}`));
  return { tableKey, plain };
}

/** The same, parsed. */
export async function openTableAsRecipient(wrap, estateID, estateKey, mine) {
  return JSON.parse(fromUtf8((await openTableRaw(wrap, estateID, estateKey, mine)).plain));
}

/**
 * A RecipientTableWrap from its JSON text. The epoch is a JSON number that
 * may in principle exceed 2^53, so it is read from the text itself and
 * kept as a decimal string (PRODUCT.md section 15, item 6).
 */
export function parseTableWrap(text) {
  const wrap = JSON.parse(text);
  const m = /"epoch"\s*:\s*(\d+)/.exec(text);
  if (!m || typeof wrap.tableID !== "string" || typeof wrap.ciphertext !== "string" || !Array.isArray(wrap.releaseWraps)) {
    throw new Error("not a key table");
  }
  wrap.epochText = m[1];
  return wrap;
}

export const openContent = (blob, contentKey, estateID, blobID) =>
  aesOpen(contentKey, blob, estateAAD(estateID, 0, `blob.${blobID}`));
