// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  passon.js
//
//  PASS A KEY ON (PRODUCT.md section 18). One physical key carries one live
//  letter relationship at a time: sponsored identity A opens its right away
//  letter, the holder saves it, A is retired, and the same key is set up on
//  an iPhone as sponsored identity B for the next person. The old envelope
//  is never resealed.
//
//  The rule: a key may be cleared only when the identity on it has no
//  unfinished obligations, AND the page can prove that. Anything it cannot
//  prove fails closed.
//
//  Pure functions only, so tools/webtests/passon.test.mjs can run them in
//  Node. The page gathers the facts; this decides.

/**
 * Whether an envelope is still held for a later date. The same test the
 * page uses to keep it closed (app.js envelopes), with one difference: a
 * date that is not a plain number counts as held, because guessing wrong
 * here would show a letter early.
 */
export function isHeld(payload, now) {
  const t = payload?.openNoEarlierThanEpoch;
  if (t === null || t === undefined) return false;
  if (typeof t !== "number" || !Number.isFinite(t)) return true;
  return now < t;
}

/**
 * The saved copy of a person's letters, as plain text: titles, letters and
 * "what to do first" steps. Never the secrets: a file sits on a device for
 * years and copies anywhere, and the secrets have their own copy buttons.
 * Never a held envelope, not even its title: the file must not open early
 * what the page keeps closed. Media is named, not embedded.
 */
export function letterFile(ownerName, opened, now) {
  const from = ownerName || "someone";
  const out = [`Letters from ${from}, opened with a Seal key.`, ""];
  for (const { payload } of opened) {
    if (isHeld(payload, now)) continue;
    out.push(payload.title || "An envelope");
    out.push("");
    if (payload.letter?.trim()) { out.push(payload.letter.trim()); out.push(""); }
    const steps = (payload.firstSteps ?? []).filter((s) => s.title?.trim() || s.note?.trim());
    if (steps.length) {
      out.push("What to do first");
      steps.forEach((s, i) => out.push(`${i + 1}. ${(s.title ?? "").trim()}${s.note?.trim() ? ` (${s.note.trim()})` : ""}`));
      out.push("");
    }
    const extras = [];
    if (payload.photos?.length) extras.push(payload.photos.length === 1 ? "a photo" : `${payload.photos.length} photos`);
    if (payload.voiceNote) extras.push("a voice message");
    if (payload.videoNote) extras.push("a video");
    if (payload.files?.length) extras.push(payload.files.length === 1 ? "a file" : `${payload.files.length} files`);
    if (extras.length) { out.push(`Not in this file: ${extras.join(", ")}. Save them from the page.`); out.push(""); }
    if (payload.secrets?.length) { out.push("Secrets are not in this file. Copy them from the page if you need them."); out.push(""); }
    out.push("----");
    out.push("");
  }
  return out.join("\n");
}

/** A plain file name: letters-from-ana.txt. */
export function letterFileName(ownerName) {
  const slug = (ownerName || "someone").normalize("NFKD").replace(/\p{M}+/gu, "").replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-+|-+$/g, "").toLowerCase().slice(0, 40) || "someone";
  return `letters-from-${slug}.txt`;
}

const sameBytes = (a, b) => a instanceof Uint8Array && b instanceof Uint8Array
  && a.length === b.length && a.every((x, i) => x === b[i]);

/**
 * Whether this identity provably owns no envelope set of its own.
 *
 * The web cannot list the sets an identity owns: the app keeps that list in
 * the owner's private iCloud database (OwnedSets.swift), EstateEvent is
 * queryable only by `estate` (CLOUDKIT_DEPLOY.md), and invites name
 * recipients and key holders, never owners. So this proves it the other
 * way round. Owner entries are signed only by a phone's Secure Enclave
 * device key (EstateEventBuilder.make), the relay refuses owner kinds
 * (worker/index.js), and every phone an identity signs in on is added to
 * its own record's device list (SyncEngine.publishIdentity). An identity
 * whose record has ever listed exactly one device, the sponsored one on
 * this key, and no backup keys, has never had a device that could sign an
 * owner entry anyone would accept.
 *
 *   endorsements  the RAW device list from the record, revoked ones
 *                 included, or null when it could not be read
 *   backups       [] when the record has no backup field, the parsed list
 *                 when it has one, null when it could not be read
 */
export function ownerProven({ endorsements, backups, sponsoredDevicePublicKey }) {
  if (!Array.isArray(endorsements) || endorsements.length !== 1) return false;
  if (!Array.isArray(backups) || backups.length !== 0) return false;
  const only = endorsements[0];
  return !!only && sameBytes(only.devicePublicKey, sponsoredDevicePublicKey)
    && only.lockedPrivate instanceof Uint8Array && only.prfSalt instanceof Uint8Array;
}

/**
 * Whether the key may be cleared from the current right away set.
 *
 *   current        the judged set whose letter was just opened
 *   opened         its decrypted envelopes [{ payload }]
 *   judged         every set this identity's invites opened (session.judged)
 *   inviteEstateIDs  every set named by an invite record addressed to this
 *                  identity (estinv.<hash>.<set>), read raw, or null when the
 *                  list could not be read whole. Every one must be a set the
 *                  page opened. A record the page could not open, or junk a
 *                  stranger wrote, blocks: it might be a letter not yet seen.
 *   ownerIsProven  ownerProven(...)
 *
 * Returns { ok: true } or { ok: false, reason, names?, until? }, reasons:
 *   unknown  something could not be checked
 *   owner    the page cannot prove this identity owns no set
 *   held     an envelope here is still closed until `until`
 *   holder   this identity is a key holder for a set not yet released
 *   other    this identity is a recipient in another live set
 */
export function passOnPlan({ current, opened, judged, inviteEstateIDs, ownerIsProven, now }) {
  const no = (reason, extra = {}) => ({ ok: false, reason, ...extra });
  if (!current || current.kind !== "rightAway" || current.state !== "released"
    || !current.openingAllowed || current.problem || !current.estateID) return no("unknown");
  if (!Array.isArray(opened) || opened.length === 0) return no("unknown");
  if (!Array.isArray(judged) || !judged.some((j) => j?.estateID === current.estateID)) return no("unknown");
  if (!ownerIsProven) return no("owner");
  if (!Array.isArray(inviteEstateIDs)) return no("unknown");
  const known = new Set(judged.map((j) => j?.estateID));
  if (inviteEstateIDs.some((id) => !known.has(id))) return no("unknown");

  const held = opened.filter(({ payload }) => isHeld(payload, now));
  if (held.length) {
    const dates = held.map(({ payload }) => payload.openNoEarlierThanEpoch).filter((t) => typeof t === "number");
    return no("held", { until: dates.length ? Math.max(...dates) : null });
  }

  const holdsFor = [], alsoFrom = [];
  for (const j of judged) {
    if (j.estateID === current.estateID) continue;
    if (j.openingAllowed === false) continue;   // cancelled for good: nothing left to lose or protect
    if (j.problem || !(j.roles instanceof Set) || j.roles.size === 0) return no("unknown");
    const name = j.ownerName || "someone";
    if (j.roles.has("custodian") && j.state !== "released") holdsFor.push(name);
    if (j.roles.has("recipient")) alsoFrom.push(name);
  }
  if (holdsFor.length) return no("holder", { names: [...new Set(holdsFor)] });
  if (alsoFrom.length) return no("other", { names: [...new Set(alsoFrom)] });
  return { ok: true };
}
