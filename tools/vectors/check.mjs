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
import { p256 } from "@noble/curves/nist.js";
// The page's own code, so passing here is passing there.
import { fromHex, toHex, fromB64, fromUtf8, sha256, same } from "../../site/open/js/bytes.js";
import {
  estateAAD, parseBundle, encodeBundle, loadPrivateBundle, hybridOpenAny,
  unlockSponsored, openTableRaw, parseTableWrap, openContent, hkdf, aesOpen,
} from "../../site/open/js/crypto.js";
import { ml_kem768 } from "../../site/open/vendor/noble-mlkem.js";

const utf8 = (s) => new TextEncoder().encode(s);

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
  // The lock key and the halves, computed here the long way to compare with Swift.
  const lockKey = await hkdf(fromHex(s.prfOutput), fromHex(s.prfSalt), utf8("seal.sponsored.lock.v1"));
  check(toHex(lockKey) === s.lockKey, "sponsored: lock key");
  const halves = JSON.parse(fromUtf8(await aesOpen(lockKey, fromHex(s.lockedPrivate), utf8("seal.sponsored.v1"))));
  check(toHex(fromB64(halves.signingKey)) === s.halves.signingKey && toHex(fromB64(halves.x25519)) === s.halves.x25519, "sponsored: halves");
  check(toHex(p256.getPublicKey(fromB64(halves.signingKey), false)) === s.devicePublicKeyX963, "sponsored: P-256 public key");
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
    // Parsed from the text, as the page does, so the epoch stays exact.
    const wrap = parseTableWrap(fromUtf8(fromB64(t.wrapBase64)));
    const r = await openTableRaw(wrap, e.estateID, fromHex(e.estateKey), u.kem)
      .then((x) => ({ ...x, table: JSON.parse(fromUtf8(x.plain)) })).catch(() => null);
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
