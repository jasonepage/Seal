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

export const config = {
  container: "iCloud.io.github.jasonepage.Seal",
  environment: "production",
  // Production, read only, limited to https://sealmessenger.com. Made 2026-10-17.
  apiToken: "2695644598fd1e998f710834375fd6d48b9510552bb29eefc0ab8c98d61170a4",
  rpId: "sealmessenger.com",
};
