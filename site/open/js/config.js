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
  apiToken: "",   // not set yet: the page says so instead of failing quietly
  rpId: "sealmessenger.com",
};
