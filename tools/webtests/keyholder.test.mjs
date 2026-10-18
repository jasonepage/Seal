// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  keyholder.test.mjs
//
//  The key holder page and the relay end to end (1.2b), in Node, against
//  an in-memory stand-in for CloudKit. An owner on a phone, two key holders
//  on the web with sponsored keys, and a recipient on the web. The key
//  holders confirm custody, one claims, the other objects and withdraws,
//  both tap, the claimant combines, and the recipient opens the envelope:
//  every entry built by the page, signed by the browser's device key, sent
//  through the relay, and judged again by the page's own release rules.
//
//      node tools/webtests/keyholder.test.mjs

import { generateKeyPairSync } from "node:crypto";
import { utf8, toB64, fromB64, sha256, framed, same } from "../../site/open/js/bytes.js";
import { unlockSponsored, estateAAD } from "../../site/open/js/crypto.js";
import { signingKeyFrom } from "../../site/open/js/signer.js";
import { buildAction, publish, custodyChallenge } from "../../site/open/js/keyholder.js";
import { findInvites, judgeEstate, openEstate, names } from "../../site/open/js/estate.js";
import { verifyP256 } from "../../site/open/js/ecdsa.js";
import { verifyAssertion, clientDataChallengeMatches } from "../../site/open/js/identity.js";
import { relayEvent, timestampRequest } from "../../worker/index.js";
import { CloudKitServer, importPrivateKey } from "../../worker/cloudkit-s2s.js";
import { random, aesSeal, hybridWrap, person, sponsoredHalves, makeEvent, assertion } from "./fixtures.mjs";

let checks = 0;
const failures = [];
const check = (ok, name) => { checks++; if (!ok) failures.push(name); };
async function mustFail(fn, pattern, name) {
  checks++;
  try { await fn(); failures.push(`${name} (did not fail)`); }
  catch (e) { if (pattern && !pattern.test(e.message)) failures.push(`${name} (failed with: ${e.message})`); }
}
const DAY = 86_400;

// ---------------------------------------------------------------- CloudKit and the relay, in memory

class FakeCloudKit {
  constructor() { this.records = new Map(); this.clock = 0; }
  put(recordName, recordType, fields, modifiedSeconds = this.clock) {
    this.records.set(recordName, { recordName, recordType, fields, modified: { timestamp: modifiedSeconds * 1000 } });
  }
  async lookup(n) { return n.map((x) => this.records.get(x) ?? null); }
  async record(name) { return this.records.get(name) ?? null; }
  async query(recordType, fieldName, value) {
    return [...this.records.values()].filter((r) => r.recordType === recordType && (!fieldName || r.fields[fieldName]?.value === value));
  }
  async asset(record, field) { return record?.fields?.[field]?.value?.bytes ?? null; }
  // The relay's server key: create only.
  async create(recordType, recordName, fields) {
    if (this.records.has(recordName)) return { exists: true };
    this.put(recordName, recordType, fields);
    return { created: true };
  }
}

const env = { ALLOWED_ORIGIN: "https://sealmessenger.com" };
const noTSA = async () => new Response("down", { status: 503 });

/** The page's fetch to /relay/event, answered by the real relay code. */
function relayFetch(ck, { origin = "https://sealmessenger.com", tamper = null } = {}) {
  return async (url, init) => {
    let body = init.body;
    if (tamper) body = tamper(body);
    const req = new Request("https://sealmessenger.com" + url, { method: "POST", headers: { Origin: origin, "Content-Type": "text/plain" }, body });
    return relayEvent(req, env, { server: ck, fetchImpl: noTSA });
  };
}

/** A software security key answering navigator.credentials.get for one person. */
function useKey(p) {
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { credentials: { get: async ({ publicKey }) => {
      const a = await assertion(p.root, p.credentialID, publicKey.challenge);
      return {
        rawId: fromB64(a.credentialID).buffer,
        response: {
          clientDataJSON: fromB64(a.clientDataJSON).buffer,
          authenticatorData: fromB64(a.authenticatorData).buffer,
          signature: fromB64(a.signature).buffer,
        },
      };
    } } },
  });
}

// ---------------------------------------------------------------- Shamir split (test side only)

function gfMul(a, b) { let r = 0; while (b) { if (b & 1) r ^= a; a <<= 1; if (a & 0x100) a ^= 0x11b; b >>= 1; } return r & 0xff; }
function split(secret, threshold, n) {
  const shares = [];
  const coeffs = [...secret].map((s) => [s, ...random(threshold - 1)]);
  for (let x = 1; x <= n; x++) {
    const y = coeffs.map((c) => { let acc = 0, p = 1; for (const k of c) { acc ^= gfMul(k, p); p = gfMul(p, x); } return acc; });
    shares.push(Uint8Array.of(x, ...y));
  }
  return shares;
}

