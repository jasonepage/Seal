// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  config.js
//
//  Where the page reads from. The API token is a CloudKit Web Services
//  token for the Production environment, read only. It is meant to be
//  public: it lets a browser read the public database, which anyone with
//  the app reads already. Make it in the CloudKit Console, API Access,
//  and limit it to https://sealmessenger.com there.

// Production unless the address says ?env=development, which reads the
// Development database instead: the data debug builds write, for testing a
// real security key on the real site (a key answers only on its own
// domain, so this cannot be tested on localhost). Both are read only.
const development = new URLSearchParams(globalThis.location?.search ?? "").get("env") === "development";

export const config = {
  container: "iCloud.io.github.jasonepage.Seal",
  environment: development ? "development" : "production",
  // Production: read only, limited to https://sealmessenger.com. Made 2026-10-17.
  // Development: the same, not made yet.
  apiToken: development ? "" : "2695644598fd1e998f710834375fd6d48b9510552bb29eefc0ab8c98d61170a4",
  rpId: "sealmessenger.com",
  development,
};
