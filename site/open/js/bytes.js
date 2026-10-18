// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  bytes.js
//
//  Small byte helpers shared by every module on the recipient page. No
//  dependencies: a browser and Node 22 both run this unchanged.

const enc = new TextEncoder();
const dec = new TextDecoder("utf-8", { fatal: true });

export const utf8 = (s) => enc.encode(s);
/** Strict UTF-8 decode; throws on bad bytes, like Swift's JSONDecoder. */
export const fromUtf8 = (b) => dec.decode(b);

export const toHex = (u) => Array.from(u, (b) => b.toString(16).padStart(2, "0")).join("");
export function fromHex(h) {
  if (typeof h !== "string" || h.length % 2 !== 0 || /[^0-9a-fA-F]/.test(h)) throw new Error("bad hex");
  return Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
}

/** Standard base64, padding required, as Foundation writes `Data` in JSON. */
export function fromB64(s) {
  if (typeof s !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(s) || s.length % 4 !== 0) throw new Error("bad base64");
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}
export function toB64(u) {
  let s = "";
  for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000));
  return btoa(s);
}
/** base64url without padding, as WebAuthn's clientDataJSON carries a challenge. */
export const toB64url = (u) => toB64(u).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export function fromB64url(s) {
  if (typeof s !== "string" || /[^A-Za-z0-9_-]/.test(s)) throw new Error("bad base64url");
  const b = s.replace(/-/g, "+").replace(/_/g, "/");
  return fromB64(b + "=".repeat((4 - (b.length % 4)) % 4));
}

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

export const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

/** UInt32 big-endian length, then the bytes: the framing every Seal digest uses. */
export function framed(domain, fields) {
  const parts = [utf8(domain)];
  for (const f of fields) {
    const len = new Uint8Array(4);
    new DataView(len.buffer).setUint32(0, f.length, false);
    parts.push(len, f);
  }
  return concat(...parts);
}

export const subtle = globalThis.crypto.subtle;
export const sha256 = async (d) => new Uint8Array(await subtle.digest("SHA-256", d));
export const sha384 = async (d) => new Uint8Array(await subtle.digest("SHA-384", d));

/** Swift's JSONEncoder writes Date as seconds since 2001-01-01. */
export const APPLE_EPOCH = 978307200;
export const appleDateToUnix = (n) => n + APPLE_EPOCH;
