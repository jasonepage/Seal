// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  CustodyConfirmationTests.swift
//  Seal
//
//  The one thing that must be true: "I still have my key" can never be
//  counted as "I authorise the release", anywhere. Then the smaller
//  things: the challenge domain, who may write it, what the owner reads.

enum CustodyConfirmationTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "custody.neverCountsTowardRelease") { try neverCountsTowardRelease($0) },
        .init(name: "custody.challengeDomain") { try challengeDomain($0) },
        .init(name: "custody.admission") { try admission($0) },
        .init(name: "custody.ownerReads") { try ownerReads($0) },
        .init(name: "custody.policyDecodes") { try policyDecodes($0) },
    ] }

    static let t0 = EstateLogTests.t0
    static let day: TimeInterval = 86_400
    typealias Actor = EstateLogTests.Actor

    static func confirmation(_ who: Actor, estate: String, epoch: UInt64, prev: Data, at: Date) throws -> EstateEvent {
        let challenge = CustodyConfirmation.challenge(estateID: estate, epoch: epoch, recordHeadDigest: prev)
        let body = try EstateEvent.encodeBody(CustodyConfirmedBody(epoch: epoch, recordHeadDigest: prev,
                                                                  assertion: who.root.assertion(challenge: challenge)))
        return try who.event(.custodyConfirmed, estate: estate, prev: prev, payload: body, at: at)
    }

    /// Three key holders, threshold two, claim open. All three confirm
    /// custody. The state must stay claimOpen with zero authorizations.
    static func neverCountsTowardRelease(_ t: SelfTest.Context) throws {
        let owner = Actor(), wife = Actor(), brother = Actor(), attorney = Actor()
        var events: [EstateEvent] = []
        var prev = Data()
        func add(_ e: EstateEvent) { events.append(e); prev = e.digest }
        let policy = ReleasePolicy(threshold: 2)
        add(try owner.event(.estateCreated, estate: "E", prev: prev,
                            payload: try EstateEvent.encodeBody(EstateCreatedBody(policy: policy, createdAtEpoch: RecordEvent.epochSeconds(t0))), at: t0))
        add(try owner.event(.heartbeat, estate: "E", prev: prev, at: t0))
        let claimAt = t0.addingTimeInterval(100 * day)
        add(try brother.event(.releaseClaimed, estate: "E", prev: prev,
                              payload: try EstateEvent.encodeBody(ClaimBody(claimID: "c1", epoch: 1, lastHeartbeatAtEpoch: nil, reason: "")), at: claimAt))
        let openAt = claimAt.addingTimeInterval(36 * day)
        for who in [wife, brother, attorney] {
            add(try confirmation(who, estate: "E", epoch: 1, prev: prev, at: openAt))
        }
        let s = ReleaseFeed.snapshot(events: events, ownerHash: owner.hash, fallbackPolicy: policy,
                                     estateCreatedAt: t0, timeOf: { $0.occurredAt })
        t.equal(s.authorizations.count, 0, "three custody confirmations are zero authorizations")
        t.equal(ReleaseMachine.state(s, now: openAt.addingTimeInterval(day)), .claimOpen, "the claim stays open, nobody has tapped for it")
        t.check(!ReleaseMachine.claimantCanRelease(s, now: openAt.addingTimeInterval(day)), "nothing can be combined")
        t.equal(ReleaseMachine.validAuthorizations(s, now: openAt.addingTimeInterval(day)).count, 0, "the machine counts nothing")

        // Confirmations before, during and after a real release change no
        // state either: the snapshot is identical with them removed.
        add(try wife.event(.authorization, estate: "E", prev: prev,
                           payload: try EstateEvent.encodeBody(AuthorizationBody(claimID: "c1", epoch: 1, recordHeadDigest: prev,
                                                                                assertion: wife.root.assertion(challenge: Data(repeating: 1, count: 32)),
                                                                                shareForClaimant: [])), at: openAt.addingTimeInterval(day)))
        let withConfirmations = events
        let without = events.filter { $0.kind != .custodyConfirmed }
        let a = ReleaseFeed.snapshot(events: withConfirmations, ownerHash: owner.hash, fallbackPolicy: policy, estateCreatedAt: t0, timeOf: { $0.occurredAt })
        let b = ReleaseFeed.snapshot(events: without, ownerHash: owner.hash, fallbackPolicy: policy, estateCreatedAt: t0, timeOf: { $0.occurredAt })
        t.equal(a, b, "the snapshot is the same with the confirmations and without them")
        t.equal(a.authorizations.count, 1, "the one real tap is the one that counts")

        // And the confirmations still read back for the owner.
        t.equal(CustodyConfirmation.latest(events: events, timeOf: { $0.occurredAt }).count, 3, "all three confirmations are on the record")
    }

    /// The same key, the same estate, the same head: a custody challenge
    /// and a release challenge are different bytes, so one assertion can
    /// never verify as the other.
    static func challengeDomain(_ t: SelfTest.Context) throws {
        let head = Data(repeating: 7, count: 32)
        let custody = CustodyConfirmation.challenge(estateID: "E", epoch: 1, recordHeadDigest: head)
        let release = ReleaseChallenge.challenge(estateID: "E", epoch: 1, claimID: "", recordHeadDigest: head)
        t.check(custody != release, "custody and release challenges differ even with an empty claim id")
        let wife = Actor()
        let assertion = wife.root.assertion(challenge: custody)
        let key = try P256.Signing.PublicKey(rawRepresentation: wife.root.rootIdentity.publicKey)
        t.check(assertion.verify(with: key), "the custody assertion verifies as a signature")
        t.check(CeremonyManager.clientDataChallengeMatches(assertion.clientDataJSON, expected: custody), "over the custody challenge")
        t.check(!CeremonyManager.clientDataChallengeMatches(assertion.clientDataJSON, expected: release), "and not over any release challenge")
        for claimID in ["c1", "c2", "E"] {
            let r = ReleaseChallenge.challenge(estateID: "E", epoch: 1, claimID: claimID, recordHeadDigest: head)
            t.check(!CeremonyManager.clientDataChallengeMatches(assertion.clientDataJSON, expected: r), "not over claim \(claimID)")
        }
    }

    static func admission(_ t: SelfTest.Context) throws {
        let owner = Actor(), wife = Actor(), stranger = Actor()
        let directory = EstateLogVerifier.Directory(identities: [
            owner.hash: (owner.root.rootIdentity, [owner.endorsement]),
            wife.hash: (wife.root.rootIdentity, [wife.endorsement]),
            stranger.hash: (stranger.root.rootIdentity, [stranger.endorsement]),
        ])
        let hb = try owner.event(.heartbeat, estate: "E", prev: Data(), at: t0)
        let byWife = try confirmation(wife, estate: "E", epoch: 1, prev: hb.digest, at: t0)
        let byOwner = try confirmation(owner, estate: "E", epoch: 1, prev: hb.digest, at: t0)
        let byStranger = try confirmation(stranger, estate: "E", epoch: 1, prev: hb.digest, at: t0)
        let admitted = EstateLogVerifier.admitted([hb, byWife, byOwner, byStranger], ownerHash: owner.hash,
                                                  custodianHashes: [wife.hash], directory: directory)
        t.equal(admitted.map(\.id), [hb.id, byWife.id], "a custodian may confirm custody; the owner and a stranger may not")
    }

    static func ownerReads(_ t: SelfTest.Context) throws {
        let wife = Actor(), forger = Actor()
        let head = Data(repeating: 3, count: 32)
        let good = try confirmation(wife, estate: "E", epoch: 1, prev: head, at: t0.addingTimeInterval(10 * day))
        let older = try confirmation(wife, estate: "E", epoch: 1, prev: head, at: t0)
        // A line signed by the wife's PHONE but carrying somebody else's tap.
        let forgedBody = try EstateEvent.encodeBody(CustodyConfirmedBody(
            epoch: 1, recordHeadDigest: head,
            assertion: forger.root.assertion(challenge: CustodyConfirmation.challenge(estateID: "E", epoch: 1, recordHeadDigest: head))))
        let forged = try wife.event(.custodyConfirmed, estate: "E", prev: head, payload: forgedBody, at: t0.addingTimeInterval(20 * day))
        let events = [older, good, forged]
        let verified = CustodyConfirmation.latestVerified(events: events, estateID: "E", custodianHash: wife.hash,
                                                          rootPublicKey: wife.root.rootIdentity.publicKey, timeOf: { $0.occurredAt })
        t.equal(verified, t0.addingTimeInterval(10 * day), "the newest confirmation whose TAP verifies under the pinned root; the forged one is ignored")
        t.equal(CustodyConfirmation.latest(events: events, timeOf: { $0.occurredAt })[wife.hash], t0.addingTimeInterval(20 * day),
                "the unverified reader takes the newest line (the phone signed it); the owner's screen uses the verified one")

        let now = t0.addingTimeInterval(400 * day)
        let fresh = CustodyConfirmation.standing(name: "Karen", lastConfirmed: t0.addingTimeInterval(380 * day), handedOverAt: t0, months: 12, now: now)
        t.check(!fresh.overdue, "confirmed 20 days ago is fine")
        let stale = CustodyConfirmation.standing(name: "Karen", lastConfirmed: t0, handedOverAt: t0, months: 12, now: now)
        t.check(stale.overdue && stale.line.contains("Ask Karen"), "400 days without a confirmation names the next step: \(stale.line)")
        let never = CustodyConfirmation.standing(name: "Karen", lastConfirmed: nil, handedOverAt: t0.addingTimeInterval(300 * day), months: 12, now: now)
        t.check(!never.overdue, "handed over 100 days ago, never confirmed, not yet due")
        t.check(CustodyConfirmation.isDue(lastConfirmed: nil, since: t0, months: 6, now: t0.addingTimeInterval(181 * day)), "due after six months of thirty days")
        for s in [fresh, stale, never] { t.check(!s.line.contains("\u{2014}"), "no em dash") }
    }

    static func policyDecodes(_ t: SelfTest.Context) throws {
        let old = """
        {"silenceDays":90,"warningDays":21,"graceDays":14,"threshold":2,"objectionBehavior":"pause"}
        """
        let p = try JSONDecoder().decode(ReleasePolicy.self, from: Data(old.utf8))
        t.equal(p.custodyConfirmMonths, 12, "an older policy gets the yearly default")
        var q = p; q.custodyConfirmMonths = 6
        let back = try JSONDecoder().decode(ReleasePolicy.self, from: try JSONEncoder().encode(q))
        t.equal(back, q, "the interval round trips")
        t.check(p != q, "changing the interval is a policy change, so it is announced with policyChanged")
    }
}
