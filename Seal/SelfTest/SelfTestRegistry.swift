// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Every suite the harness runs. Add new suites here.
enum SelfTestRegistry {
    static var suites: [SelfTest.Suite] {
        SecurityFixTests.suites
            + ClockTests.suites
            + ShamirTests.suites
            + EstateKeyTests.suites
            + ReleaseMachineTests.suites
            + EstateLogTests.suites
            + FirstStepsTests.suites
            + SecretReviewTests.suites
            + CustodyConfirmationTests.suites
            + SurvivalKitTests.suites
            + SponsoredKeyTests.suites
            + GoneAccountTests.suites
            + DepartureTests.suites
            + OnboardingCopyTests.suites
            + RuleBookTests.suites
            + AttachedFileTests.suites
            + FirstSeenTests.suites
    }
}

extension SelfTest {
    /// DEBUG launch hook. Loud on failure, silent on success. It lives here
    /// rather than in SelfTest.swift so the harness itself never names the
    /// registry, which is what lets the pure core be compiled with a subset
    /// of the suites (tools/coretests/main.swift).
    static func runAtLaunchIfDebug() {
        #if DEBUG
        let report = runAll(SelfTestRegistry.suites)
        assert(report.passed, "Self-tests failed: \(report.failures.map { "\($0.suite)/\($0.name)" })")
        #endif
    }
}
