// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  bottle.test.mjs
//
//  The 1.3 rule kinds on the recipient page (PRODUCT.md section 17), end to
//  end, against an in-memory stand-in for CloudKit, with real signatures
//  and real wraps:
//
//    right away   a table wrapped straight to the recipient opens with no
//                 release, but only when the owner's signed rule says so,
//                 only from a table the owner's vault lists, and never for
//                 anybody else;
//    break glass  a rule with no quiet time rests as "active", a claim on
//                 day one warns, and the owner's check-in stops it.
//
//      node tools/webtests/bottle.test.mjs

import { utf8, toB64, sha256, framed } from "../../site/open/js/bytes.js";
import { unlockSponsored } from "../../site/open/js/crypto.js";
import { findInvites, judgeEstate, openEstate, names } from "../../site/open/js/estate.js";
import { random, aesSeal, hybridWrap, person, sponsoredHalves, makeEvent, estateAAD, assertion } from "./fixtures.mjs";

let checks = 0;
const failures = [];
const check = (ok, name) => { checks++; if (!ok) failures.push(name); };
const DAY = 86_400;

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

const t0 = 1_800_000_000;
const base = { silenceDays: 90, warningDays: 21, graceDays: 14, threshold: 1, objectionBehavior: "pause", custodyConfirmMonths: 12 };

/** A table wrap the way EstateKeyHierarchy publishes it: direct or release. */
async function tableWrap({ estateID, tableID, table, tableKey, kem, direct, estateKey }) {
  const ciphertext = toB64(await aesSeal(tableKey, utf8(JSON.stringify(table)), estateAAD(estateID, 0, `table.${tableID}`)));
  if (direct) {
    return { tableID, ownerWraps: [], releaseWraps: [], epoch: 0, ciphertext,
      directWraps: [await hybridWrap(tableKey, kem, estateAAD(estateID, 0, `tablekey.direct.${tableID}`))] };
  }
  const inner = await aesSeal(estateKey, tableKey, estateAAD(estateID, 1, `tablekey.inner.${tableID}`));
  return { tableID, ownerWraps: [], epoch: 1, ciphertext,
    releaseWraps: [await hybridWrap(inner, kem, estateAAD(estateID, 1, `tablekey.release.${tableID}`))] };
}

