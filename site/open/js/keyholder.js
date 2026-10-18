// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  keyholder.js
//
//  WHAT A KEY HOLDER DOES, FROM A BROWSER (PRODUCT.md section 15, 1.2b).
//  Ports of EstateEngine's key holder half: confirmCustody, openClaim,
//  object, authorize (the tap) and release (the combine), with the same
//  guards in the same order. Each one builds an entry signed by this
//  person's own device key (signer.js), hands it to the relay, and then
//  reads Apple's copy back before it says anything was saved.
//
//  Nothing here can do what the phone would refuse: the guards are the
//  ported ReleaseMachine checks (release.js), and every phone checks the
//  entry again for itself when it arrives.

import { utf8, framed, sha256, same, toB64 } from "./bytes.js";
import { fromUtf8 } from "./bytes.js";
import { estateAAD, hybridOpenAny, hybridWrapToAll, parseShare, shamirCombine } from "./crypto.js";
import { releaseChallenge, parseEvent } from "./estatelog.js";
import { verifiedDevices } from "./identity.js";
import { custodianCanClaim, custodianCanAuthorize, claimantCanRelease } from "./release.js";
import { makeEvent, headDigest, newID, tapKey } from "./signer.js";
import { decodeJSONBytes, obj, arr, str, int, uint, uint8, data, hybridEnvelopeStrict } from "./schema.js";
import { bytesField } from "./cloudkit.js";
import { names } from "./estate.js";

const fail = (line) => { throw new Error(line); };

/** CustodyConfirmation.challenge */
export const custodyChallenge = (estateID, epoch, recordHeadDigest) =>
  sha256(framed("seal.custody.confirm.v1", [utf8(estateID), utf8(String(epoch)), recordHeadDigest]));

/** ReleaseChallenge.shareAAD */
export const shareAAD = (estateID, epoch, claimID) => utf8(`seal.release.share.v1|${estateID}|${epoch}|${claimID}`);

const epochMaterialShape = obj({
  estateID: str,
  epoch: uint,
  threshold: int,
  custodianShares: arr(obj({ custodianHash: str, shareIndex: uint8, envelopes: arr(hybridEnvelopeStrict), commitment: data })),
  estateKeyCommitment: data,
});

/**
 * EstateEngine.epochMaterial: the key material blob, checked against the
 * owner's signed epoch statement before a byte of it is trusted.
 */
export async function epochMaterial(ck, judged) {
  const epoch = judged.epoch ?? fail("This estate has no key set yet.");
  const record = await ck.record(`est.${judged.estateID}.epoch.${epoch.epoch}`, ["blob"]);
  const bytes = (record && await ck.asset(record, "blob")) ?? fail("The key material for this estate is not available yet.");
  const material = decodeJSONBytes(epochMaterialShape, bytes);
  const ok = material
    && same(await sha256(bytes), epoch.materialDigest)
    && material.custodianShares.length === epoch.shareCommitments.length
    && material.custodianShares.every((s, i) => same(s.commitment, epoch.shareCommitments[i]))
    && same(material.estateKeyCommitment, epoch.estateKeyCommitment);
  if (!ok) fail("The key material does not match what the writer signed. Do not go on.");
  return material;
}

/** EstateKeyHierarchy.openMyShare */
export async function openMyShare(material, myHash, kems) {
  const slot = material.custodianShares.find((s) => s.custodianHash === myHash) ?? fail("You do not hold a piece of this key.");
  const aad = estateAAD(material.estateID, material.epoch, `share.${slot.shareIndex}`);
  let encoded = null;
  for (const kem of kems) {
    try { encoded = await hybridOpenAny(slot.envelopes, kem, aad); break; } catch { /* next device */ }
  }
  const share = parseShare(encoded);
  if (!share || share.index !== slot.shareIndex || !same(await sha256(share.encoded), slot.commitment)) {
    fail("Your piece of the key did not open on this page. If the writer sealed before you had this key, they need to seal again.");
  }
  return share;
}

/** The current claim's claimant's devices, through the pinned directory (kemBundles(of:)). */
async function claimantBundles(judged, claimantHash) {
  const entry = judged.directory?.get(claimantHash) ?? fail("The person who started the claim could not be checked.");
  const bundles = (await verifiedDevices(entry.root, entry.endorsements)).map((d) => d.kemBundlePublicKeys);
  if (!bundles.length) fail("The person who started the claim has no device to send your piece to.");
  return bundles;
}

const lastHeartbeat = (events) => {
  let best = null;
  for (const e of events) if (e.kind === "heartbeat" && (!best || e.occurredAtEpoch > best.occurredAtEpoch)) best = e;
  return best;
};

/**
 * Builds the entry for one action, with the phone's guards. `me` is
 * { hash, credentialID, signer, kems }. Returns { event, wire }.
 */
