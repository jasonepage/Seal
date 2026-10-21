// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  retire.test.mjs
//
//  Retiring a key from the web (worker/index.js, relayRetire): the relay
//  writes the phone's own write-once "tomb.<hash>" marker only for a tap by
//  the identity's own root key over the delete challenge, and the proof it
//  stores is one every phone accepts (TombstoneProof.markerCounts).
//
//      node tools/webtests/retire.test.mjs

import { utf8, toB64, fromB64, toHex, sha256 } from "../../site/open/js/bytes.js";
import { parseAssertion, verifyAssertion, clientDataChallengeMatches } from "../../site/open/js/identity.js";
import { relayRetire, retireChallenge } from "../../worker/index.js";
import { random, person, assertion } from "./fixtures.mjs";

let checks = 0;
const failures = [];
const check = (ok, name) => { checks++; if (!ok) failures.push(name); };

class FakeCloudKit {
  constructor() { this.records = new Map(); }
  put(recordName, recordType, fields) { this.records.set(recordName, { recordName, recordType, fields, modified: { timestamp: 0 } }); }
  async lookup(n) { return n.map((x) => this.records.get(x) ?? null); }
  async record(name) { return this.records.get(name) ?? null; }
  async query(recordType, fieldName, value) {
    return [...this.records.values()].filter((r) => r.recordType === recordType && (!fieldName || r.fields[fieldName]?.value === value));
  }
  async create(recordType, recordName, fields) {
    if (this.records.has(recordName)) return { exists: true };
    this.put(recordName, recordType, fields);
    return { created: true };
  }
}

const env = { ALLOWED_ORIGIN: "https://sealmessenger.com" };
const send = (ck, body, origin = "https://sealmessenger.com") => relayRetire(
  new Request("https://sealmessenger.com/relay/retire", { method: "POST", headers: { Origin: origin, "Content-Type": "text/plain" }, body: JSON.stringify(body) }),
  env, { server: ck });

async function retireBody(signer, credentialID, { challengeFor = null } = {}) {
  const nonce = random(32);
  const challenge = challengeFor ?? await retireChallenge(nonce);
  return { retire: { nonce: toB64(nonce), assertion: await assertion(signer.root, credentialID, challenge) } };
}

const ck = new FakeCloudKit();
const karen = await person("Karen");
await karen.addDevice();
ck.put(karen.hash, "Identity", karen.fields());
const bob = await person("Bob");
ck.put(bob.hash, "Identity", bob.fields());

// Refusals first, while Karen is alive.
{
  const res = await send(ck, await retireBody(karen, karen.credentialID), "https://evil.example");
  check(res.status === 403, "another site's page is refused");
  const wrong = await send(ck, await retireBody(karen, karen.credentialID, { challengeFor: random(32) }));
  check(wrong.status === 400, "a tap made for something else is refused");
  const forged = await send(ck, await retireBody(bob, karen.credentialID));
  check(forged.status === 403, "someone else's key cannot retire Karen");
  const stranger = await person("Nobody");
  const missing = await send(ck, await retireBody(stranger, stranger.credentialID));
  check(missing.status === 404, "a key with no identity of its own (a backup key) is refused");
  check(!ck.records.has(`tomb.${karen.hash}`), "nothing was written by any refusal");
}

// The real retire.
{
  const res = await send(ck, await retireBody(karen, karen.credentialID));
  const answer = await res.json();
  check(res.status === 200 && answer.ok && answer.hash === karen.hash && !answer.existed, "Karen's own tap retires Karen");
  const tomb = ck.records.get(`tomb.${karen.hash}`);
  check(tomb?.recordType === "Identity" && tomb.fields.tier?.value === "deleted", "the marker is the phone's: an Identity record, tier deleted");
  // The stored proof, read the way a phone reads it.
  const proof = JSON.parse(new TextDecoder().decode(fromB64(tomb.fields.revocations.value)));
  const a = parseAssertion(utf8(JSON.stringify(proof.assertion)));
  check(!!a && toHex(await sha256(a.credentialID)) === karen.hash, "the proof names Karen's credential");
  check(clientDataChallengeMatches(a.clientDataJSON, await retireChallenge(fromB64(proof.nonce))), "the proof is over the delete challenge");
  check(await verifyAssertion(a, karen.root.raw64), "the proof verifies against Karen's root key");
  check(Object.keys(proof).sort().join() === "assertion,nonce"
    && Object.keys(proof.assertion).sort().join() === "authenticatorData,clientDataJSON,credentialID,signature",
    "the proof has exactly TombstoneProof's and WebAuthnAssertion's keys");
  check(ck.records.get(karen.hash).fields.tier.value === "verified", "the live record is left alone (only its creator may change it)");

  const again = await (await send(ck, await retireBody(karen, karen.credentialID))).json();
  check(again.ok && again.existed, "retiring twice is fine and says it was already done");
  check(ck.records.has(bob.hash) && !ck.records.has(`tomb.${bob.hash}`), "Bob is untouched");
}

for (const f of failures) console.log(`FAIL ${f}`);
console.log(`${checks} checks, ${failures.length} failures`);
process.exit(failures.length ? 1 : 0);
