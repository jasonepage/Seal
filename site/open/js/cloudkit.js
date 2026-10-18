// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  cloudkit.js
//
//  Reading Seal's public CloudKit database from a browser, anonymously,
//  through CloudKit Web Services (plain HTTPS and JSON, no Apple script on
//  the page). Read only: this page writes nothing anywhere.
//
//  The API token is made in the CloudKit Console for the Production
//  environment. It is meant to sit in a public web page: it lets anyone
//  read the public database, which anyone with the app can do already.

import { fromB64 } from "./bytes.js";

const HOST = "https://api.apple-cloudkit.com";

export class CloudKit {
  /**
   * `origin` is for scripts only (tools/vectors/live-check.mjs): a token
   * limited to sealmessenger.com refuses a request that does not name it.
   * A browser sends its own Origin and never uses this.
   */
  constructor({ container, environment, apiToken, origin = null }) {
    this.base = `${HOST}/database/1/${encodeURIComponent(container)}/${environment}/public`;
    this.token = apiToken;
    this.origin = origin;
  }

  async #post(path, body) {
    const res = await fetch(`${this.base}/${path}?ckAPIToken=${encodeURIComponent(this.token)}`, {
      method: "POST",
      // text/plain, not application/json: a JSON content type makes the
      // browser ask permission first (a CORS preflight), which CloudKit Web
      // Services does not answer, so every request failed with a network
      // error. The body is still JSON; Apple reads it either way.
      headers: { "Content-Type": "text/plain;charset=UTF-8", ...(this.origin ? { Origin: this.origin } : {}) },
      body: JSON.stringify(body),
      credentials: "omit",
      cache: "no-store",
      referrerPolicy: "no-referrer",
    });
    const json = await res.json().catch(() => null);
    if (!res.ok || !json) {
      const reason = json?.reason ?? json?.serverErrorCode ?? `HTTP ${res.status}`;
      throw new Error(`Apple's server refused the request (${reason}).`);
    }
    return json;
  }

  /** Records by name. Missing ones come back as null, in the same order. */
  async lookup(names, desiredKeys) {
    const out = [];
    for (let i = 0; i < names.length; i += 200) {
      const chunk = names.slice(i, i + 200);
      const body = { records: chunk.map((recordName) => ({ recordName })) };
      if (desiredKeys) body.desiredKeys = desiredKeys;
      const json = await this.#post("records/lookup", body);
      const byName = new Map();
      for (const r of json.records ?? []) if (!r.serverErrorCode) byName.set(r.recordName, r);
      for (const n of chunk) out.push(byName.get(n) ?? null);
    }
    return out;
  }

  async record(name, desiredKeys) {
    return (await this.lookup([name], desiredKeys))[0];
  }

  /** Every record of a type whose STRING field equals a value, following continuations. */
  async query(recordType, fieldName, value, { desiredKeys, maxPages = 20 } = {}) {
    const records = [];
    let marker = null;
    for (let page = 0; page < maxPages; page++) {
      const body = { query: { recordType }, resultsLimit: 200 };
      if (fieldName) {
        body.query.filterBy = [{ fieldName, comparator: "EQUALS", fieldValue: { value, type: "STRING" } }];
      }
      if (desiredKeys) body.desiredKeys = desiredKeys;
      if (marker) body.continuationMarker = marker;
      const json = await this.#post("records/query", body);
      for (const r of json.records ?? []) if (!r.serverErrorCode) records.push(r);
      marker = json.continuationMarker;
      if (!marker) break;
    }
    return records;
  }

  /** The bytes of an ASSETID field, or null. */
  async asset(record, fieldName) {
    const url = record?.fields?.[fieldName]?.value?.downloadURL;
    if (typeof url !== "string") return null;
    const res = await fetch(url.replace("${f}", "blob"), { credentials: "omit", cache: "no-store", referrerPolicy: "no-referrer" });
    if (!res.ok) throw new Error(`A file could not be downloaded (HTTP ${res.status}).`);
    return new Uint8Array(await res.arrayBuffer());
  }
}

/** A BYTES field as a Uint8Array, a STRING field as a string, else null. */
export function bytesField(record, name) {
  const f = record?.fields?.[name];
  if (!f || typeof f.value !== "string") return null;
  try { return fromB64(f.value); } catch { return null; }
}
export function stringField(record, name) {
  const v = record?.fields?.[name]?.value;
  return typeof v === "string" ? v : null;
}
/** Apple's server time for the record's last change, in seconds. */
export function modifiedAt(record) {
  const ms = record?.modified?.timestamp;
  return typeof ms === "number" ? ms / 1000 : null;
}
