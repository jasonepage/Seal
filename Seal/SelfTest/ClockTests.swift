// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum ClockTests {
    static var suites: [SelfTest.Suite] { [
        .init(name: "clock.simulated") { try simulated($0) },
    ] }

    static func simulated(_ t: SelfTest.Context) throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = SimulatedClock(now: start)
        t.equal(clock.now, start, "a simulated clock starts where it is told")
        clock.advance(days: 90)
        t.equal(clock.now.timeIntervalSince(start), 90 * 86_400, "advance(days:) moves exactly that far")
        clock.set(start)
        t.equal(clock.now, start, "set puts it back")
        let system = SystemClock()
        t.check(abs(system.now.timeIntervalSinceNow) < 5, "the system clock reads the wall clock")
    }
}