// ---------------------------------------------------------------- people

/** A person whose only device is a sponsored key's virtual device, as on the web. */
async function webPerson(name) {
  const p = await person(name);
  const halves = await sponsoredHalves();
  const commitment = await sha256(framed("seal.endorse.v3", [halves.sign.x963, halves.kem.bundle]));
  p.endorsements.push({
    devicePublicKey: toB64(halves.sign.x963), kemBundlePublicKeys: toB64(halves.kem.bundle),
    assertion: toB64(utf8(JSON.stringify(await assertion(p.root, p.credentialID, commitment)))),
    createdAt: 0, lockedPrivate: toB64(halves.locked), prfSalt: toB64(halves.salt),
  });
  p.halves = halves;
  return p;
}
/** What the page holds after the two taps. */
async function session(p) {
  const u = await unlockSponsored(p.halves.locked, p.halves.prf, p.halves.salt);
  return { hash: p.hash, credentialID: p.credentialID, kems: [u.kem], signer: await signingKeyFrom(u.signingKey, p.halves.sign.x963) };
}

// ---------------------------------------------------------------- the estate

const t0 = 1_800_000_000;
const policy = { silenceDays: 90, warningDays: 21, graceDays: 14, threshold: 2, objectionBehavior: "pause", custodyConfirmMonths: 12 };

const ck = new FakeCloudKit();
const estateID = "E-keyholders";
const owner = await person("Dad", { tier: "passkey" });
const ownerPhone = await owner.addDevice();
const riley = await webPerson("Riley");
const sam = await webPerson("Sam");
const ana = await webPerson("Ana");
for (const p of [owner, riley, sam, ana]) ck.put(p.hash, "Identity", p.fields(), 0);

const estateKey = random(32);
const shares = split(estateKey, 2, 2);
const holders = [riley, sam];
const material = {
  estateID, epoch: 1, threshold: 2, ownerWraps: [],
  custodianShares: await Promise.all(holders.map(async (k, i) => ({
    custodianHash: k.hash, shareIndex: i + 1,
    envelopes: [await hybridWrap(shares[i], k.halves.kem, estateAAD(estateID, 1, `share.${i + 1}`))],
    commitment: toB64(await sha256(shares[i])),
  }))),
  estateKeyCommitment: toB64(await sha256(estateKey)),
};
const materialBytes = utf8(JSON.stringify(material));
ck.put(`est.${estateID}.epoch.1`, "MediaAsset", { blob: { value: { bytes: materialBytes } } }, 0);

// Ana's table and envelope.
const tableID = "T-ana", tableKey = random(32), contentKey = random(32), blobID = "B-1";
const payload = { title: "For Ana", letter: "The boat is yours.", secrets: [], photos: [], voiceNote: null, revealOrder: 0, writtenAtEpoch: t0, firstSteps: [], videoNote: null, openNoEarlierThanEpoch: null, files: [] };
ck.put(names.content(estateID, blobID), "MediaAsset", { blob: { value: { bytes: await aesSeal(contentKey, utf8(JSON.stringify(payload)), estateAAD(estateID, 0, `blob.${blobID}`)) } } }, 0);
const table = { recipientHash: ana.hash, entries: [{ envelopeID: "env1", contentKey: toB64(contentKey), title: "For Ana", revealOrder: 0, blobIDs: [blobID] }] };
const inner = await aesSeal(estateKey, tableKey, estateAAD(estateID, 1, `tablekey.inner.${tableID}`));
ck.put(names.table(estateID, tableID), "MediaAsset", { blob: { value: { bytes: utf8(JSON.stringify({
  tableID, ownerWraps: [], epoch: 1,
  releaseWraps: [await hybridWrap(inner, ana.halves.kem, estateAAD(estateID, 1, `tablekey.release.${tableID}`))],
  ciphertext: toB64(await aesSeal(tableKey, utf8(JSON.stringify(table)), estateAAD(estateID, 0, `table.${tableID}`))),
})) } } }, 0);

// Invites: Riley and Sam as key holders, Ana as a recipient.
async function invite(p, role) {
  const inv = { estateID, ownerHash: owner.hash, ownerName: "Dad", role };
  ck.put(`estinv.${p.hash}.${estateID}`, "GroupInvite", {
    recipient: { value: p.hash, type: "STRING" },
    payload: { value: toB64(utf8(JSON.stringify({ estateInvite: [await hybridWrap(utf8(JSON.stringify(inv)), p.halves.kem, utf8("seal.estate.invite.v1"))] }))), type: "BYTES" },
  }, 0);
}
await invite(riley, "custodian"); await invite(sam, "custodian"); await invite(ana, "recipient");

