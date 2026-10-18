// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  fingerprint.js
//
//  FingerprintPhrase (Seal/Crypto/FingerprintPhrase.swift): an emoji and
//  three words from a public key. The writer sees the same words under
//  their own seal in the app ("Your words"), so a reader can check that
//  these envelopes come from the person they think.

import { utf8, concat, sha256 } from "./bytes.js";

const EMOJIS = [
  "🦊", "🦉", "🐢", "🐝", "🦭", "🐙", "🦅", "🐺",
  "🦡", "🐊", "🦔", "🐋", "🐿️", "🐞", "🦬", "🐈",
];
const WORDS = [
  "meadow", "anchor", "violet", "ember", "harbor", "cedar", "summit", "willow",
  "lantern", "moss", "drift", "quartz", "raven", "saddle", "tide", "grove",
  "flint", "marble", "noon", "orchid", "pebble", "quill", "river", "slate",
  "thorn", "umber", "vale", "wander", "yarrow", "zephyr", "amber", "birch",
  "canyon", "dune", "elm", "fjord", "garnet", "heath", "iris", "juniper",
  "kestrel", "larch", "mesa", "nectar", "onyx", "prairie", "reef", "sage",
  "tundra", "aspen", "brook", "cliff", "dell", "evergreen", "fern", "glacier",
  "hollow", "inlet", "jade", "knoll", "lagoon", "maple", "north", "oak",
];

export async function phrase(publicKey) {
  const d = await sha256(concat(utf8("seal.fingerprint.v1"), publicKey));
  return `${EMOJIS[d[0] % EMOJIS.length]} ${WORDS[d[1] % WORDS.length]} ${WORDS[d[2] % WORDS.length]} ${WORDS[d[3] % WORDS.length]}`;
}
