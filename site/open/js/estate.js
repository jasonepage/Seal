// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  estate.js
//
//  What the recipient page does after the security key is unlocked, in
//  the order the phone does it (EstateEngine: refreshGuarded, refresh,
//  openEnvelopes, openMedia):
//
//    1. find the estates that named this person, from the invites wrapped
//       to their devices;
//    2. for each, fetch the signed record, believe only what the owner's
//       and the key holders' endorsed devices signed, and judge the
//       release exactly as the phone does (release.js);
//    3. only after a release judged earned, and whose key matches the
//       owner's own signed commitment, open the key tables and find the one
//       that is this person's.
//
//  Nothing here is stored. Everything lives in memory and is gone when the
//  tab closes.

import { utf8, fromUtf8, sha256, same } from "./bytes.js";
import { CloudKit, bytesField, stringField, modifiedAt } from "./cloudkit.js";
import { hybridOpenAny, openTableAsRecipient, parseTableWrap, openContent } from "./crypto.js";
import { parseEvent, admitted, newest } from "./estatelog.js";
import { identityFromRecord } from "./identity.js";
import { pageTimes, snapshot, state, timeline, policyWith, openingAllowed } from "./release.js";
import { estateInvite, keyTable, envelopePayload, decodeJSONBytes, tryDecode, obj, arr, hybridEnvelopeStrict } from "./schema.js";

/** Swift's Date.distantPast, in seconds since 1970. The phone's estateCreatedAt for a guarded estate. */
const DISTANT_PAST = -62135769600;
const INVITE_AAD = utf8("seal.estate.invite.v1");
const DELETED_TIER = "deleted";

export const names = {
  event: (estateID, eventID) => `eev.${estateID}.${eventID}`,
  table: (estateID, tableID) => `est.${estateID}.table.${tableID}`,
  content: (estateID, blobID) => `est.${estateID}.blob.${blobID}`,
};

const IDENTITY_KEYS = ["publicKey", "tier", "displayName", "deviceEndorsements", "credentialID", "revocations", "backupEndorsements"];

function identityFields(record) {
  return {
    publicKey: bytesField(record, "publicKey"),
    tier: stringField(record, "tier"),
    displayName: stringField(record, "displayName"),
    deviceEndorsements: bytesField(record, "deviceEndorsements"),
    credentialID: bytesField(record, "credentialID") ?? undefined,
    revocations: bytesField(record, "revocations") ?? undefined,
    backupEndorsements: bytesField(record, "backupEndorsements") ?? undefined,
  };
}

async function sideRevocations(ck, hash) {
  const records = await ck.query("GroupInvite", "recipient", `revoke.${hash}`, { desiredKeys: ["payload"] });
  return records.map((r) => bytesField(r, "payload")).filter(Boolean);
}

/**
 * SyncEngine.fetchIdentity, without the pin (the page has none; see
 * `pinnedKey`). With `history`, a deleted identity is still read, the way
 * the phone reads an owner who left (fetchIdentityForHistory): the record
 * only supplies the device list the key signed.
 */
export async function fetchIdentity(ck, hash, { pinnedKey = null, history = false } = {}) {
  const record = await ck.record(hash, IDENTITY_KEYS);
  if (!record) return null;
  const fields = identityFields(record);
  if (!fields.publicKey) return null;
  if (pinnedKey && !same(pinnedKey, fields.publicKey)) return null;
  const revs = await sideRevocations(ck, hash);
  if (fields.tier === DELETED_TIER) {
    if (!history || !fields.deviceEndorsements?.length) return null;
    // The tier string is the deleted sentinel, not a real tier, and the
    // phone reads no backups for history. Nothing else changes.
    return identityFromRecord({ ...fields, tier: "verified", backupEndorsements: undefined }, revs, hash);
  }
  return identityFromRecord(fields, revs, hash);
}

/** Every estate invite addressed to this person that their devices open (SyncEngine.fetchEstateInvites). */
export async function findInvites(ck, myHash, kems) {
  const records = await ck.query("GroupInvite", "recipient", myHash, { desiredKeys: ["payload"] });
  const found = [];
  for (const r of records) {
    const payload = bytesField(r, "payload");
    const wire = payload && decodeJSONBytes(obj({ estateInvite: arr(hybridEnvelopeStrict) }), payload);
    if (!wire) continue;
    for (const kem of kems) {
      let plain;
      try { plain = await hybridOpenAny(wire.estateInvite, kem, INVITE_AAD); } catch { continue; }
      const invite = decodeJSONBytes(estateInvite, plain);
      if (invite && !found.some((f) => f.estateID === invite.estateID && f.role === invite.role)) found.push(invite);
      break;
    }
  }
  return found;
}

/** SyncEngine.fetchEstateEvents, plus Apple's modification time on each record. */
async function fetchEvents(ck, estateID, now) {
  const records = await ck.query("EstateEvent", "estate", estateID, { maxPages: 100 });
  const events = [];
  for (const r of records) {
    const payload = bytesField(r, "payload");
    const e = payload && await parseEvent(payload);
    // An event counts only from the record named for it (audit C1 review).
    if (!e || e.estateID !== estateID || r.recordName !== names.event(estateID, e.id)) continue;
    // No server time means no floor to trust, so the strictest one: now.
    e.modifiedAt = modifiedAt(r) ?? now;
    events.push(e);
  }
  return events;
}