export async function buildAction(action, { ck, judged, me, now, reason = "", note = "", rpId }) {
  const { estateID, snapshot: s, events = [], epoch } = judged;
  const isCustodian = !!epoch?.custodianHashes.includes(me.hash);
  const head = headDigest(events);
  const make = (kind, body) => makeEvent({ kind, estateID, actorHash: me.hash, signer: me.signer, previousDigest: head, body, now });
  const notCancelled = () => { if (!judged.openingAllowed) fail("The writer cancelled these envelopes when they deleted their Seal account. Nothing can open them."); };

  switch (action) {
    case "confirmCustody": {
      if (!isCustodian) fail("You do not hold a key for this estate.");
      const challenge = await custodyChallenge(estateID, epoch.epoch, head);
      const assertion = await tapKey(me.credentialID, challenge, rpId);
      return make("custodyConfirmed", { epoch: epoch.epoch, recordHeadDigest: head, assertion });
    }
    case "claim": {
      notCancelled();
      if (!isCustodian || !s) fail("You are not a key holder for this estate.");
      if (!custodianCanClaim(s, now)) fail("A claim can only start once the writer has been silent for the full period.");
      const hb = lastHeartbeat(events);
      return make("releaseClaimed", { claimID: newID(), epoch: epoch.epoch, lastHeartbeatAtEpoch: hb ? hb.occurredAtEpoch : null, reason });
    }
    case "object":
    case "withdraw": {
      if (!isCustodian || !s?.claim) fail("There is no claim to object to.");
      return make(action === "withdraw" ? "objectionWithdrawn" : "objection", { claimID: s.claim.id, withdrawn: action === "withdraw", note });
    }
    case "tap": {
      notCancelled();
      if (!isCustodian || !s?.claim) fail("There is no open claim on this estate.");
      if (!custodianCanAuthorize(s, now, me.hash)) fail("The claim is not open for keys yet, or you have already tapped.");
      const claim = s.claim;
      const share = await openMyShare(await epochMaterial(ck, judged), me.hash, me.kems);
      const wrapped = await hybridWrapToAll(share.encoded, await claimantBundles(judged, claim.claimantHash), shareAAD(estateID, epoch.epoch, claim.id));
      const challenge = await releaseChallenge(estateID, epoch.epoch, claim.id, head);
      const assertion = await tapKey(me.credentialID, challenge, rpId);
      return make("authorization", { claimID: claim.id, epoch: epoch.epoch, recordHeadDigest: head, assertion, shareForClaimant: wrapped });
    }
    case "release": {
      notCancelled();
      if (!s?.claim || s.claim.claimantHash !== me.hash) fail("Only the key holder who started the claim can combine the keys.");
      if (!claimantCanRelease(s, now)) fail("Not enough key holders have tapped yet.");
      const claim = s.claim;
      const material = await epochMaterial(ck, judged);
      const aad = shareAAD(estateID, epoch.epoch, claim.id);
      const shares = [];
      // Taps on this claim, already checked against each key holder's pinned
      // key when the record was admitted (EstateLogVerifier, audit C1).
      for (const e of events) {
        if (e.kind !== "authorization" || !e.body || e.body.claimID !== claim.id || e.body.epoch !== epoch.epoch) continue;
        for (const kem of me.kems) {
          try {
            const share = parseShare(await hybridOpenAny(e.body.shareForClaimant, kem, aad));
            if (share) { shares.push(share); break; }
          } catch { /* not wrapped to this device */ }
        }
      }
      try {
        const own = await openMyShare(material, me.hash, me.kems);
        if (!shares.some((x) => x.index === own.index)) shares.push(own);
      } catch { /* the claimant need not hold a piece */ }
      // A share that does not match its slot's commitment is dropped, not fatal.
      const good = [];
      for (const sh of shares) {
        const slot = material.custodianShares.find((x) => x.shareIndex === sh.index);
        if (slot && same(await sha256(sh.encoded), slot.commitment) && !good.some((g) => g.index === sh.index)) good.push(sh);
      }
      if (good.length < material.threshold) fail(`Only ${good.length} of the ${material.threshold} pieces needed opened here.`);
      const estateKey = shamirCombine(good, material.threshold);
      if (!same(await sha256(estateKey), material.estateKeyCommitment)) fail("The pieces did not rebuild the writer's key. Nothing was released.");
      const shareIndexes = [...new Set(good.map((g) => g.index))].sort((a, b) => a - b);
      return make("released", { claimID: claim.id, epoch: epoch.epoch, shareIndexes, estateKey });
    }
    default:
      fail("Unknown action.");
  }
}

/**
 * Hands a signed entry to the relay, then reads Apple's copy back. The
 * relay can fail to deliver, or later delete what it delivered, but it
 * cannot forge or change an entry: the page only says "saved" once the
 * entry Apple holds is byte for byte the one signed here.
 */
export async function publish(ck, { event, wire }, { relayURL = "/relay/event", tries = 6, wait = 1500, fetchImpl = fetch, sleep } = {}) {
  const res = await fetchImpl(relayURL, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=UTF-8" },
    body: JSON.stringify({ event: wire }),
    credentials: "omit",
    cache: "no-store",
  });
  const answer = await res.json().catch(() => null);
  if (!res.ok || !answer?.ok) fail(answer?.message ?? `The relay did not take it (HTTP ${res.status}). Nothing was saved.`);
  const pause = sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
  for (let i = 0; i < tries; i++) {
    const record = await ck.record(names.event(event.estateID, event.id)).catch(() => null);
    const payload = record && bytesField(record, "payload");
    const back = payload && await parseEvent(payload);
    if (back && back.id === event.id && same(back.digest, event.digest) && same(back.signature, event.signature)) {
      return { saved: true, stamped: !!back.timestampToken };
    }
    await pause(wait);
  }
  fail("The relay said it saved this, but Apple's copy could not be found. Try again, or use the iPhone app.");
}

export { toB64, fromUtf8 };
