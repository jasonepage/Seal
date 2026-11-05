// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  passon.test.mjs
//
//  Passing a key on (PRODUCT.md section 18): the saved copy of a letter
//  and the check before a key is freed.
//
//    the file       has the title, the letter and the steps; never a
//                   secret, not even one whose value looks like a letter;
//                   names what it leaves out;
//    the check      refuses a key that is a key holder for anyone else,
//                   allows a key that only opens letters, and names the
//                   other writers whose letters stop opening too;
//    the name       is a plain, safe file name.
//
//      node tools/webtests/passon.test.mjs

import { letterFile, letterFileName, passOnCheck } from "../../site/open/js/passon.js";

let checks = 0;
const failures = [];
const check = (ok, name) => { checks++; if (!ok) failures.push(name); };

const payload = (over = {}) => ({
  title: "For Sam", letter: "You were the first person I told.\nKeep going.",
  firstSteps: [{ title: "Call Ana", note: "she knows" }, { title: "  ", note: "" }],
  photos: [], voiceNote: null, videoNote: null, files: [],
  secrets: [{ title: "Alarm", value: "SECRET-4471-DO-NOT-LEAK", cardType: "password" }],
  ...over,
});

// ---- the file
const text = letterFile("Ana", [{ entry: {}, payload: payload() }]);
check(text.includes("Letters from Ana"), "file: names the writer");
check(text.includes("For Sam"), "file: has the title");
check(text.includes("You were the first person I told.\nKeep going."), "file: has the letter as written");
check(text.includes("1. Call Ana (she knows)"), "file: has the steps");
check(!text.includes("2. "), "file: an empty step is left out");
check(!text.includes("SECRET-4471"), "file: never a secret value");
check(!text.includes("Alarm"), "file: never a secret title");
check(text.includes("Secrets are not in this file"), "file: says secrets were left out");

const media = letterFile("Ana", [{ entry: {}, payload: payload({ secrets: [], photos: [{}, {}], voiceNote: {}, files: [{}] }) }]);
check(media.includes("Not in this file: 2 photos, a voice message, a file."), "file: names the media it leaves out");
check(!media.includes("Secrets are not in this file"), "file: no secrets line when there are none");

const two = letterFile(null, [{ entry: {}, payload: payload({ title: "" }) }, { entry: {}, payload: payload({ title: "Second" }) }]);
check(two.includes("Letters from someone"), "file: an unnamed writer reads as someone");
check(two.includes("An envelope") && two.includes("Second"), "file: every opened envelope is in it");

// ---- the check
const mine = { estateID: "E1", ownerName: "Ana", roles: new Set(["recipient"]) };
check(passOnCheck([mine], "E1").ok === true, "check: a key that only opens this letter may be freed");
check(passOnCheck([mine], "E1").alsoFrom.length === 0, "check: nothing else stops opening");

const holder = { estateID: "E2", ownerName: "Dad", roles: new Set(["custodian"]) };
const refused = passOnCheck([mine, holder], "E1");
check(refused.ok === false, "check: refused when the key is a key holder for someone");
check(refused.holdsFor.join() === "Dad", "check: says whose key it is");

const both = { estateID: "E3", ownerName: "Mom", roles: new Set(["recipient", "custodian"]) };
check(passOnCheck([mine, both], "E1").ok === false, "check: refused when the key is both recipient and key holder elsewhere");

const other = { estateID: "E4", ownerName: "Lee", roles: new Set(["recipient"]) };
const warned = passOnCheck([mine, other, { ...other, estateID: "E5" }], "E1");
check(warned.ok === true, "check: other letters do not block it");
check(warned.alsoFrom.join() === "Lee", "check: names each other writer once");

check(passOnCheck([], "E1").ok === true, "check: an empty list is allowed (nothing else to protect)");

// ---- the name
check(letterFileName("Ana") === "letters-from-ana.txt", "name: plain");
check(letterFileName("José María") === "letters-from-jose-maria.txt", "name: accents and spaces");
check(letterFileName("../../etc/passwd") === "letters-from-etc-passwd.txt", "name: no path");
check(letterFileName("") === "letters-from-someone.txt" && letterFileName(null) === "letters-from-someone.txt", "name: no name");
check(letterFileName("!!!") === "letters-from-someone.txt", "name: nothing usable");

if (failures.length) {
  console.log(failures.map((f) => `FAIL ${f}`).join("\n"));
  console.log(`${checks} checks, ${failures.length} failures`);
  process.exit(1);
}
console.log(`${checks} checks, 0 failures`);
