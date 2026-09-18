// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  tools/coretests/main.swift
//
//  RUNS SEAL'S OWN TESTS WITHOUT THE APP.
//
//  Seal has no test target: a passkey needs a real app to live in, so the
//  suites in Seal/SelfTest run at DEBUG launch on a phone. That is fine for
//  the developer and useless to a stranger, who cannot see them pass.
//
//  So the parts with no user interface, no network and no keychain in them
//  are compiled here straight from the app's own source files, with the same
//  suites, by tools/run_core_tests.sh. Nothing is copied or reimplemented:
//  if these files change, this either compiles and passes, or it does not.
//
//  Today that is the key split and the release countdown, which are the two
//  things most worth checking in public. More files join the list as they
//  stop needing the app around them.

import Foundation

let report = MainActor.assumeIsolated {
    SelfTest.runAll(ShamirTests.suites + ReleaseMachineTests.suites)
}

for failure in report.failures {
    print("FAIL \(failure.suite) / \(failure.name): \(failure.detail)")
}
print("\(report.checks) checks, \(report.failures.count) failures")
exit(report.passed ? 0 : 1)
