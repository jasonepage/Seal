#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Writes site/open/SHA256SUMS: the hash of every file the recipient page
# serves, so anyone can compare what the site sends with this repository.
#
#     sh tools/web_hashes.sh          write it
#     sh tools/web_hashes.sh --check  fail if it is out of date
set -e
cd "$(dirname "$0")/../site/open"
LIST=$(find . -type f ! -name SHA256SUMS ! -path './test/*' | LC_ALL=C sort)
# shellcheck disable=SC2086
NEW=$(sha256sum $LIST 2>/dev/null || shasum -a 256 $LIST)
if [ "$1" = "--check" ]; then
  if [ "$NEW" != "$(cat SHA256SUMS 2>/dev/null)" ]; then
    echo "site/open/SHA256SUMS is out of date. Run: sh tools/web_hashes.sh"
    exit 1
  fi
  echo "site/open/SHA256SUMS is current"
else
  echo "$NEW" > SHA256SUMS
  echo "wrote site/open/SHA256SUMS"
fi
