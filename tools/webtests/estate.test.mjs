// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  estate.test.mjs
//
//  The recipient page end to end, against an in-memory stand-in for
//  CloudKit: real signatures, real endorsements, real wraps. An owner, two
//  key holders and a recipient with a sponsored key. Checks that an earned
//  release opens, and that every way of cheating the release judgment the
//  phone guards against is refused here too.
//
//      node tools/webtests/estate.test.mjs

import { utf8, toB64, sha256, framed } from "../../site/open/js/bytes.js";
import { unlockSponsored } from "../../site/open/js/crypto.js";
import { findInvites, judgeEstate, openEstate, openMedia, names } from "../../site/open/js/estate.js";
import {
  random, aesSeal, hybridWrap, person, sponsoredHalves, makeEvent, tapBody, estateAAD, assertion,
} from "./fixtures.mjs";

let checks = 0;
const failures = [];
const check = (ok, name) => { checks++; if (!ok) failures.push(name); };
const DAY = 86_400;

// ---------------------------------------------------------------- CloudKit stand-in

class FakeCloudKit {
  constructor() { this.records = new Map(); }
  put(recordName, recordType, fields, modifiedSeconds = 0) {
    this.records.set(recordName, { recordName, recordType, fields, modified: { timestamp: modifiedSeconds * 1000 } });
  }
  async lookup(names) { return names.map((n) => this.records.get(n) ?? null); }
  async record(name) { return this.records.get(name) ?? null; }
  async query(recordType, fieldName, value) {
    return [...this.records.values()].filter((r) => r.recordType === recordType
      && (!fieldName || r.fields[fieldName]?.value === value));
  }
  async asset(record, field) { return record?.fields?.[field]?.value?.bytes ?? null; }
}

// ---------------------------------------------------------------- the estate

const t0 = 1_800_000_000;
const policy = { silenceDays: 90, warningDays: 21, graceDays: 14, threshold: 2, objectionBehavior: "pause", custodyConfirmMonths: 12 };

