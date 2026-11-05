// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  passon.test.mjs
//
//  Passing a key on (PRODUCT.md section 18): the saved copy of a letter,
//  the held-letter rule, the ownership proof, and the check before a key
//  is cleared. Every unknown must refuse.
//
//      node tools/webtests/passon.test.mjs

import { isHeld, letterFile, letterFileName, ownerProven, passOnPlan } from "../../site/open/js/passon.js";

let checks = 0;
const failures = [];
const check = (ok, name) => { checks++; if (!ok) failures.push(name); };

const NOW = 1_800_000_000;
const payload = (over = {}) => ({
  title: "For Sam", letter: "You were the first person I told.\nKeep going.",
  firstSteps: [{ title: "Call Ana", note: "she knows" }, { title: "  ", note: "" }],
  photos: [], voiceNote: null, videoNote: null, files: [], openNoEarlierThanEpoch: null,
  secrets: [{ title: "Alarm", value: "SECRET-4471-DO-NOT-LEAK", cardType: "password" }],
  ...over,
});
const env = (over) => ({ entry: {}, payload: payload(over) });

// ---- held: the exact boundary, and anything odd counts as held
check(isHeld(payload(), NOW) === false, "held: no date is open");
check(isHeld(payload({ openNoEarlierThanEpoch: NOW + 1 }), NOW) === true, "held: one second before is held");
check(isHeld(payload({ openNoEarlierThanEpoch: NOW }), NOW) === false, "held: at the exact second it opens, as the page shows it");
check(isHeld(payload({ openNoEarlierThanEpoch: NOW - 1 }), NOW) === false, "held: after is open");
check(isHeld(payload({ openNoEarlierThanEpoch: "soon" }), NOW) === true, "held: a date that is not a number counts as held");
check(isHeld(payload({ openNoEarlierThanEpoch: NaN }), NOW) === true, "held: NaN counts as held");

// ---- the file: secrets never, held envelopes never, not even the title
const text = letterFile("Ana", [env()], NOW);
check(text.includes("Letters from Ana") && text.includes("For Sam"), "file: writer and title");
check(text.includes("You were the first person I told.\nKeep going."), "file: the letter as written");
check(text.includes("1. Call Ana (she knows)") && !text.includes("2. "), "file: steps, empty ones left out");
check(!text.includes("SECRET-4471") && !text.includes("Alarm"), "file: never a secret, value or title");
check(text.includes("Secrets are not in this file"), "file: says secrets were left out");

const withHeld = letterFile("Ana", [
  env({ title: "Open now", letter: "Hello now." }),
  env({ title: "Birthday 18", letter: "HELD-LETTER-TEXT", firstSteps: [{ title: "HELD-STEP", note: "" }], openNoEarlierThanEpoch: NOW + 86_400 }),
], NOW);
check(withHeld.includes("Open now") && withHeld.includes("Hello now."), "file: the open envelope is in it");
check(!withHeld.includes("HELD-LETTER-TEXT"), "file: a held letter is not in it");
check(!withHeld.includes("Birthday 18"), "file: a held title is not in it");
check(!withHeld.includes("HELD-STEP"), "file: a held step is not in it");
const atBoundary = letterFile("Ana", [env({ title: "Opens today", openNoEarlierThanEpoch: NOW })], NOW);
check(atBoundary.includes("Opens today"), "file: at the exact second it opens, it is in the file");
const media = letterFile("Ana", [env({ secrets: [], photos: [{}, {}], voiceNote: {}, files: [{}] })], NOW);
check(media.includes("Not in this file: 2 photos, a voice message, a file.") && !media.includes("Secrets are not"), "file: names media it leaves out");

// ---- names
check(letterFileName("Ana") === "letters-from-ana.txt", "name: plain");
check(letterFileName("José María") === "letters-from-jose-maria.txt", "name: accents and spaces");
check(letterFileName("../../etc/passwd") === "letters-from-etc-passwd.txt", "name: no path");
check(letterFileName(null) === "letters-from-someone.txt" && letterFileName("!!!") === "letters-from-someone.txt", "name: nothing usable");