async function build(variant = {}) {
  const ck = new FakeCloudKit();
  const estateID = "E-" + Math.random().toString(16).slice(2);
  const owner = await person("Dad", { tier: "passkey" });
  const ownerPhone = await owner.addDevice();
  const sam = await person("Sam"); const samPhone = await sam.addDevice();
  const k2 = await person("Riley"); const k2Phone = await k2.addDevice();
  const recipient = await person("Ana");
  const halves = await sponsoredHalves();
  const commitment0 = await sha256(framed("seal.endorse.v3", [halves.sign.x963, halves.kem.bundle]));
  recipient.endorsements.push({
    devicePublicKey: toB64(halves.sign.x963), kemBundlePublicKeys: toB64(halves.kem.bundle),
    assertion: toB64(utf8(JSON.stringify(await assertion(recipient.root, recipient.credentialID, commitment0)))),
    createdAt: 0, lockedPrivate: toB64(halves.locked), prfSalt: toB64(halves.salt),
  });
  for (const p of [owner, sam, k2, recipient]) ck.put(p.hash, "Identity", p.fields());

  const contentKey = random(32);
  const payloadBlobID = "B-payload";
  const payload = {
    title: "The house", letter: "Ana, the alarm code is on the card.",
    secrets: [{ cardType: "combination", title: "Alarm", value: "2468", note: null, asset: null, fallbackText: "Alarm" }],
    photos: [], voiceNote: null, revealOrder: 0, writtenAtEpoch: t0,
    firstSteps: [], videoNote: null, openNoEarlierThanEpoch: null, files: [],
  };
  ck.put(names.content(estateID, payloadBlobID), "MediaAsset",
    { blob: { value: { bytes: await aesSeal(contentKey, utf8(JSON.stringify(payload)), estateAAD(estateID, 0, `blob.${payloadBlobID}`)) } } });

  const estateKey = random(32);
  const mine = { recipientHash: recipient.hash, entries: [{ envelopeID: "e1", contentKey: toB64(contentKey), title: "The house", revealOrder: 0, blobIDs: [payloadBlobID] }] };
  const direct = variant.releaseTable ? false : true;
  const myWrap = await tableWrap({ estateID, tableID: "T-mine", table: mine, tableKey: random(32), kem: halves.kem, direct, estateKey });
  ck.put(names.table(estateID, "T-mine"), "MediaAsset", { blob: { value: { bytes: utf8(JSON.stringify(myWrap)) } } });
  const samsWrap = await tableWrap({ estateID, tableID: "T-sam", table: { recipientHash: sam.hash, entries: [] }, tableKey: random(32), kem: samPhone.kem, direct: true });
  ck.put(names.table(estateID, "T-sam"), "MediaAsset", { blob: { value: { bytes: utf8(JSON.stringify(samsWrap)) } } });

  const invite = { estateID, ownerHash: owner.hash, ownerName: "Dad", role: "recipient" };
  ck.put(`estinv.${recipient.hash}.${estateID}`, "GroupInvite", {
    recipient: { value: recipient.hash, type: "STRING" },
    payload: { value: toB64(utf8(JSON.stringify({ estateInvite: [await hybridWrap(utf8(JSON.stringify(invite)), halves.kem, utf8("seal.estate.invite.v1"))] }))), type: "BYTES" },
  });

  const add = async (args, modified) => {
    const e = await makeEvent({ estateID, ...args });
    ck.put(names.event(estateID, e.id), "EstateEvent", {
      estate: { value: estateID, type: "STRING" },
      payload: { value: toB64(utf8(JSON.stringify(e))), type: "BYTES" },
    }, modified ?? args.at);
    return e;
  };
  const policy = variant.kind === undefined ? { ...base, kind: "rightAway" }
    : variant.kind === null ? { ...base } : { ...base, ...variant.policy, kind: variant.kind };
  await add({ kind: "estateCreated", actorHash: owner.hash, device: ownerPhone, at: t0, body: { policy, createdAtEpoch: t0 } });
  if (variant.kind === "breakGlass" || variant.claimAt) {
    await add({ kind: "epochPublished", actorHash: owner.hash, device: ownerPhone, at: t0 + 1, body: {
      epoch: 1, threshold: 2, custodianHashes: [sam.hash, k2.hash],
      custodianPublicKeys: [toB64(sam.root.raw64), toB64(k2.root.raw64)],
      shareCommitments: [toB64(random(32)), toB64(random(32))], estateKeyCommitment: toB64(await sha256(estateKey)), materialDigest: toB64(random(32)),
    } });
  }
  const listed = variant.unlisted ? ["T-sam"] : ["T-sam", "T-mine"];
  await add({ kind: "vaultUpdated", actorHash: owner.hash, device: ownerPhone, at: t0 + 2, body: { blobCommitment: toB64(random(32)), tableIDs: listed } });
  await add({ kind: "heartbeat", actorHash: owner.hash, device: ownerPhone, at: t0 + 3 });
  if (variant.claimAt) {
    await add({ kind: "releaseClaimed", actorHash: sam.hash, device: samPhone, at: t0 + 3 + variant.claimAt, body: { claimID: "C-1", epoch: 1, lastHeartbeatAtEpoch: t0 + 3, reason: "the bank called" } });
  }
  if (variant.checkInAfter) await add({ kind: "heartbeat", actorHash: owner.hash, device: ownerPhone, at: t0 + 3 + variant.checkInAfter });
  return { ck, estateID, recipient, halves, payload };
}