// The owner's phone writes the start of the record.
let ownerHead = new Uint8Array(0);
async function ownerEvent(kind, at, body = null) {
  const e = await makeEvent({ kind, estateID, actorHash: owner.hash, device: ownerPhone, at, body, previousDigest: ownerHead });
  ck.put(names.event(estateID, e.id), "EstateEvent", { estate: { value: estateID, type: "STRING" }, payload: { value: toB64(utf8(JSON.stringify(e))), type: "BYTES" } }, at);
  return e;
}
await ownerEvent("estateCreated", t0, { policy, createdAtEpoch: t0 });
await ownerEvent("epochPublished", t0 + 1, {
  epoch: 1, threshold: 2, custodianHashes: holders.map((k) => k.hash), custodianPublicKeys: holders.map((k) => toB64(k.root.raw64)),
  shareCommitments: material.custodianShares.map((s) => s.commitment), estateKeyCommitment: material.estateKeyCommitment,
  materialDigest: toB64(await sha256(materialBytes)),
});
await ownerEvent("vaultUpdated", t0 + 2, { blobCommitment: toB64(random(32)), tableIDs: [tableID] });
await ownerEvent("heartbeat", t0 + 3);

// ---------------------------------------------------------------- the page, step by step

const R = await session(riley), S = await session(sam), A = await session(ana);
const rpId = "sealmessenger.com";
const quick = { sleep: async () => {}, wait: 0 };

async function judged(who, now) {
  const invites = await findInvites(ck, who.hash, who.kems);
  return judgeEstate(ck, { ...invites.find((i) => i.estateID === estateID) }, now);
}
async function step(p, sess, action, now, extra = {}) {
  useKey(p);
  ck.clock = now;
  const j = await judged(sess, now);
  const built = await buildAction(action, { ck, judged: j, me: sess, now, rpId, ...extra });
  return publish(ck, built, { fetchImpl: relayFetch(ck), ...quick });
}

// 1. Custody confirmation from the web, any time.
let now = t0 + 10 * DAY;
const saved = await step(riley, R, "confirmCustody", now);
check(saved.saved, "custody confirmation: saved and read back from Apple's copy");
{
  const j = await judged(R, now);
  const e = j.events.find((x) => x.kind === "custodyConfirmed");
  check(!!e && e.actorHash === riley.hash, "custody confirmation: admitted as Riley's, from her endorsed browser device");
  const expected = e && await custodyChallenge(estateID, 1, e.body.recordHeadDigest);
  check(e && await verifyAssertion(e.body.assertion, riley.root.raw64) && clientDataChallengeMatches(e.body.assertion.clientDataJSON, expected),
    "custody confirmation: the tap verifies under Riley's root key over the custody challenge");
}

// 2. A claim is refused before the silence has run, and accepted after.
await mustFail(() => step(riley, R, "claim", t0 + 30 * DAY, { reason: "early" }), /silent for the full period/, "claim: refused while the writer is not overdue");
now = t0 + 3 + 91 * DAY;
check((await step(riley, R, "claim", now, { reason: "No word since spring" })).saved, "claim: saved after 91 days of silence");
check((await judged(R, now + 60)).state === "warning", "claim: the estate reads warning");

// 3. Sam objects, which holds it; withdrawing lets it run again.
now += 2 * DAY;
check((await step(sam, S, "object", now, { note: "He is travelling" })).saved, "objection: saved");
check((await judged(S, now + 60)).state === "objected", "objection: the estate reads objected");
now += 1 * DAY;
check((await step(sam, S, "withdraw", now, { note: "Spoke to his sister" })).saved, "withdrawal: saved");
check((await judged(S, now + 60)).state === "warning", "withdrawal: back to warning");

// 4. Taps are refused until the warnings and grace have run (paused time included).
await mustFail(() => step(sam, S, "tap", now + DAY), /not open for keys yet/, "tap: refused during warnings");
now = t0 + 3 + 91 * DAY + 35 * DAY + 1 * DAY + 2 * DAY;   // claim + warning + grace + pause, plus margin
check((await judged(R, now)).state === "claimOpen", "taps: the claim is open for keys");
check((await step(riley, R, "tap", now)).saved, "tap: Riley's tap saved");
await mustFail(() => step(riley, R, "tap", now + 60), /already tapped/, "tap: a second tap by Riley is refused");
await mustFail(() => step(sam, S, "release", now + 60), /Only the key holder who started/, "release: refused for someone who did not claim");
check((await step(sam, S, "tap", now + 120)).saved, "tap: Sam's tap saved");
check((await judged(R, now + 180)).state === "authorized", "taps: the estate reads authorized");