async function build(variant = {}) {
  const ck = new FakeCloudKit();
  const estateID = "E-" + Math.random().toString(16).slice(2);
  const owner = await person("Dad", { tier: "passkey" });
  const ownerPhone = await owner.addDevice();
  const k1 = await person("Riley"); const k1Phone = await k1.addDevice();
  const k2 = await person("Sam"); const k2Phone = await k2.addDevice();
  const stranger = await person("Mallory"); const strangerPhone = await stranger.addDevice();
  const recipient = await person("Ana");
  const halves = await sponsoredHalves();
  // The sponsored virtual device, endorsed by Ana's own key over the
  // public parts of the halves it locks.
  const commitment0 = await sha256(framed("seal.endorse.v3", [halves.sign.x963, halves.kem.bundle]));
  recipient.endorsements.push({
    devicePublicKey: toB64(halves.sign.x963), kemBundlePublicKeys: toB64(halves.kem.bundle),
    assertion: toB64(utf8(JSON.stringify(await assertion(recipient.root, recipient.credentialID, commitment0)))),
    createdAt: 0, lockedPrivate: toB64(halves.locked), prfSalt: toB64(halves.salt),
  });

  for (const p of [owner, k1, k2, stranger, recipient]) ck.put(p.hash, "Identity", p.fields());
  if (variant.swapK2Key) {
    // The directory serves a different key for Sam than the owner signed.
    const fake = await person("Sam"); await fake.addDevice();
    ck.put(k2.hash, "Identity", { ...fake.fields() });
    k2.devices[0] = fake.devices[0];
  }

  // Keys and tables.
  const estateKey = random(32);
  const tableKey = random(32);
  const contentKey = random(32);
  const tableID = "T-mine", otherTableID = "T-other";
  const payloadBlobID = "B-payload", photoBlobID = "B-photo";
  const photo = utf8("\xff\xd8 a jpeg, honestly");
  const payload = {
    title: "For Ana", letter: "Dear Ana,\nThe boat is yours.",
    secrets: [{ cardType: "password", title: "Bank", value: "hunter2", note: null, asset: null, fallbackText: "Bank" }],
    photos: [{ blobID: photoBlobID, kind: "photo", sha256: toB64(await sha256(photo)), byteCount: photo.length, localName: "p.jpg" }],
    voiceNote: null, revealOrder: 0, writtenAtEpoch: t0,
    firstSteps: [{ id: "s1", title: "Call the lawyer", note: "", secretIndex: null }],
    videoNote: null, openNoEarlierThanEpoch: variant.holdUntil ?? null, files: [],
  };
  ck.put(names.content(estateID, payloadBlobID), "MediaAsset",
    { blob: { value: { bytes: await aesSeal(contentKey, utf8(JSON.stringify(payload)), estateAAD(estateID, 0, `blob.${payloadBlobID}`)) } } });
  const photoBytes = variant.tamperPhoto ? utf8("not the photo that was sealed") : photo;
  ck.put(names.content(estateID, photoBlobID), "MediaAsset",
    { blob: { value: { bytes: await aesSeal(contentKey, photoBytes, estateAAD(estateID, 0, `blob.${photoBlobID}`)) } } });

  const table = { recipientHash: recipient.hash, entries: [{ envelopeID: "env1", contentKey: toB64(contentKey), title: "For Ana", revealOrder: 0, blobIDs: [payloadBlobID, photoBlobID] }] };
  const inner = await aesSeal(estateKey, tableKey, estateAAD(estateID, 1, `tablekey.inner.${tableID}`));
  const wrap = {
    tableID, ownerWraps: [], epoch: 1,
    releaseWraps: [await hybridWrap(inner, halves.kem, estateAAD(estateID, 1, `tablekey.release.${tableID}`))],
    ciphertext: toB64(await aesSeal(tableKey, utf8(JSON.stringify(table)), estateAAD(estateID, 0, `table.${tableID}`))),
  };
  ck.put(names.table(estateID, tableID), "MediaAsset", { blob: { value: { bytes: utf8(JSON.stringify(wrap)) } } });
  // Somebody else's table: wrapped to Sam's phone, not to Ana.
  const otherKey = random(32);
  const otherInner = await aesSeal(estateKey, otherKey, estateAAD(estateID, 1, `tablekey.inner.${otherTableID}`));
  const otherWrap = {
    tableID: otherTableID, ownerWraps: [], epoch: 1,
    releaseWraps: [await hybridWrap(otherInner, k2Phone.kem, estateAAD(estateID, 1, `tablekey.release.${otherTableID}`))],
    ciphertext: toB64(await aesSeal(otherKey, utf8(JSON.stringify({ recipientHash: k2.hash, entries: [] })), estateAAD(estateID, 0, `table.${otherTableID}`))),
  };
  ck.put(names.table(estateID, otherTableID), "MediaAsset", { blob: { value: { bytes: utf8(JSON.stringify(otherWrap)) } } });

  // The invite, wrapped to Ana's virtual device.
  const invite = { estateID, ownerHash: owner.hash, ownerName: "Dad", role: "recipient" };
  ck.put(`estinv.${recipient.hash}.${estateID}`, "GroupInvite", {
    recipient: { value: recipient.hash, type: "STRING" },
    payload: { value: toB64(utf8(JSON.stringify({ estateInvite: [await hybridWrap(utf8(JSON.stringify(invite)), halves.kem, utf8("seal.estate.invite.v1"))] }))), type: "BYTES" },
  });

  // The record.
  const events = [];
  const add = async (args, modified) => {
    const e = await makeEvent({ estateID, ...args });
    events.push(e);
    ck.put(names.event(estateID, e.id), "EstateEvent", {
      estate: { value: estateID, type: "STRING" },
      payload: { value: toB64(utf8(JSON.stringify(e))), type: "BYTES" },
    }, modified ?? args.at);
    return e;
  };
  const commitment = toB64(await sha256(estateKey));
  await add({ kind: "estateCreated", actorHash: owner.hash, device: ownerPhone, at: t0, body: { policy, createdAtEpoch: t0 } });
  await add({ kind: "epochPublished", actorHash: owner.hash, device: ownerPhone, at: t0 + 1, body: {
    epoch: 1, threshold: 2, custodianHashes: [k1.hash, k2.hash],
    custodianPublicKeys: [toB64(k1.root.raw64), toB64(k2.root.raw64)],
    shareCommitments: [toB64(random(32)), toB64(random(32))], estateKeyCommitment: commitment, materialDigest: toB64(random(32)),
  } });
  await add({ kind: "vaultUpdated", actorHash: owner.hash, device: ownerPhone, at: t0 + 2, body: { blobCommitment: toB64(random(32)), tableIDs: [otherTableID, tableID] } });
  await add({ kind: "heartbeat", actorHash: owner.hash, device: ownerPhone, at: t0 + 3 });

  const claimAt = t0 + 3 + 91 * DAY;
  const claimID = "C-1";
  const claimRealAt = variant.backdateClaim ? claimAt + 30 * DAY : claimAt;   // published later than it says
  await add({ kind: "releaseClaimed", actorHash: k1.hash, device: k1Phone, at: claimAt, body: { claimID, epoch: 1, lastHeartbeatAtEpoch: t0 + 3, reason: "quiet" } }, claimRealAt);
  if (variant.heartbeatAfterClaim) await add({ kind: "heartbeat", actorHash: owner.hash, device: ownerPhone, at: claimAt + DAY });
  const opensAt = claimAt + 35 * DAY;
  const tapAt = variant.earlyTaps ? claimAt + 2 * DAY : opensAt + DAY;
  await add({ kind: "authorization", actorHash: k1.hash, device: k1Phone, at: tapAt, body: await tapBody(k1, estateID, 1, claimID) }, variant.backdateClaim ? claimRealAt + DAY : tapAt);
  const k2Body = await tapBody(k2, estateID, 1, claimID);
  if (variant.forgedTap) k2Body.assertion = (await tapBody(stranger, estateID, 1, claimID)).assertion;
  await add({ kind: "authorization", actorHash: k2.hash, device: k2Phone, at: tapAt + 60, body: k2Body }, variant.backdateClaim ? claimRealAt + DAY : tapAt + 60);
  // A stranger's events count for nothing.
  await add({ kind: "authorization", actorHash: stranger.hash, device: strangerPhone, at: tapAt, body: await tapBody(stranger, estateID, 1, claimID) });
  const releasedKey = variant.wrongKey ? random(32) : estateKey;
  await add({ kind: "released", actorHash: k1.hash, device: k1Phone, at: tapAt + 120, body: { claimID, epoch: 1, shareIndexes: [1, 2], estateKey: toB64(releasedKey) } }, variant.backdateClaim ? claimRealAt + DAY : tapAt + 120);
  if (variant.departedCancel) await add({ kind: "ownerDeparted", actorHash: owner.hash, device: ownerPhone, at: t0 + 4, body: { keepEnvelopes: false, departedAtEpoch: t0 + 4 } });

  return { ck, estateID, owner, recipient, halves, payload, photo, tapAt };
}

