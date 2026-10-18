// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  cloudkit-s2s.js
//
//  CloudKit Web Services with a server-to-server key: the relay's only way
//  to write. Every request is signed with ECDSA P-256 over
//  "<ISO 8601 date>:<base64 SHA-256 of the body>:<path>", DER encoded, in
//  the X-Apple-CloudKit-Request-SignatureV1 header (Apple's CloudKit Web
//  Services reference, "Accessing CloudKit Using a Server-to-Server Key").
//
//  The private key is a Cloudflare secret, CLOUDKIT_PRIVATE_KEY, as made
//  by `openssl ecparam -name prime256v1 -genkey -noout`: a SEC1 "EC
//  PRIVATE KEY" PEM, which carries the public point too.

import { fromB64, toB64, sha256, subtle } from "../site/open/js/bytes.js";
import { rawToDer } from "../site/open/js/signer.js";

const HOST = "https://api.apple-cloudkit.com";

/** DER TLV reader, just enough for a SEC1 EC private key. */
function readTLV(b, at) {
  const tag = b[at];
  let len = b[at + 1], off = at + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n < 1 || n > 2) throw new Error("bad DER length");
    len = 0;
    for (let i = 0; i < n; i++) len = (len << 8) | b[off + i];
    off += n;
  }
  if (off + len > b.length) throw new Error("DER runs past its end");
  return { tag, start: off, end: off + len };
}

const b64url = (u) => toB64(u).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** A WebCrypto signing key from the PEM in the secret. SEC1 or PKCS#8. */
export async function importPrivateKey(pem) {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = fromB64(body + "=".repeat((4 - (body.length % 4)) % 4));
  if (/BEGIN PRIVATE KEY/.test(pem)) {
    return subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  }
  // SEC1: SEQUENCE { INTEGER 1, OCTET STRING d, [0] OID, [1] BIT STRING point }
  const seq = readTLV(der, 0);
  if (seq.tag !== 0x30) throw new Error("not an EC private key");
  let at = seq.start;
  const version = readTLV(der, at); at = version.end;
  const dTLV = readTLV(der, at); at = dTLV.end;
  if (dTLV.tag !== 0x04) throw new Error("no private scalar");
  let point = null;
  while (at < seq.end) {
    const t = readTLV(der, at);
    if (t.tag === 0xa1) {
      const bit = readTLV(der, t.start);
      if (bit.tag === 0x03) point = der.subarray(bit.start + 1, bit.end);   // skip the unused-bits byte
    }
    at = t.end;
  }
  if (!point || point.length !== 65 || point[0] !== 4) throw new Error("the key has no public point; make it with openssl ecparam -genkey");
  let d = der.subarray(dTLV.start, dTLV.end);
  if (d.length > 32) d = d.subarray(d.length - 32);
  const jwk = { kty: "EC", crv: "P-256", ext: false, d: b64url(d), x: b64url(point.subarray(1, 33)), y: b64url(point.subarray(33)) };
  return subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

export class CloudKitServer {
  constructor({ container, environment, keyID, privateKey, fetchImpl = fetch, now = () => new Date() }) {
    this.path = `/database/1/${container}/${environment}/public`;
    this.keyID = keyID;
    this.key = privateKey;
    // Wrapped, not stored as is: Cloudflare refuses a `fetch` called as
    // someone else's method ("Illegal invocation").
    this.fetch = (...args) => fetchImpl(...args);
    this.now = now;
  }

  /** Signs and sends one request. Returns the parsed JSON, or throws with Apple's reason. */
  async post(subpath, payload) {
    const body = JSON.stringify(payload);
    const date = this.now().toISOString().replace(/\.\d{3}Z$/, "Z");
    const bodyHash = toB64(await sha256(new TextEncoder().encode(body)));
    const path = `${this.path}/${subpath}`;
    const message = new TextEncoder().encode(`${date}:${bodyHash}:${path}`);
    const raw = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, this.key, message));
    const res = await this.fetch(`${HOST}${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Apple-CloudKit-Request-KeyID": this.keyID,
        "X-Apple-CloudKit-Request-ISO8601Date": date,
        "X-Apple-CloudKit-Request-SignatureV1": toB64(rawToDer(raw)),
      },
      body,
    });
    const json = await res.json().catch(() => null);
    if (!res.ok || !json) throw new Error(`CloudKit refused the request (${json?.serverErrorCode ?? res.status}${json?.reason ? ": " + json.reason : ""})`);
    return json;
  }

  async lookup(names, desiredKeys) {
    const json = await this.post("records/lookup", { records: names.map((recordName) => ({ recordName })), ...(desiredKeys ? { desiredKeys } : {}) });
    const byName = new Map();
    for (const r of json.records ?? []) if (!r.serverErrorCode) byName.set(r.recordName, r);
    return names.map((n) => byName.get(n) ?? null);
  }

  async record(name, desiredKeys) { return (await this.lookup([name], desiredKeys))[0]; }

  async query(recordType, fieldName, value, { desiredKeys, maxPages = 20 } = {}) {
    const out = [];
    let marker = null;
    for (let page = 0; page < maxPages; page++) {
      const body = { query: { recordType, filterBy: [{ fieldName, comparator: "EQUALS", fieldValue: { value, type: "STRING" } }] }, resultsLimit: 200 };
      if (desiredKeys) body.desiredKeys = desiredKeys;
      if (marker) body.continuationMarker = marker;
      const json = await this.post("records/query", body);
      for (const r of json.records ?? []) if (!r.serverErrorCode) out.push(r);
      marker = json.continuationMarker;
      if (!marker) break;
    }
    return out;
  }

  /** Creates one record. Returns { created: true } or { exists: true }. Never replaces. */
  async create(recordType, recordName, fields) {
    const json = await this.post("records/modify", {
      // One operation, so nothing to make atomic, and CloudKit refuses
      // "atomic" in the public database's default zone anyway.
      operations: [{ operationType: "create", record: { recordType, recordName, fields } }],
    });
    const r = json.records?.[0];
    if (r && !r.serverErrorCode) return { created: true };
    if (r?.serverErrorCode === "CONFLICT" || r?.serverErrorCode === "RECORD_EXISTS" || /exist/i.test(r?.reason ?? "")) return { exists: true };
    throw new Error(`CloudKit did not save it (${r?.serverErrorCode ?? "no answer"}${r?.reason ? ": " + r.reason : ""})`);
  }
}
