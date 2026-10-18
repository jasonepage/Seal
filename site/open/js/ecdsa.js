// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  ecdsa.js
//
//  ECDSA verification with WebCrypto alone. CryptoKit and security keys
//  write signatures in DER; WebCrypto wants the two numbers side by side
//  (IEEE P1363), so this converts, strictly, and never guesses: a signature
//  that does not parse is simply not valid.

import { concat, subtle } from "./bytes.js";

/** DER `SEQUENCE { INTEGER r, INTEGER s }` to r ‖ s, each `size` bytes. Null if malformed. */
export function derToRaw(der, size) {
  if (!(der instanceof Uint8Array) || der.length < 8 || der[0] !== 0x30) return null;
  let at = 1;
  let seqLen = der[at++];
  if (seqLen & 0x80) {
    if (seqLen !== 0x81 || at >= der.length) return null;   // signatures are short
    seqLen = der[at++];
    if (seqLen < 0x80) return null;                          // not minimal
  }
  if (at + seqLen !== der.length) return null;
  const out = [];
  for (let i = 0; i < 2; i++) {
    if (der[at++] !== 0x02) return null;
    const len = der[at++];
    if (len === 0 || len > size + 1 || at + len > der.length) return null;
    let n = der.subarray(at, at + len);
    at += len;
    if (n[0] & 0x80) return null;                            // negative
    if (n.length > 1 && n[0] === 0 && !(n[1] & 0x80)) return null; // not minimal
    if (n[0] === 0 && n.length > 1) n = n.subarray(1);
    if (n.length > size) return null;
    const padded = new Uint8Array(size);
    padded.set(n, size - n.length);
    out.push(padded);
  }
  if (at !== der.length) return null;
  return concat(out[0], out[1]);
}

const CURVES = {
  "P-256": { size: 32, hash: "SHA-256" },
  "P-384": { size: 48, hash: "SHA-384" },
};

/** Uncompressed point bytes for WebCrypto: accepts x963 (04 ‖ x ‖ y) or raw (x ‖ y). */
function uncompressed(pub, size) {
  if (pub.length === 2 * size + 1 && pub[0] === 0x04) return pub;
  if (pub.length === 2 * size) return concat(Uint8Array.of(0x04), pub);
  return null;
}

/**
 * True when `derSignature` is a valid ECDSA signature by `publicKey` over
 * `message`, hashed with the curve's usual hash (SHA-256 for P-256, as
 * CryptoKit's `isValidSignature(_:for:)` does over Data).
 */
export async function verifyECDSA(curve, publicKey, derSignature, message, hash) {
  const c = CURVES[curve];
  if (!c) return false;
  const point = uncompressed(publicKey, c.size);
  const raw = derToRaw(derSignature, c.size);
  if (!point || !raw) return false;
  try {
    const key = await subtle.importKey("raw", point, { name: "ECDSA", namedCurve: curve }, false, ["verify"]);
    return await subtle.verify({ name: "ECDSA", hash: hash ?? c.hash }, key, raw, message);
  } catch {
    return false;
  }
}

export const verifyP256 = (publicKey, derSignature, message) => verifyECDSA("P-256", publicKey, derSignature, message);