async function open(name, variant, now = t0 + 60) {
  const s = await build(variant);
  const unlocked = await unlockSponsored(s.halves.locked, s.halves.prf, s.halves.salt);
  const kems = [unlocked.kem];
  const invites = await findInvites(s.ck, s.recipient.hash, kems);
  check(invites.length === 1, `${name}: the invite opens`);
  const judged = await judgeEstate(s.ck, invites[0], now);
  let opened = null, problem = null;
  try { opened = await openEstate(s.ck, judged, kems, now); } catch (e) { problem = e.message; }
  return { judged, opened, problem, s };
}

// Right away: opens at once, mine only, and reads back exactly.
{
  const { judged, opened, s } = await open("right away", {});
  check(judged.kind === "rightAway", "right away: the owner's signed rule says right away");
  check(judged.state === "released", `right away: shown as open (got ${judged.state})`);
  check(opened?.length === 1, "right away: exactly my one envelope opens, with no release");
  check(opened?.[0]?.payload.secrets[0].value === "2468" && opened?.[0]?.payload.letter === s.payload.letter, "right away: the letter and the secret read back exactly");
}
// A direct table under a quiet rule is never opened.
{
  const { judged, opened, problem } = await open("direct table, quiet rule", { kind: null });
  check(judged.state !== "released", "direct table, quiet rule: not shown as open");
  check(opened === null && /still sealed/.test(problem ?? ""), "direct table, quiet rule: nothing opens");
}
// A release table under a right away rule is not opened the direct way.
{
  const { opened } = await open("release table, right away rule", { releaseTable: true });
  check(Array.isArray(opened) && opened.length === 0, "release table, right away rule: nothing opens");
}
// A table the owner's vault does not list is not tried.
{
  const { opened } = await open("unlisted table", { unlisted: true });
  check(Array.isArray(opened) && opened.length === 0, "unlisted table: nothing opens");
}
// An unknown kind fails the body, as on the phone, so the rule reads as quiet.
{
  const { judged, opened } = await open("unknown kind", { kind: "sooner" });
  check(judged.kind === "quiet" && opened === null, "unknown kind: treated as no rule, nothing opens");
}
// Break glass (instant): rests as active, a claim on day one is open for
// taps at once, and nothing the owner sends voids it.
{
  const glass = { silenceDays: 0, warningDays: 0, graceDays: 0, threshold: 2 };
  const rest = await open("break glass at rest", { kind: "breakGlass", policy: glass }, t0 + 30 * DAY);
  check(rest.judged.machineState === "overdue" && rest.judged.state === "active", `break glass at rest: shown as active (machine ${rest.judged.machineState}, shown ${rest.judged.state})`);
  check(rest.opened === null, "break glass at rest: nothing opens");
  const claimed = await open("break glass claimed", { kind: "breakGlass", policy: glass, claimAt: 3600 }, t0 + 3 + 3600 + 5);
  check(claimed.judged.state === "claimOpen", `break glass claimed: open for taps at once (got ${claimed.judged.state})`);
  const ownerOpened = await open("break glass, owner checks in", { kind: "breakGlass", policy: glass, claimAt: 3600, checkInAfter: 3600 + 30 }, t0 + 3 + 3600 + 60);
  check(ownerOpened.judged.state === "claimOpen", `break glass: the owner's check-in does not stop it (got ${ownerOpened.judged.state})`);
  const quiet = await open("quiet rule, owner checks in", { kind: "quiet", policy: { silenceDays: 7, warningDays: 2, graceDays: 0, threshold: 2 }, claimAt: 8 * DAY, checkInAfter: 8 * DAY + 30 }, t0 + 3 + 8 * DAY + 60);
  check(quiet.judged.state === "cancelled", `a 7 day quiet rule: the owner's check-in still stops it (got ${quiet.judged.state})`);
}

for (const f of failures) console.log(`FAIL ${f}`);
console.log(`${checks} checks, ${failures.length} failures`);
process.exit(failures.length ? 1 : 0);