async function scenario(name, variant, expect) {
  const s = await build(variant);
  const now = s.tapAt + 200 + 1;
  const unlocked = await unlockSponsored(s.halves.locked, s.halves.prf, s.halves.salt);
  const kems = [unlocked.kem];
  const invites = await findInvites(s.ck, s.recipient.hash, kems);
  check(invites.length === 1 && invites[0].estateID === s.estateID, `${name}: the invite opens`);
  const judged = await judgeEstate(s.ck, invites[0], now + (expect.laterBy ?? 0));
  check(judged.state === expect.state, `${name}: state is ${expect.state} (got ${judged.state})`);
  if (expect.state !== "released") {
    let refused = false;
    try { await openEstate(s.ck, judged, kems, now); } catch { refused = true; }
    check(refused, `${name}: nothing opens`);
    return;
  }
  let opened = null, problem = null;
  try { opened = await openEstate(s.ck, judged, kems, now + (expect.laterBy ?? 0)); } catch (e) { problem = e.message; }
  if (expect.openFails) { check(problem !== null, `${name}: opening is refused`); return; }
  check(opened && opened.length === 1, `${name}: exactly my one envelope opens (${problem ?? ""})`);
  if (!opened?.length) return;
  const { entry, payload } = opened[0];
  check(payload.letter === s.payload.letter && payload.secrets[0].value === "hunter2", `${name}: the letter and the secret read back exactly`);
  check(payload.firstSteps?.[0]?.title === "Call the lawyer", `${name}: first steps read back`);
  let photo = null, photoProblem = null;
  try { photo = await openMedia(s.ck, s.estateID, entry, payload.photos[0]); } catch (e) { photoProblem = e.message; }
  if (variant.tamperPhoto) check(photo === null && /does not match/.test(photoProblem ?? ""), `${name}: a swapped photo is refused`);
  else check(photo && photo.length === s.photo.length, `${name}: the photo opens and matches its hash`);
}

await scenario("honest release", {}, { state: "released" });
// Taps made early still count from the moment the claim opens (releaseEarned),
// so the release is dated then, in the future, and proves nothing yet.
await scenario("taps and release before the claim opened", { earlyTaps: true }, { state: "warning" });
await scenario("owner checked in after the claim", { heartbeatAfterClaim: true }, { state: "cancelled" });
await scenario("key does not match the owner's commitment", { wrongKey: true }, { state: "authorized" });
await scenario("one tap signed by the wrong key", { forgedTap: true }, { state: "claimOpen" });
await scenario("directory swapped a key holder's key", { swapK2Key: true }, { state: "claimOpen" });
await scenario("claim backdated, published 30 days late", { backdateClaim: true }, { state: "warning" });
await scenario("owner left and cancelled", { departedCancel: true }, { state: "released", openFails: true });
await scenario("photo swapped in storage", { tamperPhoto: true }, { state: "released" });

for (const f of failures) console.log(`FAIL ${f}`);
console.log(`${checks} checks, ${failures.length} failures`);
process.exit(failures.length ? 1 : 0);
