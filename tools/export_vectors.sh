#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Writes docs/vectors/web-set1.json from the app's own crypto source, for the
# browser version (PRODUCT.md section 15) to be checked against. Needs a Mac
# on macOS 26 or later (ML-KEM-768 in CryptoKit) with Xcode's command line
# tools.
#
#     sh tools/export_vectors.sh
#     node tools/vectors/check.mjs docs/vectors/web-set1.json
set -e
cd "$(dirname "$0")/.."

SOURCES="Seal/Crypto/Hex.swift \
Seal/Crypto/Shamir.swift \
Seal/Crypto/KEMBundle.swift \
Seal/Estate/EstateKeys.swift \
Seal/Identity/SponsoredKey.swift"

OUT=$(mktemp -d)/seal-vectors
echo "compiling the crypto and the exporter"
# shellcheck disable=SC2086
swiftc -swift-version 6 -target "$(uname -m)-apple-macos26.0" $SOURCES tools/vectors/main.swift -o "$OUT"
mkdir -p docs/vectors
"$OUT" > docs/vectors/web-set1.json
echo "wrote docs/vectors/web-set1.json"
