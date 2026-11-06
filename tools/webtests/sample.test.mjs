// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  sample.test.mjs
//
// The sample letter on /open/#sample: plain data, clearly a sample, and in
// the same shape the real reveal reads. Run by run.sh.
import { SAMPLE } from "../../site/open/js/sample.js";

let failures = 0, checks = 0;
const check = (ok, what) => { checks++; if (!ok) { failures++; console.log("FAIL " + what); } };

check(Object.isFrozen(SAMPLE), "the sample cannot be changed at run time");
check(/sample/i.test(SAMPLE.letter), "the letter says it is a sample");
check(SAMPLE.secrets.every((s) => typeof s.title === "string" && typeof s.value === "string" && s.cardType), "secret cards have the fields secretBlock reads");
check(SAMPLE.secrets.some((s) => /sample|not a real|not-a-real/i.test(s.value + " " + s.note)), "a secret says it is not real");
check(Array.isArray(SAMPLE.steps) && SAMPLE.steps.every((s) => typeof s.title === "string" && typeof s.note === "string"), "steps have title and note");
check(SAMPLE.photo.src.startsWith("../") && !/^https?:/.test(SAMPLE.photo.src), "the photo is our own file, allowed by img-src 'self'");
const all = JSON.stringify(SAMPLE);
check(!all.includes("—"), "no em dashes");
check(!/\bNFC\b|tap your key|hold the key/i.test(all), "keys are plugged in, never tapped");

console.log(`sample: ${checks} checks, ${failures} failures`);
if (failures) process.exit(1);
