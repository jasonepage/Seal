#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Runs every test of the recipient page (site/open) in Node 22 or later.
# No install needed: the page uses WebCrypto and its one vendored library.
#
#     sh tools/webtests/run.sh
set -e
cd "$(dirname "$0")/../.."
for f in site/open/js/*.js; do node --check "$f"; done
failed=0
for t in timestamp identity release estate; do
  printf '%-10s ' "$t"
  if out=$(node "tools/webtests/$t.test.mjs" 2>&1); then
    echo "$out" | tail -1
  else
    echo "$out" | tail -20
    failed=1
  fi
done
[ "$failed" = 0 ] || { echo "a web test failed"; exit 1; }
sh tools/web_hashes.sh --check
