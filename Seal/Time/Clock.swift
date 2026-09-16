// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  Clock.swift
//  Seal
//
//  THE CLOCK IS INJECTED EVERYWHERE.
//
//  The release machine (Estate/ReleaseMachine.swift) turns a person's silence
//  into a countdown that ends with their secrets being opened. Every step of
//  that is a comparison against "now". If "now" is read straight from the
//  system, the whole machine can only be exercised by waiting 90 real days,
//  which means it would never be exercised at all. So nothing in Seal calls
//  `Date()` or `.now` directly. It reads `Clocks.current.now`, or, in the
//  pure code, receives a `Date` as an argument.
//
//  Two implementations:
//    - `SystemClock`, which is the wall clock and is what ships.
//    - `SimulatedClock`, which starts wherever you set it and only moves when
//      told to. The debug Time Travel screen advances it by days so the whole
//      machine can run end to end in ninety seconds. The self-tests use it
//      for every state machine and policy case.
//
//  NOTE ON THE NAME. Swift's standard library also has a `Clock` protocol
//  (the one behind `ContinuousClock`). A type declared in this module shadows
//  it, which is what we want: nothing in Seal uses the standard library one
//  by name. If a future file needs it, write `Swift.Clock`.

protocol Clock: AnyObject {
    var now: Date { get }
}

/// The wall clock. What every release build uses.
final class SystemClock: Clock {
    var now: Date { Date() }
}

/// A clock that only moves when told to. Observable so debug screens can
/// show the simulated date live.
@Observable
final class SimulatedClock: Clock {
    private(set) var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now
    }

    func set(_ date: Date) { now = date }

    func advance(_ interval: TimeInterval) { now = now.addingTimeInterval(interval) }

    func advance(days: Double) { advance(days * 86_400) }
}

/// The process-wide injection point. Engines that live for the whole app
/// take a `Clock` in their initialiser and default to this, so a test or the
/// debug screen can swap it once and have every consumer follow.
enum Clocks {
    static var current: Clock = SystemClock()

    /// Posted whenever the simulated clock moves or the current clock is
    /// swapped, so anything watching a countdown re-evaluates.
    static let changed = Notification.Name("seal.clock.changed")

    static var isSimulated: Bool { current is SimulatedClock }

    /// Debug only: replace the wall clock with a simulated one seeded from
    /// the current moment, or put the wall clock back.
    static func setSimulated(_ on: Bool) {
        if on {
            guard !isSimulated else { return }
            current = SimulatedClock(now: current.now)
        } else {
            current = SystemClock()
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func travel(days: Double) {
        guard let simulated = current as? SimulatedClock else { return }
        simulated.advance(days: days)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
