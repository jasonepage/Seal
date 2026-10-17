// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  tools/vectors/check.mjs
//
//  THE BROWSER'S HALF OF "MATCHES BYTE FOR BYTE" (PRODUCT.md section 15).
//
//  Opens everything in a vectors file written by the app's own Swift
//  (tools/export_vectors.sh), using only what a browser has: WebCrypto
//  (AES-GCM, HKDF, SHA-256, X25519) plus two small audited libraries for
//  what WebCrypto lacks (ML-KEM-768, and deriving a P-256 public key from a
//  raw private key). Every function in the "seal" section below is meant to
//  move into the web page unchanged, so passing here is passing there.
//
//      cd tools/vectors && npm install
//      node check.mjs ../../docs/vectors/web-set1.json

import { readFileSync } from "node:fs";
import { ml_kem768 } from "@noble/post-quantum/ml-kem.js";
import { p256 } from "@noble/curves/nist.js";

const subtle = globalThis.crypto.subtle;

// ---------------------------------------------------------------- bytes

const enc = new TextEncoder();
export const utf8 = (s) => enc.encode(s);
export const fromHex = (h) => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
export const toHex = (u) => Array.from(u, (b) => b.toString(16).padStart(2, "0")).join("");
export const fromB64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
export const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

// ---------------------------------------------------------------- seal

export const sha256 = async (d) => new Uint8Array(await subtle.digest("SHA-256", d));

export async function hkdf(ikm, salt, info, length = 32) {
  const k = await subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, length * 8));
}

/** CryptoKit's combined form: 12 byte nonce, ciphertext, 16 byte tag. */
export async function aesOpen(key, combined, aad) {
  const k = await subtle.importKey("raw", key, "AES-GCM", false, ["decrypt"]);
  const iv = combined.slice(0, 12);
  return new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv, additionalData: aad, tagLength: 128 }, k, combined.slice(12)));
}

/** EstateCrypto.aad. Epoch is passed as a decimal string so a UInt64 survives. */
export const estateAAD = (estateID, epoch, purpose) => utf8(`seal.estate.v1|${estateID}|${String(epoch)}|${purpose}`);

// X25519. WebCrypto will not import a raw private key, so it is wrapped in
// the fixed PKCS#8 header for X25519 (RFC 8410), which every browser takes.
const X25519_PKCS8 = fromHex("302e020100300506032b656e04220420");

export async function x25519Private(raw) {
  return subtle.importKey("pkcs8", concat(X25519_PKCS8, raw), { name: "X25519" }, true, ["deriveBits"]);
}
export async function x25519PublicOf(privateKey) {
  const jwk = await subtle.exportKey("jwk", privateKey);
  return fromB64(jwk.x.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (jwk.x.length % 4)) % 4));
}
export async function x25519(privateKey, peerRaw) {
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
  for (const env of envs) {
    try { return await hybridOpen(env, mine, aad); } catch { /* not this copy */ }
  }
  throw new Error("no copy opened");
}

/** SponsoredKey.unlock, then the public parts its endorsement commits to. */
const SPONSORED_INFO = utf8("seal.sponsored.lock.v1");
const SPONSORED_AAD = utf8("seal.sponsored.v1");
export async function unlockSponsored(lockedPrivate, prfOutput, prfSalt) {
  const lockKey = await hkdf(prfOutput, prfSalt, SPONSORED_INFO);
  const plain = await aesOpen(lockKey, lockedPrivate, SPONSORED_AAD);
  const h = JSON.parse(new TextDecoder().decode(plain));
  const halves = {
    signingKey: fromB64(h.signingKey),
    x25519: fromB64(h.x25519),
    mlkem768Seed: h.mlkem768Seed ? fromB64(h.mlkem768Seed) : null,
  };
  const kem = await loadPrivateBundle(halves.x25519, halves.mlkem768Seed);
  return {
    halves, kem, lockKey,
    devicePublicKeyX963: p256.getPublicKey(halves.signingKey, false),
    kemBundle: encodeBundle(kem.xPub, kem.mlPublic),
  };
}

