// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  tools/vectors/live-check.mjs
//
//  THE PAGE'S CHECKS AGAINST REAL DATA THE PHONES WROTE. Reads the public
//  CloudKit database (read only, the same way the recipient page does) and
//  runs the page's own code over it:
//
//    - every identity in the directory: do the page's WebAuthn and
//      endorsement checks accept the device endorsements the phones made?
//    - with --estate <id>: does every event's digest and signature check
//      out in JavaScript, and do the timestamp tokens verify?
//
//  A phone-made endorsement or event that the page refuses means the page
//  is wrong, not the phone. Nothing here can write anything.
//
//      node tools/vectors/live-check.mjs <CloudKit API token> [--estate <estateID>]...
//
//  The token is the same public, read-only token the page carries.

import { CloudKit } from "../../site/open/js/cloudkit.js";
import { fetchIdentity, names } from "../../site/open/js/estate.js";
import { verifiedDevices } from "../../site/open/js/identity.js";
import { parseEvent, signatureIsValid } from "../../site/open/js/estatelog.js";
import { verifiedGenTime } from "../../site/open/js/timestamp.js";
import { bytesField, stringField } from "../../site/open/js/cloudkit.js";

const args = process.argv.slice(2);
const token = args[0];
if (!token || token.startsWith("--")) {
  console.error("usage: node tools/vectors/live-check.mjs <CloudKit API token> [--estate <estateID>]...");
  process.exit(2);
}
const estates = [];
for (let i = 1; i < args.length; i++) if (args[i] === "--estate" && args[i + 1]) estates.push(args[++i]);

// Named as the site, because the token is limited to sealmessenger.com.
const ck = new CloudKit({ container: "iCloud.io.github.jasonepage.Seal", environment: "production", apiToken: token, origin: "https://sealmessenger.com" });
let problems = 0;

// 1. The directory.
const records = await ck.query("Identity", null, null, { desiredKeys: ["tier"], maxPages: 50 });
let people = 0, devices = 0, accepted = 0;
for (const r of records) {
  if (r.recordName.startsWith("tomb.") || stringField(r, "tier") === "deleted") continue;
  const found = await fetchIdentity(ck, r.recordName);
  if (!found) { console.log(`identity ${r.recordName.slice(0, 12)}: did not decode`); problems++; continue; }
  people++;
  devices += found.endorsements.length;
  const ok = await verifiedDevices(found.root, found.endorsements);
  accepted += ok.length;
  if (ok.length !== found.endorsements.length) {
    console.log(`identity ${r.recordName.slice(0, 12)}: ${ok.length} of ${found.endorsements.length} endorsements verify`);
  }
}
console.log(`directory: ${people} identities, ${accepted} of ${devices} device endorsements verify in JavaScript`);
console.log("  (an endorsement that fails here may also fail on the phones: an old or revoked one. Compare with the app before calling it a bug.)");

// 2. Estates, when asked for.
for (const estateID of estates) {
  const recs = await ck.query("EstateEvent", "estate", estateID, { maxPages: 100 });
  let parsed = 0, signed = 0, tokens = 0, tokensOK = 0;
  for (const r of recs) {
    const payload = bytesField(r, "payload");
    const e = payload && await parseEvent(payload);
    if (!e || r.recordName !== names.event(estateID, e.id)) { console.log(`estate ${estateID.slice(0, 8)}: record ${r.recordName} did not decode`); problems++; continue; }
    parsed++;
    if (await signatureIsValid(e)) signed++; else { console.log(`estate ${estateID.slice(0, 8)}: ${e.kind} ${e.id} signature or digest does not match`); problems++; }
    if (e.timestampToken) {
      tokens++;
      if (await verifiedGenTime(e.timestampToken, e.digest) !== null) tokensOK++;
      else { console.log(`estate ${estateID.slice(0, 8)}: ${e.kind} ${e.id} timestamp token does not verify`); problems++; }
    }
  }
  console.log(`estate ${estateID.slice(0, 8)}: ${parsed} events, ${signed} signatures check out, ${tokensOK} of ${tokens} timestamp tokens verify`);
}

console.log(problems ? `${problems} problems` : "no problems");
process.exit(problems ? 1 : 0);
