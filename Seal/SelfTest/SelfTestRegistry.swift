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
    }
}