/** Shamir.combine over GF(2^8), polynomial 0x11B. */
function gfMul(a, b) {
  let r = 0;
  while (b) { if (b & 1) r ^= a; a <<= 1; if (a & 0x100) a ^= 0x11b; b >>= 1; }
  return r & 0xff;
}
function gfInv(a) {
  let r = 1, base = a, e = 254;
  while (e) { if (e & 1) r = gfMul(r, base); base = gfMul(base, base); e >>= 1; }
  return r;
}
export function shamirCombine(encodedShares, threshold) {
  const used = encodedShares.slice(0, threshold).map((s) => ({ x: s[0], y: s.slice(1) }));
  if (used.length < threshold) throw new Error("not enough shares");
  const xs = new Set(used.map((s) => s.x));
  if (xs.size !== used.length || xs.has(0)) throw new Error("bad share index");
  const basis = used.map((si, i) => {
    let num = 1, den = 1;
    used.forEach((sk, k) => { if (k !== i) { num = gfMul(num, sk.x); den = gfMul(den, si.x ^ sk.x); } });
    return gfMul(num, gfInv(den));
  });
  const out = new Uint8Array(used[0].y.length);
  for (let j = 0; j < out.length; j++) used.forEach((s, i) => { out[j] ^= gfMul(s.y[j], basis[i]); });
  return out;
}

/** EstateKeyHierarchy.openTableKeyAsRecipient, then openTable. */
export async function openTableAsRecipient(wrap, estateID, estateKey, mine) {
  const inner = await hybridOpenAny(wrap.releaseWraps, mine, estateAAD(estateID, wrap.epoch, `tablekey.release.${wrap.tableID}`));
  const tableKey = await aesOpen(estateKey, inner, estateAAD(estateID, wrap.epoch, `tablekey.inner.${wrap.tableID}`));
  const plain = await aesOpen(tableKey, fromB64(wrap.ciphertext), estateAAD(estateID, 0, `table.${wrap.tableID}`));
  return { tableKey, plain, table: JSON.parse(new TextDecoder().decode(plain)) };
}

export const openContent = (blob, contentKey, estateID, blobID) =>
  aesOpen(contentKey, blob, estateAAD(estateID, 0, `blob.${blobID}`));

// ---------------------------------------------------------------- the checks

let checks = 0;
const failures = [];
function check(ok, name) { checks++; if (!ok) failures.push(name); }
async function mustThrow(fn, name) {
  checks++;
  try { await fn(); failures.push(name); } catch { /* good */ }
}
const parseStored = (b64) => JSON.parse(new TextDecoder().decode(fromB64(b64)));

