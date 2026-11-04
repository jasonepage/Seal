#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Compiles the parts of Seal that need no app around them, straight from the
# app's own source files, and runs the same self-test suites the phone runs
# at launch. Needs a Mac with Xcode's command line tools and nothing else.
#
#     sh tools/run_core_tests.sh
#
# Add a file to CORE below only when it compiles with no user interface, no
# network and no keychain behind it.
set -e
cd "$(dirname "$0")/.."

CORE="Seal/Time/Clock.swift \
Seal/Crypto/Hex.swift \
Seal/Crypto/Shamir.swift \
Seal/Estate/ReleasePolicy.swift \
Seal/Estate/ReleaseMachine.swift"

SUITES="Seal/SelfTest/SelfTest.swift \
Seal/SelfTest/ShamirTests.swift \
Seal/SelfTest/ReleaseMachineTests.swift"

OUT=$(mktemp -d)/seal-core-tests
echo "compiling the core and its suites"
# The app target builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so
# Clocks.current is main actor state in the app. Compile the same way here.
# Without the flag, Swift 6 reports it as unsafe global state the app never has.
# shellcheck disable=SC2086
swiftc -swift-version 6 -default-isolation MainActor $CORE $SUITES tools/coretests/main.swift -o "$OUT"
echo "running"
"$OUT"
