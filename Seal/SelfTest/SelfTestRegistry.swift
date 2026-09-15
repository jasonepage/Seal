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
    }
}
