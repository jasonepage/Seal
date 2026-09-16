// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  ReleaseMachineTests.swift
//  Seal
//
//  Every transition in the brief's section 5, every cancel path, both
//  objection behaviours, and the boundaries, all driven by a SimulatedClock.
//  The story used throughout: the default policy (90 / 21 / 14, 2 of 3),
//  custodians "wife", "brother", "attorney".

enum ReleaseMachineTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "release.silence", run: silence),
        .init(name: "release.happyPath", run: happyPath),
        .init(name: "release.heartbeatBeatsEverything", run: heartbeatBeatsEverything),
        .init(name: "release.cancellation", run: cancellation),
        .init(name: "release.objectionPause", run: objectionPause),
        .init(name: "release.objectionVeto", run: objectionVeto),
        .init(name: "release.authorizationRules", run: authorizationRules),
        .init(name: "release.earlyClaim", run: earlyClaim),
        .init(name: "release.policy", run: policy),
        .init(name: "release.ninetySecondRun", run: ninetySecondRun),
    ] }

    static let day: TimeInterval = 86_400
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func fresh() -> ReleaseSnapshot {
        ReleaseSnapshot(policy: ReleasePolicy(threshold: 2), estateCreatedAt: t0, lastHeartbeatAt: t0, claim: nil)
    }

    static func claim(at: Date, id: String = "claim-1") -> ReleaseSnapshot.Claim {
        .init(id: id, epoch: 1, claimantHash: "brother", openedAt: at)
    }

    // MARK: silence

    static func silence(_ t: SelfTest.Context) throws {
        var s = fresh()
        let clock = SimulatedClock(now: t0)
        t.equal(ReleaseMachine.state(s, now: clock.now), .active, "fresh estate is active")
        clock.advance(days: 89)
        t.equal(ReleaseMachine.state(s, now: clock.now), .active, "day 89 still active")
        clock.advance(days: 1)
        t.equal(ReleaseMachine.state(s, now: clock.now), .active, "exactly 90 days is still active (strictly greater)")
        clock.advance(1)
        t.equal(ReleaseMachine.state(s, now: clock.now), .overdue, "one second past 90 days is overdue")
        t.equal(ReleaseMachine.silentDays(s, now: clock.now), 90, "silent days counts whole days")
        t.check(ReleaseMachine.custodianCanClaim(s, now: clock.now), "custodians may claim when overdue")
        t.check(!ReleaseMachine.custodianCanClaim(s, now: t0), "custodians may not claim while active")
        t.equal(ReleaseMachine.nextTransition(s, now: t0), t0.addingTimeInterval(90 * day), "next transition from active is the silence deadline")
        // A heartbeat resets the anchor.
        s.lastHeartbeatAt = clock.now
        t.equal(ReleaseMachine.state(s, now: clock.now), .active, "a heartbeat makes it active again")
        // No heartbeat ever: silence counts from creation.
        var never = fresh(); never.lastHeartbeatAt = nil
        t.equal(ReleaseMachine.state(never, now: t0.addingTimeInterval(91 * day)), .overdue, "no heartbeat ever: creation is the anchor")
    }

    // MARK: happy path

    static func happyPath(_ t: SelfTest.Context) throws {
        var s = fresh()
        let clock = SimulatedClock(now: t0)
        clock.advance(days: 100)
        t.equal(ReleaseMachine.state(s, now: clock.now), .overdue, "overdue at day 100")
        s.claim = claim(at: clock.now)
        t.equal(ReleaseMachine.state(s, now: clock.now), .warning, "a claim moves overdue to warning")
        let tl = ReleaseMachine.timeline(s, now: clock.now)!
        t.equal(tl.warningEndsAt, clock.now.addingTimeInterval(21 * day), "warnings run 21 days")
        t.equal(tl.claimOpensAt, clock.now.addingTimeInterval(35 * day), "keys can be tapped after 21 + 14 days")
        t.equal(ReleaseMachine.nextTransition(s, now: clock.now), tl.warningEndsAt, "next transition from warning")
        clock.advance(days: 20)
        t.equal(ReleaseMachine.state(s, now: clock.now), .warning, "day 20 of warnings")
        clock.advance(days: 1)
        t.equal(ReleaseMachine.state(s, now: clock.now), .grace, "day 21 is grace")
        t.equal(ReleaseMachine.nextTransition(s, now: clock.now), tl.claimOpensAt, "next transition from grace")
        t.check(!ReleaseMachine.custodianCanAuthorize(s, now: clock.now, custodianHash: "wife"), "no taps during grace")
        clock.advance(days: 14)
        t.equal(ReleaseMachine.state(s, now: clock.now), .claimOpen, "after grace the claim is open")
        t.check(ReleaseMachine.nextTransition(s, now: clock.now) == nil, "claimOpen waits for people, not time")
        t.check(ReleaseMachine.custodianCanAuthorize(s, now: clock.now, custodianHash: "wife"), "wife may tap")
        s.authorizations.append(.init(custodianHash: "wife", at: clock.now))
        t.equal(ReleaseMachine.state(s, now: clock.now), .claimOpen, "one of two is not enough")
        t.check(!ReleaseMachine.custodianCanAuthorize(s, now: clock.now, custodianHash: "wife"), "wife may not tap twice")
        clock.advance(days: 2)
        s.authorizations.append(.init(custodianHash: "attorney", at: clock.now))
        t.equal(ReleaseMachine.state(s, now: clock.now), .authorized, "two of three authorises")
        t.check(ReleaseMachine.claimantCanRelease(s, now: clock.now), "claimant may now combine shares")
        s.releasedAt = clock.now
        t.equal(ReleaseMachine.state(s, now: clock.now), .released, "released")
        clock.advance(days: 400)
        t.equal(ReleaseMachine.state(s, now: clock.now), .released, "released is terminal")
        s.lastHeartbeatAt = clock.now
        t.equal(ReleaseMachine.state(s, now: clock.now), .released, "a heartbeat after release changes nothing (the key is out)")
    }

    // MARK: heartbeat beats everything

    static func heartbeatBeatsEverything(_ t: SelfTest.Context) throws {
        // Reach each live state, then heartbeat, and expect the claim dead.
        let claimAt = t0.addingTimeInterval(100 * day)
        func snapshotAt(_ state: ReleaseState) -> (ReleaseSnapshot, Date) {
            var s = fresh()
            s.claim = claim(at: claimAt)
            switch state {
            case .warning: return (s, claimAt.addingTimeInterval(5 * day))
            case .grace: return (s, claimAt.addingTimeInterval(25 * day))
            case .claimOpen: return (s, claimAt.addingTimeInterval(40 * day))
            case .authorized:
                let at = claimAt.addingTimeInterval(40 * day)
                s.authorizations = [.init(custodianHash: "wife", at: at), .init(custodianHash: "brother", at: at)]
                return (s, at.addingTimeInterval(day))
            case .objected:
                s.objections = [.init(custodianHash: "attorney", at: claimAt.addingTimeInterval(2 * day), withdrawnAt: nil)]
                return (s, claimAt.addingTimeInterval(3 * day))
            default: fatalError("not a live state")
            }
        }
        for state in [ReleaseState.warning, .grace, .claimOpen, .authorized, .objected] {
            var (s, now) = snapshotAt(state)
            t.equal(ReleaseMachine.state(s, now: now), state, "reached \(state)")
            t.check(ReleaseMachine.ownerCanCancel(s, now: now), "owner can cancel from \(state)")
            s.lastHeartbeatAt = now
            t.equal(ReleaseMachine.state(s, now: now), .cancelled, "heartbeat from \(state) cancels")
            t.check(ReleaseMachine.timeline(s, now: now) == nil, "no timeline after cancel from \(state)")
            t.check(!ReleaseMachine.claimantCanRelease(s, now: now), "no release after cancel from \(state)")
            // And the cycle starts over: 90 more days of silence before overdue.
            t.equal(ReleaseMachine.state(s, now: now.addingTimeInterval(90 * day)), .cancelled, "still cancelled at 90 days")
            t.equal(ReleaseMachine.state(s, now: now.addingTimeInterval(90 * day + 1)), .overdue, "overdue again after fresh silence")
            t.equal(ReleaseMachine.nextTransition(s, now: now), now.addingTimeInterval(90 * day), "next transition from cancelled is the new silence deadline")
        }
        // A heartbeat BEFORE the claim does not cancel it.
        var s = fresh()
        s.claim = claim(at: claimAt)
        s.lastHeartbeatAt = claimAt.addingTimeInterval(-1)
        // ...but that makes the claim too early (anchor moved), so it is ignored.
        t.equal(ReleaseMachine.state(s, now: claimAt.addingTimeInterval(day)), .active, "a claim one day after a heartbeat is ignored")
    }

    // MARK: cancellation

    static func cancellation(_ t: SelfTest.Context) throws {
        let claimAt = t0.addingTimeInterval(100 * day)
        var s = fresh()
        s.claim = claim(at: claimAt)
        let now = claimAt.addingTimeInterval(10 * day)
        t.equal(ReleaseMachine.state(s, now: now), .warning, "warning before cancel")
        s.cancellations = [claimAt.addingTimeInterval(-day)]
        t.equal(ReleaseMachine.state(s, now: now), .warning, "a cancellation older than the claim does not touch it")
        s.cancellations = [now]
        // The owner has still not heartbeated, so silence from the LAST
        // heartbeat (t0) is well past 90 days: overdue, not cancelled.
        t.equal(ReleaseMachine.state(s, now: now), .overdue, "cancellation without a heartbeat kills the claim; silence still stands")
        t.check(ReleaseMachine.custodianCanClaim(s, now: now), "a new claim may open after a bare cancellation")
        // Cancellation plus heartbeat (the app always sends both).
        s.lastHeartbeatAt = now
        t.equal(ReleaseMachine.state(s, now: now), .cancelled, "cancellation with heartbeat shows cancelled")
    }

    // MARK: objection, pause behaviour

    static func objectionPause(_ t: SelfTest.Context) throws {
        let claimAt = t0.addingTimeInterval(100 * day)
        var s = fresh()
        s.policy.objectionBehavior = .pause
        s.claim = claim(at: claimAt)
        let objectAt = claimAt.addingTimeInterval(10 * day)
        s.objections = [.init(custodianHash: "attorney", at: objectAt, withdrawnAt: nil)]
        t.equal(ReleaseMachine.state(s, now: claimAt.addingTimeInterval(9 * day)), .warning, "before the objection: warning")
        t.equal(ReleaseMachine.state(s, now: objectAt.addingTimeInterval(day)), .objected, "an open objection pauses")
        t.check(ReleaseMachine.nextTransition(s, now: objectAt.addingTimeInterval(day)) == nil, "paused: no timed transition")
        t.equal(ReleaseMachine.state(s, now: objectAt.addingTimeInterval(100 * day)), .objected, "paused forever until withdrawn")
        // Withdraw after 5 days: every deadline slides by 5 days.
        s.objections[0].withdrawnAt = objectAt.addingTimeInterval(5 * day)
        let after = objectAt.addingTimeInterval(6 * day)
        t.equal(ReleaseMachine.state(s, now: after), .warning, "withdrawn: back to warning")
        let tl = ReleaseMachine.timeline(s, now: after)!
        t.equal(tl.pausedTotal, 5 * day, "five days of pause recorded")
        t.equal(tl.warningEndsAt, claimAt.addingTimeInterval(26 * day), "warning end slid by five days")
        t.equal(tl.claimOpensAt, claimAt.addingTimeInterval(40 * day), "claim open slid by five days")
        t.equal(ReleaseMachine.state(s, now: claimAt.addingTimeInterval(39 * day)), .grace, "still grace on the old open day plus 4")
        t.equal(ReleaseMachine.state(s, now: claimAt.addingTimeInterval(40 * day)), .claimOpen, "open on the slid day")
        // An objection during claimOpen also pauses, and a tap during the
        // pause does not count.
        let openNow = claimAt.addingTimeInterval(41 * day)
        s.objections.append(.init(custodianHash: "wife", at: openNow, withdrawnAt: nil))
        t.equal(ReleaseMachine.state(s, now: openNow.addingTimeInterval(1)), .objected, "objection during claimOpen pauses")
        s.authorizations = [.init(custodianHash: "brother", at: openNow.addingTimeInterval(day)),
                            .init(custodianHash: "attorney", at: openNow.addingTimeInterval(day))]
        s.objections[1].withdrawnAt = openNow.addingTimeInterval(3 * day)
        let later = openNow.addingTimeInterval(4 * day)
        t.equal(ReleaseMachine.validAuthorizations(s, now: later).count, 0, "taps made during a pause do not count")
        t.equal(ReleaseMachine.state(s, now: later), .claimOpen, "after withdrawal, claim open again, nobody has validly tapped")
        s.authorizations = [.init(custodianHash: "brother", at: later), .init(custodianHash: "attorney", at: later)]
        t.equal(ReleaseMachine.state(s, now: later), .authorized, "taps after the pause count")
    }

    // MARK: objection, veto behaviour

    static func objectionVeto(_ t: SelfTest.Context) throws {
        let claimAt = t0.addingTimeInterval(100 * day)
        var s = fresh()
        s.policy.objectionBehavior = .veto
        s.claim = claim(at: claimAt)
        s.objections = [.init(custodianHash: "attorney", at: claimAt.addingTimeInterval(3 * day), withdrawnAt: nil)]
        let now = claimAt.addingTimeInterval(4 * day)
        t.equal(ReleaseMachine.state(s, now: now), .objected, "veto: objected")
        t.check(ReleaseMachine.timeline(s, now: now) == nil, "veto: no timeline, the claim is dead")
        s.objections[0].withdrawnAt = claimAt.addingTimeInterval(5 * day)
        t.equal(ReleaseMachine.state(s, now: claimAt.addingTimeInterval(6 * day)), .objected, "veto: withdrawing does not revive the claim")
        t.equal(ReleaseMachine.state(s, now: claimAt.addingTimeInterval(200 * day)), .objected, "veto: stays objected until a new claim")
        s.authorizations = [.init(custodianHash: "wife", at: claimAt.addingTimeInterval(50 * day)),
                            .init(custodianHash: "brother", at: claimAt.addingTimeInterval(50 * day))]
        t.equal(ReleaseMachine.state(s, now: claimAt.addingTimeInterval(51 * day)), .objected, "veto: taps on a vetoed claim do nothing")
        t.check(ReleaseMachine.custodianCanClaim(s, now: claimAt.addingTimeInterval(51 * day)),
                "veto: a new claim may open because the owner is still silent")
        // A new claim starts a new countdown.
        s.claim = claim(at: claimAt.addingTimeInterval(60 * day), id: "claim-2")
        s.objections = []
        s.authorizations = []
        t.equal(ReleaseMachine.state(s, now: claimAt.addingTimeInterval(61 * day)), .warning, "a new claim runs again")
    }

    // MARK: authorization rules

    static func authorizationRules(_ t: SelfTest.Context) throws {
        let claimAt = t0.addingTimeInterval(100 * day)
        var s = fresh()
        s.claim = claim(at: claimAt)
        let open = claimAt.addingTimeInterval(35 * day)
        // Two taps by the same custodian are one.
        s.authorizations = [.init(custodianHash: "wife", at: open), .init(custodianHash: "wife", at: open.addingTimeInterval(day))]
        t.equal(ReleaseMachine.state(s, now: open.addingTimeInterval(2 * day)), .claimOpen, "same custodian twice is one")
        // A tap before the claim opened does not count.
        s.authorizations = [.init(custodianHash: "wife", at: open.addingTimeInterval(-1)), .init(custodianHash: "brother", at: open)]
        t.equal(ReleaseMachine.state(s, now: open.addingTimeInterval(day)), .claimOpen, "a tap one second before open does not count")
        s.authorizations = [.init(custodianHash: "wife", at: open), .init(custodianHash: "brother", at: open)]
        t.equal(ReleaseMachine.state(s, now: open), .authorized, "taps exactly at open count")
        // A tap dated in the future is not counted yet.
        s.authorizations = [.init(custodianHash: "wife", at: open), .init(custodianHash: "brother", at: open.addingTimeInterval(5 * day))]
        t.equal(ReleaseMachine.state(s, now: open.addingTimeInterval(day)), .claimOpen, "a future-dated tap is not counted yet")
        // Threshold of 3 of 3.
        s.policy.threshold = 3
        s.authorizations = [.init(custodianHash: "wife", at: open), .init(custodianHash: "brother", at: open), .init(custodianHash: "attorney", at: open)]
        t.equal(ReleaseMachine.state(s, now: open), .authorized, "3 of 3")
        s.authorizations.removeLast()
        t.equal(ReleaseMachine.state(s, now: open), .claimOpen, "2 of 3 when 3 required")
        // The claimant's own tap counts like anyone else's.
        s.policy.threshold = 1
        s.authorizations = [.init(custodianHash: "brother", at: open)]
        t.equal(ReleaseMachine.state(s, now: open), .authorized, "1 of 3: the claimant's own tap suffices")
    }

    // MARK: early claim

    static func earlyClaim(_ t: SelfTest.Context) throws {
        var s = fresh()
        s.claim = claim(at: t0.addingTimeInterval(30 * day))
        t.equal(ReleaseMachine.voidReason(s), .openedTooEarly, "a claim at day 30 of 90 is too early")
        t.equal(ReleaseMachine.state(s, now: t0.addingTimeInterval(31 * day)), .active, "too-early claim: still active")
        t.equal(ReleaseMachine.state(s, now: t0.addingTimeInterval(200 * day)), .overdue, "too-early claim never matures; overdue needs a new claim")
        t.check(ReleaseMachine.custodianCanClaim(s, now: t0.addingTimeInterval(200 * day)), "a new claim is allowed")
        // Exactly at the boundary is allowed.
        s.claim = claim(at: t0.addingTimeInterval(90 * day))
        t.equal(ReleaseMachine.voidReason(s), .notVoid, "a claim exactly at 90 days is allowed")
        // A claim dated before now is not live yet from the perspective of an
        // earlier now.
        t.equal(ReleaseMachine.state(s, now: t0.addingTimeInterval(89 * day)), .active, "before the claim's own time: active")
    }

    // MARK: policy validation

    static func policy(_ t: SelfTest.Context) throws {
        var p = ReleasePolicy(threshold: 2)
        t.noThrow("default policy validates with 3 custodians") { try p.validate(custodianCount: 3) }
        t.equal(p.silenceDays, 90, "default silence 90")
        t.equal(p.warningDays, 21, "default warning 21")
        t.equal(p.graceDays, 14, "default grace 14")
        t.equal(p.objectionBehavior, .pause, "default objection behaviour is pause")
        p.silenceDays = 45
        t.throwsError("45 days is not an allowed silence") { try p.validate(custodianCount: 3) }
        p.silenceDays = 365
        t.noThrow("365 is allowed") { try p.validate(custodianCount: 3) }
        p.threshold = 4
        t.throwsError("threshold above custodians") { try p.validate(custodianCount: 3) }
        p.threshold = 0
        t.throwsError("threshold zero") { try p.validate(custodianCount: 3) }
        p.threshold = 1
        p.warningDays = 0
        t.throwsError("zero warning days") { try p.validate(custodianCount: 1) }
        p.warningDays = 1; p.graceDays = 0
        t.noThrow("zero grace is allowed") { try p.validate(custodianCount: 1) }
    }

    // MARK: the whole thing, fast

    /// The debug Time Travel screen runs exactly this: the story from the
    /// brief, every phase, driven by a simulated clock, in seconds.
    static func ninetySecondRun(_ t: SelfTest.Context) throws {
        let clock = SimulatedClock(now: t0)
        var s = ReleaseSnapshot(policy: ReleasePolicy(threshold: 2), estateCreatedAt: clock.now, lastHeartbeatAt: clock.now, claim: nil)
        var seen: [ReleaseState] = [ReleaseMachine.state(s, now: clock.now)]
        // Sunday night: he opens the app every week for a while.
        for _ in 0..<8 { clock.advance(days: 7); s.lastHeartbeatAt = clock.now }
        seen.append(ReleaseMachine.state(s, now: clock.now))
        // Then silence.
        clock.advance(days: 91)
        seen.append(ReleaseMachine.state(s, now: clock.now))
        s.claim = claim(at: clock.now)
        seen.append(ReleaseMachine.state(s, now: clock.now))
        clock.advance(days: 21)
        seen.append(ReleaseMachine.state(s, now: clock.now))
        clock.advance(days: 14)
        seen.append(ReleaseMachine.state(s, now: clock.now))
        s.authorizations.append(.init(custodianHash: "wife", at: clock.now))
        clock.advance(days: 1)
        s.authorizations.append(.init(custodianHash: "attorney", at: clock.now))
        seen.append(ReleaseMachine.state(s, now: clock.now))
        s.releasedAt = clock.now
        seen.append(ReleaseMachine.state(s, now: clock.now))
        t.equal(seen, [.active, .active, .overdue, .warning, .grace, .claimOpen, .authorized, .released],
                "the full story runs through every state in order")
    }
}