/**
 * Judge one estate (EstateEngine.refresh, then the snapshot). Returns
 * { estateID, ownerName, ownerHash, state, snapshot, timeline, events,
 *   epoch, vault, openingAllowed, problem }.
 */
export async function judgeEstate(ck, invite, now) {
  const { estateID, ownerHash } = invite;
  const out = { estateID, ownerHash, ownerName: invite.ownerName, problem: null };
  const fetched = await fetchEvents(ck, estateID, now);

  // The owner first: their events are what everything else hangs from.
  const directory = new Map();
  const owner = await fetchIdentity(ck, ownerHash, { history: true });
  if (!owner) { out.problem = "owner"; out.state = "unknown"; return out; }
  directory.set(ownerHash, owner);
  const ownerOnly = await admitted(fetched, ownerHash, new Set(), directory);

  // The newest epoch statement names the key holders and their keys. As on
  // the phone, an undecodable newest statement means no statement.
  const epochEvent = newest(ownerOnly.filter((e) => e.kind === "epochPublished"));
  const epoch = epochEvent?.body ?? null;
  const vaultEvent = newest(ownerOnly.filter((e) => e.kind === "vaultUpdated"));
  const vault = vaultEvent?.body ?? null;

  const custodianHashes = new Set(epoch?.custodianHashes ?? []);
  if (epoch) {
    for (let i = 0; i < epoch.custodianHashes.length; i++) {
      const hash = epoch.custodianHashes[i];
      // The owner's signed statement is the pin: a directory that serves a
      // different key for a key holder gets no say (KeyPinStore on the phone).
      const pinnedKey = epoch.custodianPublicKeys[i] ?? null;
      const found = pinnedKey ? await fetchIdentity(ck, hash, { pinnedKey }).catch(() => null) : null;
      if (found) directory.set(hash, found);
    }
  }
  const events = await admitted(fetched, ownerHash, custodianHashes, directory);
  out.events = events;
  out.epoch = epoch;
  out.vault = vault;
  out.openingAllowed = await openingAllowed(events, ownerHash);
  if (!events.length) { out.state = "waiting"; return out; }

  const times = await pageTimes(events);
  const policy = policyWith(epoch ? epoch.threshold : 1);
  const snap = await snapshot(events, ownerHash, policy, DISTANT_PAST, times);
  out.snapshot = snap;
  out.state = state(snap, now);
  out.timeline = timeline(snap, now);
  return out;
}

/**
 * EstateEngine.openEnvelopes: after a judged release, the published Estate
 * Key plus this person's own KEM keys open their table, and only theirs.
 * Throws with a plain sentence when it cannot.
 */
export async function openEstate(ck, judged, kems, now) {
  const { estateID, ownerHash, snapshot: s, events } = judged;
  if (!judged.openingAllowed) throw new Error("These envelopes were cancelled when their writer deleted their Seal account. They can never be opened.");
  if (!s || s.releasedAt === null || s.releasedAt > now || !s.releaseEventID) throw new Error("These envelopes are still sealed.");
  const released = events.find((e) => e.id === s.releaseEventID && e.kind === "released")?.body;
  if (!released) throw new Error("These envelopes are still sealed.");
  // The key against the owner's own signed commitment, before a single table is tried.
  const keyHash = await sha256(released.estateKey);
  const matches = events.some((e) => e.kind === "epochPublished" && e.actorHash === ownerHash && e.body
    && e.body.epoch === released.epoch && same(e.body.estateKeyCommitment, keyHash));
  if (!matches) throw new Error("The published key does not match what the writer sealed. Nothing was opened.");

  const opened = [];
  for (const tableID of judged.vault?.tableIDs ?? []) {
    const record = await ck.record(names.table(estateID, tableID), ["blob"]);
    const bytes = record && await ck.asset(record, "blob");
    if (!bytes) continue;
    let wrap;
    try { wrap = parseTableWrap(fromUtf8(bytes)); } catch { continue; }
    let table = null;
    for (const kem of kems) {
      try { table = tryDecode(keyTable, await openTableAsRecipient(wrap, estateID, released.estateKey, kem)); } catch { /* not mine */ }
      if (table) break;
    }
    if (!table) continue;
    for (const entry of [...table.entries].sort((a, b) => a.revealOrder - b.revealOrder)) {
      const payloadID = entry.blobIDs[0];
      if (!payloadID) continue;
      const blobRecord = await ck.record(names.content(estateID, payloadID), ["blob"]);
      const blob = blobRecord && await ck.asset(blobRecord, "blob");
      if (!blob) continue;
      const plain = await openContent(blob, entry.contentKey, estateID, payloadID);
      const payload = decodeJSONBytes(envelopePayload, plain);
      if (!payload) throw new Error("An envelope did not read correctly. Nothing was changed.");
      opened.push({ entry, payload });
    }
  }
  return opened;
}

/** EstateEngine.openMedia: fetch, open, and check against the hash the owner sealed. */
export async function openMedia(ck, estateID, entry, item) {
  const record = await ck.record(names.content(estateID, item.blobID), ["blob"]);
  const blob = record && await ck.asset(record, "blob");
  if (!blob) throw new Error("That file is not available.");
  const plain = await openContent(blob, entry.contentKey, estateID, item.blobID);
  if (!same(await sha256(plain), item.sha256)) throw new Error("That file does not match what the writer sealed.");
  return plain;
}

export { CloudKit };