async function run(v) {
  // 1. AAD strings
  for (const c of v.aad) check(toHex(estateAAD(c.estateID, c.epoch, c.purpose)) === c.bytes, `aad ${c.purpose}`);

  // 2. ML-KEM-768 alone
  if (v.mlkem768) {
    const m = v.mlkem768;
    check(m.seedLength === 64, `ML-KEM seed is 64 bytes (got ${m.seedLength})`);
    const kp = ml_kem768.keygen(fromHex(m.seed));
    check(toHex(kp.publicKey) === m.publicKey, "ML-KEM public key from the seed");
    check(toHex(ml_kem768.decapsulate(fromHex(m.ciphertext), kp.secretKey)) === m.sharedSecret, "ML-KEM shared secret");
  }

  // 3. bundle encoding
  const hb = parseBundle(fromHex(v.kemBundle.hybrid.encoded));
  check(hb && toHex(hb.x25519) === v.kemBundle.hybrid.x25519 && toHex(hb.mlkem768) === v.kemBundle.hybrid.mlkem768, "hybrid bundle parses");
  const cb = parseBundle(fromHex(v.kemBundle.classical.encoded));
  check(cb && cb.mlkem768 === null, "classical bundle parses");
  check(parseBundle(new Uint8Array(33)) === null, "a 33 byte bundle is skipped");

  // 4. hybrid wrap, both suites
  for (const w of v.hybridWrap) {
    const mine = await loadPrivateBundle(fromHex(w.mine.x25519), w.mine.mlkem768Seed ? fromHex(w.mine.mlkem768Seed) : null);
    check(toHex(encodeBundle(mine.xPub, mine.mlPublic)) === w.mine.publicBundle, `${w.suite}: public bundle from the private half`);
    const envs = parseStored(w.envelopesBase64);
    const secret = await hybridOpenAny(envs, mine, fromHex(w.aad)).catch(() => null);
    check(secret && toHex(secret) === w.secret, `${w.suite}: opens`);
    await mustThrow(() => hybridOpenAny(envs, mine, fromHex(w.mustFailWithAad)), `${w.suite}: wrong aad must not open`);
  }

  // 5. sponsored key
  const s = v.sponsored;
  const u = await unlockSponsored(fromHex(s.lockedPrivate), fromHex(s.prfOutput), fromHex(s.prfSalt));
  check(toHex(u.lockKey) === s.lockKey, "sponsored: lock key");
  check(toHex(u.halves.signingKey) === s.halves.signingKey && toHex(u.halves.x25519) === s.halves.x25519, "sponsored: halves");
  check(toHex(u.devicePublicKeyX963) === s.devicePublicKeyX963, "sponsored: P-256 public key");
  check(toHex(u.kemBundle) === s.kemBundle, "sponsored: KEM bundle");
  const wrongPrf = fromHex(s.prfOutput); wrongPrf[0] ^= 1;
  await mustThrow(() => unlockSponsored(fromHex(s.lockedPrivate), wrongPrf, fromHex(s.prfSalt)), "sponsored: a wrong secret must not open");

  // 6. the estate
  const e = v.estate;
  const material = parseStored(e.epochKeyMaterialBase64);
  const opened = [];
  for (const c of e.custodians) {
    const slot = material.custodianShares.find((x) => x.custodianHash === c.custodianHash);
    const mine = await loadPrivateBundle(fromHex(c.mine.x25519), fromHex(c.mine.mlkem768Seed));
    const share = await hybridOpenAny(slot.envelopes, mine, estateAAD(e.estateID, material.epoch, `share.${slot.shareIndex}`));
    check(toHex(share) === c.shareEncoded, `${c.custodianHash}: opens their share`);
    check(share[0] === slot.shareIndex && same(await sha256(share), fromB64(slot.commitment)), `${c.custodianHash}: share matches its commitment`);
    opened.push(share);
  }
  const key = shamirCombine(e.recoverWith.map((i) => opened[i]), material.threshold);
  check(toHex(key) === e.estateKey, "two shares rebuild the Estate Key");
  check(same(await sha256(key), fromB64(material.estateKeyCommitment)), "the rebuilt key matches the owner's commitment");

  let mineCount = 0;
  for (const t of e.tables) {
    const wrap = parseStored(t.wrapBase64);
    const r = await openTableAsRecipient(wrap, e.estateID, fromHex(e.estateKey), u.kem).catch(() => null);
    if (!t.isMine) { check(r === null, "someone else's table does not open"); continue; }
    mineCount++;
    check(r && toHex(r.tableKey) === t.tableKey, "my table key");
    check(r && same(r.plain, fromB64(t.tablePlainBase64)), "my table, byte for byte");
    const entry = r?.table.entries[0];
    const pt = entry && await openContent(fromHex(e.content.blob), fromB64(entry.contentKey), e.estateID, e.content.blobID).catch(() => null);
    check(pt && toHex(pt) === e.content.plaintext, "the envelope content opens with the key from my table");
  }
  check(mineCount === 1, "exactly one table is mine");
}

const file = process.argv[2];
if (!file) { console.error("usage: node check.mjs <vectors.json>"); process.exit(2); }
await run(JSON.parse(readFileSync(file, "utf8"))).catch((err) => failures.push(`crashed: ${err.stack ?? err}`));
for (const f of failures) console.log(`FAIL ${f}`);
console.log(`${checks} checks, ${failures.length} failures`);
process.exit(failures.length ? 1 : 0);