// ---- ownership: only one device ever, the sponsored one, and no backups
const dev = Uint8Array.from([4, 1, 2, 3]);
const sponsored = { devicePublicKey: dev, lockedPrivate: Uint8Array.of(9), prfSalt: Uint8Array.of(8) };
const phone = { devicePublicKey: Uint8Array.from([4, 9, 9, 9]), lockedPrivate: null, prfSalt: null };
check(ownerProven({ endorsements: [sponsored], backups: [], sponsoredDevicePublicKey: dev }) === true, "owner: only the sponsored device is proven");
check(ownerProven({ endorsements: [sponsored, phone], backups: [], sponsoredDevicePublicKey: dev }) === false, "owner: a phone ever signed in is not");
check(ownerProven({ endorsements: [phone], backups: [], sponsoredDevicePublicKey: dev }) === false, "owner: a different device is not");
check(ownerProven({ endorsements: [{ ...sponsored, lockedPrivate: null }], backups: [], sponsoredDevicePublicKey: dev }) === false, "owner: a device with no locked halves is not");
check(ownerProven({ endorsements: [sponsored], backups: [{}], sponsoredDevicePublicKey: dev }) === false, "owner: a backup key is not");
check(ownerProven({ endorsements: [sponsored], backups: null, sponsoredDevicePublicKey: dev }) === false, "owner: unreadable backups are not");
check(ownerProven({ endorsements: null, backups: [], sponsoredDevicePublicKey: dev }) === false, "owner: an unreadable device list is not");
check(ownerProven({ endorsements: [], backups: [], sponsoredDevicePublicKey: dev }) === false, "owner: an empty device list is not");

// ---- the plan
const cur = { estateID: "E1", ownerName: "Ana", kind: "rightAway", state: "released", openingAllowed: true, problem: null, roles: new Set(["recipient"]) };
const base = { current: cur, opened: [env()], judged: [cur], inviteEstateIDs: ["E1"], ownerIsProven: true, now: NOW };
const plan = (over) => passOnPlan({ ...base, ...over });

check(plan({}).ok === true, "plan: a clean, open right away letter with ownership proven may be cleared");
check(plan({ ownerIsProven: false }).reason === "owner", "plan: unproven ownership refuses");
check(plan({ opened: [env(), env({ openNoEarlierThanEpoch: NOW + 60 })] }).reason === "held", "plan: a held envelope refuses");
check(plan({ opened: [env({ openNoEarlierThanEpoch: NOW + 60 })] }).until === NOW + 60, "plan: says until when");
check(plan({ opened: [env({ openNoEarlierThanEpoch: NOW })] }).ok === true, "plan: at the exact second it opens, it may be cleared");

const holderActive = { estateID: "E2", ownerName: "Dad", kind: "breakGlass", state: "active", openingAllowed: true, problem: null, roles: new Set(["custodian"]) };
const r1 = plan({ judged: [cur, holderActive], inviteEstateIDs: ["E1", "E2"] });
check(r1.reason === "holder" && r1.names.join() === "Dad", "plan: a live key holder role refuses and says whose");
const holderDone = { ...holderActive, state: "released" };
check(plan({ judged: [cur, holderDone], inviteEstateIDs: ["E1", "E2"] }).ok === true, "plan: a key holder role in a released set is finished");

const otherSealed = { estateID: "E3", ownerName: "Lee", kind: "quiet", state: "active", openingAllowed: true, problem: null, roles: new Set(["recipient"]) };
const r2 = plan({ judged: [cur, otherSealed], inviteEstateIDs: ["E1", "E3"] });
check(r2.reason === "other" && r2.names.join() === "Lee", "plan: another unopened letter refuses");
const otherReleased = { ...otherSealed, kind: "rightAway", state: "released" };
check(plan({ judged: [cur, otherReleased], inviteEstateIDs: ["E1", "E3"] }).reason === "other", "plan: another live letter refuses even if open (the page cannot know it was saved)");
const otherCancelled = { ...otherSealed, openingAllowed: false };
check(plan({ judged: [cur, otherCancelled], inviteEstateIDs: ["E1", "E3"] }).ok === true, "plan: a cancelled set is finished history");

// unknowns all refuse
check(plan({ inviteEstateIDs: null }).reason === "unknown", "unknown: invite list unreadable");
check(plan({ inviteEstateIDs: ["E1", "E9"] }).reason === "unknown", "unknown: an invite for a set the page did not open");
check(plan({ judged: [] }).reason === "unknown", "unknown: the current set is not in the list");
check(plan({ judged: null }).reason === "unknown", "unknown: no list");
check(plan({ opened: [] }).reason === "unknown", "unknown: nothing opened");
check(plan({ current: { ...cur, kind: "quiet" } }).reason === "unknown", "unknown: not a right away set");
check(plan({ current: { ...cur, problem: "owner" } }).reason === "unknown", "unknown: the writer's record did not check out");
check(plan({ judged: [cur, { ...otherSealed, problem: "owner" }], inviteEstateIDs: ["E1", "E3"] }).reason === "unknown", "unknown: another set with a problem");
check(plan({ judged: [cur, { ...otherSealed, roles: new Set() }], inviteEstateIDs: ["E1", "E3"] }).reason === "unknown", "unknown: another set with no role");

if (failures.length) {
  console.log(failures.map((f) => `FAIL ${f}`).join("\n"));
  console.log(`${checks} checks, ${failures.length} failures`);
  process.exit(1);
}
console.log(`${checks} checks, 0 failures`);
