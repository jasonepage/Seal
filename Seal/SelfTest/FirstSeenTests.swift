// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  FirstSeenTests.swift
//  Seal
//
//  REVIEW.md finding 1: a claim dated forty days ago, on a claim this
//  phone learned of today, must run the full warning period from today.
//  The feed is fed unsigned events on purpose (nothing here verifies a
//  signature; that is EstateLogVerifier's job and its own tests), with
//  `timeOf` from a FirstSeen table, and the machine is asked what state
//  it sees. Also: the writer's own events are never clamped, heartbeats
//  are never clamped, seeding trusts what was already there, and the
//  table round trips and prunes.

enum FirstSeenTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "firstseen.backdatedClaimStillWarns") { try backdatedClaimStillWarns($0) },
        .init(name: "firstseen.backdatedTapDoesNotCount") { try backdatedTapDoesNotCount($0) },
        .init(name: "firstseen.heartbeatNotClamped") { try heartbeatNotClamped($0) },
        .init(name: "firstseen.seedAndPrune") { try seedAndPrune($0) },
        .init(name: "firstseen.codable") { try codable($0) },
    ] }

    static let day: TimeInterval = 86_400
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let owner = "owner"
    static let estateID = "estate-1"

    /// An unsigned event with the given kind, actor and claimed time.
    static func event(_ kind: EstateEvent.Kind, by actor: String, at: Date, id: String, payload: Data = Data()) -> EstateEvent {
        EstateEvent(id: id, estateID: estateID, kind: kind, actorHash: actor,
                    actorDevicePublicKey: Data(repeating: 4, count: 65),
                    occurredAtEpoch: Int64(at.timeIntervalSince1970),
                    previousDigest: Data(), payload: payload, signature: Data(), timestampToken: nil)
    }

    static func claimPayload(_ id: String) throws -> Data {
        try EstateEvent.encodeBody(ClaimBody(claimID: id, epoch: 1, lastHeartbeatAtEpoch: nil, reason: "test"))
    }

    /// Owner quiet since t0 (heartbeat at t0). A key holder writes a claim
    /// on day 140 but dates it day 100. Seen honestly, day 140 is in the
    /// warnings (claim opened day 140, warnings run to day 161). Seen at
    /// the claimed date, day 140 would already be past warnings (100 + 21
    /// + 14 = 135) and the keys could be tapped with no warning ever sent.
    static func backdatedClaimStillWarns(_ t: SelfTest.Context) throws {
        let heartbeat = event(.heartbeat, by: owner, at: t0, id: "hb")
        let claim = event(.releaseClaimed, by: "brother", at: t0.addingTimeInterval(100 * day),
                          id: "claim", payload: try claimPayload("c1"))
        let now = t0.addingTimeInterval(140 * day)
        var seen = FirstSeen()
        seen.note([heartbeat], at: t0)
        seen.note([claim], at: now)

        let honest = ReleaseFeed.snapshot(events: [heartbeat, claim], ownerHash: owner,
                                          fallbackPolicy: ReleasePolicy(threshold: 1), estateCreatedAt: t0,
                                          timeOf: seen.timeOf)
        t.equal(honest.claim?.openedAt, now, "the claim is dated the day this phone saw it")
        t.equal(ReleaseMachine.state(honest, now: now), .warning, "the owner is warned from today")
        t.equal(ReleaseMachine.state(honest, now: now.addingTimeInterval(20 * day)), .warning, "still warning on day 20")
        t.equal(ReleaseMachine.state(honest, now: now.addingTimeInterval(22 * day)), .grace, "grace after the warnings")
        t.equal(ReleaseMachine.state(honest, now: now.addingTimeInterval(36 * day)), .claimOpen, "keys only after the full period")

        // The same events with no table: the backdated claim skips it all.
        let naive = ReleaseFeed.snapshot(events: [heartbeat, claim], ownerHash: owner,
                                         fallbackPolicy: ReleasePolicy(threshold: 1), estateCreatedAt: t0)
        t.equal(ReleaseMachine.state(naive, now: now), .claimOpen, "without the table the backdated claim would open at once (the bug)")
    }

    /// A tap dated before this phone saw it is treated as the day it was
    /// seen, so it can never land inside a period the claim had not
    /// reached on this phone. (The feed's own tap rules are covered by
    /// ReleaseMachineTests; a real AuthorizationBody needs a hardware
    /// assertion, so only the time rule is checked here.)
    static func backdatedTapDoesNotCount(_ t: SelfTest.Context) throws {
        let tap = event(.authorization, by: "brother", at: t0.addingTimeInterval(130 * day), id: "tap")
        var seen = FirstSeen()
        seen.note([tap], at: t0.addingTimeInterval(136 * day))
        t.equal(seen.timeOf(tap), t0.addingTimeInterval(136 * day), "a backdated tap is dated the day this phone saw it")
        let honest = event(.authorization, by: "brother", at: t0.addingTimeInterval(136 * day), id: "tap2")
        seen.note([honest], at: t0.addingTimeInterval(136 * day))
        t.equal(seen.timeOf(honest), honest.occurredAt, "an honest tap keeps its time")
        let unknown = event(.authorization, by: "brother", at: t0, id: "tap3")
        t.equal(seen.timeOf(unknown), t0, "an event the table has never seen keeps its own time")
    }

    /// The owner's heartbeat keeps its own time even if this phone saw it
    /// late: backdating your own life hurts nobody, and clamping it would
    /// make a slow sync look like silence.
    static func heartbeatNotClamped(_ t: SelfTest.Context) throws {
        let late = event(.heartbeat, by: owner, at: t0.addingTimeInterval(50 * day), id: "hb2")
        var seen = FirstSeen()
        seen.note([late], at: t0.addingTimeInterval(80 * day))
        t.equal(seen.timeOf(late), late.occurredAt, "a heartbeat is never clamped")
        let claim = event(.releaseClaimed, by: "brother", at: t0, id: "c", payload: try claimPayload("c1"))
        seen.note([claim], at: t0.addingTimeInterval(80 * day))
        t.equal(seen.timeOf(claim), t0.addingTimeInterval(80 * day), "a claim is clamped to first sight")
        seen.note([claim], at: t0.addingTimeInterval(90 * day))
        t.equal(seen.timeOf(claim), t0.addingTimeInterval(80 * day), "seeing it again later does not move it")
    }

    static func seedAndPrune(_ t: SelfTest.Context) throws {
        let claim = event(.releaseClaimed, by: "brother", at: t0, id: "c", payload: try claimPayload("c1"))
        var seen = FirstSeen()
        seen.seed([claim])
        t.equal(seen.timeOf(claim), t0, "a seeded event is trusted at its own time, once")
        t.check(!seen.note([claim], at: t0.addingTimeInterval(day)), "noting a seeded event again changes nothing")
        seen.keep(only: [])
        t.check(seen.byEventID.isEmpty, "pruning drops ids no log holds")
    }

    static func codable(_ t: SelfTest.Context) throws {
        var seen = FirstSeen()
        seen.byEventID["a"] = t0
        let data = try JSONEncoder().encode(seen)
        let back = try JSONDecoder().decode(FirstSeen.self, from: data)
        t.equal(back, seen, "the table round trips")
    }
}
