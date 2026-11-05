// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  passon.js
//
//  PASS A KEY ON (PRODUCT.md section 18). A right away letter opens with
//  the key it was written to. The key can then carry a new letter to
//  someone new: the holder saves their letter, frees the key (the web
//  retire in app.js, the same tap and marker as RetireKeyCeremony.swift),
//  and a writer on an iPhone sets the key up again for the next person.
//
//  Pure functions only, so tools/webtests/passon.test.mjs can run them in
//  Node. The page draws the screens; this decides what they say.

/**
 * The saved copy of a person's letters, as plain text. Titles, letters
 * and "what to do first" steps only. Never the secrets: a file sits on a
 * device for years and can be copied anywhere, and the secrets have their
 * own copy buttons. Media is named, not embedded; it has its own Save
 * buttons on the page.
 */
export function letterFile(ownerName, opened) {
  const from = ownerName || "someone";
  const out = [`Letters from ${from}, opened with a Seal key.`, ""];
  for (const { payload } of opened) {
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

/**
 * Whether this key may be freed for the right away estate `estateID`.
 * `judged` is everything the signed-in identity is part of.
 *
 *   { ok: false, holdsFor: [...] }  the key is a key holder for someone.
 *        Freeing it would quietly take a key out of their rule, so the
 *        page refuses and says whose.
 *   { ok: true, alsoFrom: [...] }   allowed. alsoFrom names other writers
 *        whose letters this key opens too; those stop opening as well,
 *        and the page says so before the tap.
 */
export function passOnCheck(judged, estateID) {
  const others = judged.filter((j) => j.estateID !== estateID);
  const holdsFor = others.filter((j) => j.roles?.has("custodian")).map((j) => j.ownerName || "someone");
  if (holdsFor.length) return { ok: false, holdsFor: [...new Set(holdsFor)] };
  const alsoFrom = others.filter((j) => j.roles?.has("recipient")).map((j) => j.ownerName || "someone");
  return { ok: true, alsoFrom: [...new Set(alsoFrom)] };
}