// 5. Riley combines. The released key must be the owner's.
check((await step(riley, R, "release", now + 240)).saved, "release: saved");
const after = await judged(A, now + 300);
check(after.state === "released", `release: the estate reads released (got ${after.state})`);
const opened = await openEstate(ck, after, A.kems, now + 300).catch((e) => e.message);
check(Array.isArray(opened) && opened.length === 1 && opened[0].payload.letter === "The boat is yours.", "release: Ana opens her envelope in the browser");

// ---------------------------------------------------------------- the relay refuses what a phone would refuse

{
  useKey(riley);
  const j = await judged(R, now + 400);
  const built = await buildAction("confirmCustody", { ck, judged: j, me: R, now: now + 400, rpId });
  const wrongOrigin = relayFetch(ck, { origin: "https://evil.example" });
  await mustFail(() => publish(ck, built, { fetchImpl: wrongOrigin, ...quick }), /only takes entries from sealmessenger.com/, "relay: refuses another site");
  const flipped = relayFetch(ck, { tamper: (body) => { const o = JSON.parse(body); o.event.occurredAtEpoch -= 1; return JSON.stringify(o); } });
  await mustFail(() => publish(ck, built, { fetchImpl: flipped, ...quick }), /signature does not check out/, "relay: refuses an entry changed after signing");
  const ownerKind = relayFetch(ck, { tamper: (body) => { const o = JSON.parse(body); o.event.kind = "heartbeat"; return JSON.stringify(o); } });
  await mustFail(() => publish(ck, built, { fetchImpl: ownerKind, ...quick }), /Only a key holder's entries/, "relay: refuses a writer's kind of entry");
  // Signed by a device the actor's key never endorsed.
  const rogue = await sponsoredHalves();
  const rogueSigner = await signingKeyFrom((await unlockSponsored(rogue.locked, rogue.prf, rogue.salt)).signingKey, rogue.sign.x963);
  const built2 = await buildAction("confirmCustody", { ck, judged: j, me: { ...R, signer: rogueSigner }, now: now + 400, rpId });
  await mustFail(() => publish(ck, built2, { fetchImpl: relayFetch(ck), ...quick }), /not signed by a device/, "relay: refuses a device the key holder never endorsed");
  // A relay that says yes but saves nothing is caught by the read back.
  const liar = async () => new Response(JSON.stringify({ ok: true }), { status: 200 });
  await mustFail(() => publish(ck, built, { fetchImpl: liar, ...quick }), /could not be found/, "page: does not say saved when Apple has no copy");
}

// ---------------------------------------------------------------- server-to-server signing

{
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const pem = privateKey.export({ type: "sec1", format: "pem" });
  const key = await importPrivateKey(pem);
  const pub = new Uint8Array(publicKey.export({ type: "spki", format: "der" })).slice(-65);
  let seen = null;
  const server = new CloudKitServer({
    container: "iCloud.io.github.jasonepage.Seal", environment: "production", keyID: "KEYID", privateKey: key,
    now: () => new Date("2026-10-17T21:00:00.123Z"),
    fetchImpl: async (url, init) => { seen = { url, init }; return new Response(JSON.stringify({ records: [{ recordName: "x" }] })); },
  });
  await server.create("EstateEvent", "x", {});
  const h = seen.init.headers;
  check(h["X-Apple-CloudKit-Request-KeyID"] === "KEYID", "s2s: key id header");
  check(h["X-Apple-CloudKit-Request-ISO8601Date"] === "2026-10-17T21:00:00Z", "s2s: date without milliseconds");
  check(seen.url === "https://api.apple-cloudkit.com/database/1/iCloud.io.github.jasonepage.Seal/production/public/records/modify", "s2s: the records/modify path");
  const message = utf8(`2026-10-17T21:00:00Z:${toB64(await sha256(utf8(seen.init.body)))}:/database/1/iCloud.io.github.jasonepage.Seal/production/public/records/modify`);
  check(await verifyP256(pub, fromB64(h["X-Apple-CloudKit-Request-SignatureV1"]), message), "s2s: DER signature over date:bodyhash:path verifies under the key");
  const pk8 = await importPrivateKey(privateKey.export({ type: "pkcs8", format: "pem" }));
  check(!!pk8, "s2s: a PKCS#8 key imports too");
}

// ---------------------------------------------------------------- the timestamp request

{
  const digest = random(32);
  const req = timestampRequest(digest);
  check(req[0] === 0x30 && same(req.slice(req.length - 3), Uint8Array.of(0x01, 0x01, 0xff)), "tsa: a SEQUENCE ending in certReq TRUE");
  const at = req.findIndex((_, i) => req[i] === 0x04 && req[i + 1] === 32);
  check(at > 0 && same(req.slice(at + 2, at + 34), digest), "tsa: carries the event digest as the SHA-256 imprint");
}

for (const f of failures) console.log(`FAIL ${f}`);
console.log(`${checks} checks, ${failures.length} failures`);
process.exit(failures.length ? 1 : 0);
