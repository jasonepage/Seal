// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  DepartureTests.swift
//  Seal
//
//  Deleting an account: only the account's own key can write a delete
//  marker that counts (TombstoneProof), only the owner can write the
//  "I deleted my account" entry, and what that entry means for the
//  envelopes (DepartureRules).

enum DepartureTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "departure.markerNeedsTheOwnersKey") { try markerNeedsTheOwnersKey($0) },
        .init(name: "departure.onlyTheOwnerCanLeave") { try onlyTheOwnerCanLeave($0) },
        .init(name: "departure.keepCancelAndVoid") { try keepCancelAndVoid($0) },
        .init(name: "departure.datesFollowTheRule") { try datesFollowTheRule($0) },
    ] }

    static let t0 = EstateLogTests.t0
    typealias Actor = EstateLogTests.Actor

    static func markerNeedsTheOwnersKey(_ t: SelfTest.Context) throws {
        let owner = TestAuthenticator()
        let stranger = TestAuthenticator()
        let hash = owner.credentialIDHash
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let good = TombstoneProof(nonce: nonce, assertion: owner.assertion(challenge: TombstoneProof.challenge(nonce: nonce)))
        let goodData = try JSONEncoder().encode(good)

        t.check(TombstoneProof.markerCounts(hash: hash, proofData: goodData, knownKey: owner.publicKeyData),
                "the owner's signed marker counts")
        t.check(!TombstoneProof.markerCounts(hash: hash, proofData: nil, knownKey: owner.publicKeyData),
                "an unsigned marker for a known identity is ignored")
        let forged = TombstoneProof(nonce: nonce, assertion: stranger.assertion(challenge: TombstoneProof.challenge(nonce: nonce)))
        t.check(!TombstoneProof.markerCounts(hash: hash, proofData: try JSONEncoder().encode(forged), knownKey: owner.publicKeyData),
                "a stranger's signature is ignored")
        t.check(!good.proves(deletionOf: stranger.credentialIDHash, publicKey: owner.publicKeyData),
                "the owner's proof deletes only the owner")
        let otherDomain = TombstoneProof(nonce: nonce, assertion: owner.assertion(challenge: nonce))
        t.check(!otherDomain.proves(deletionOf: hash, publicKey: owner.publicKeyData),
                "a tap over some other challenge is not a delete")
        var badOptions = TestAuthenticator.Options()
        badOptions.relyingPartyID = "example.com"
        let otherSite = TombstoneProof(nonce: nonce, assertion: owner.assertion(challenge: TombstoneProof.challenge(nonce: nonce), options: badOptions))
        t.check(!otherSite.proves(deletionOf: hash, publicKey: owner.publicKeyData),
                "a signature made for another website is not a delete")
        t.check(TombstoneProof.markerCounts(hash: hash, proofData: nil, knownKey: nil),
                "with no identity to protect, a marker still counts")
    }

    static func onlyTheOwnerCanLeave(_ t: SelfTest.Context) throws {
        let owner = Actor(), keyHolder = Actor()
        let directory = EstateLogVerifier.Directory(identities: [
            owner.hash: (owner.root.rootIdentity, [owner.endorsement]),
            keyHolder.hash: (keyHolder.root.rootIdentity, [keyHolder.endorsement]),
        ])
        let body = try EstateEvent.encodeBody(DepartureBody(keepEnvelopes: false, departedAtEpoch: RecordEvent.epochSeconds(t0)))
        let mine = try owner.event(.ownerDeparted, estate: "E", prev: Data(), payload: body, at: t0)
        let fake = try keyHolder.event(.ownerDeparted, estate: "E", prev: Data(), payload: body, at: t0)
        let admitted = EstateLogVerifier.admitted([mine, fake], ownerHash: owner.hash,
                                                  custodianHashes: [keyHolder.hash], directory: directory)
        t.equal(admitted.map(\.id), [mine.id], "the owner's entry is admitted and a key holder's is dropped")
        t.check(DepartureRules.departure(events: [fake], ownerHash: owner.hash) == nil,
                "a key holder cannot make the owner look gone")
    }

    static func keepCancelAndVoid(_ t: SelfTest.Context) throws {
        let owner = Actor()
        func leave(_ keep: Bool, at: Date) throws -> EstateEvent {
            try owner.event(.ownerDeparted, estate: "E", prev: Data(),
                            payload: try EstateEvent.encodeBody(DepartureBody(keepEnvelopes: keep, departedAtEpoch: RecordEvent.epochSeconds(at))),
                            at: at)
        }
        let hb = try owner.event(.heartbeat, estate: "E", prev: Data(), at: t0)
        t.check(DepartureRules.departure(events: [hb], ownerHash: owner.hash) == nil, "no entry, nobody left")
        t.check(DepartureRules.openingAllowed(events: [hb], ownerHash: owner.hash), "opening is allowed while the owner is here")

        let keep = try leave(true, at: t0.addingTimeInterval(60))
        t.equal(DepartureRules.departure(events: [hb, keep], ownerHash: owner.hash)?.keepEnvelopes, true, "keep reads as keep")
        t.check(DepartureRules.openingAllowed(events: [hb, keep], ownerHash: owner.hash), "keep still allows opening")

        let cancel = try leave(false, at: t0.addingTimeInterval(30))
        t.check(!DepartureRules.openingAllowed(events: [hb, cancel, keep], ownerHash: owner.hash),
                "a cancel wins over a keep, even an older one")

        let garbled = try owner.event(.ownerDeparted, estate: "E", prev: Data(), payload: Data("x".utf8), at: t0.addingTimeInterval(90))
        t.check(!DepartureRules.openingAllowed(events: [hb, garbled], ownerHash: owner.hash),
                "an entry that does not read is treated as a cancel")

        let later = try owner.event(.heartbeat, estate: "E", prev: Data(), at: t0.addingTimeInterval(3_600))
        t.check(DepartureRules.departure(events: [hb, cancel, later], ownerHash: owner.hash) == nil,
                "a check-in after the entry means the delete never finished")
        t.check(DepartureRules.openingAllowed(events: [hb, cancel, later], ownerHash: owner.hash),
                "and the owner is treated as here again")
    }

    static func datesFollowTheRule(_ t: SelfTest.Context) throws {
        let owner = Actor()
        var policy = ReleasePolicy(threshold: 1)
        policy.silenceDays = 90; policy.warningDays = 21; policy.graceDays = 14
        let created = try owner.event(.estateCreated, estate: "E", prev: Data(),
                                      payload: try EstateEvent.encodeBody(EstateCreatedBody(policy: policy, createdAtEpoch: RecordEvent.epochSeconds(t0))),
                                      at: t0)
        let leftAt = t0.addingTimeInterval(10 * 86_400)
        let keep = try owner.event(.ownerDeparted, estate: "E", prev: created.digest,
                                   payload: try EstateEvent.encodeBody(DepartureBody(keepEnvelopes: true, departedAtEpoch: RecordEvent.epochSeconds(leftAt))),
                                   at: leftAt)
        let s = ReleaseFeed.snapshot(events: [created, keep], ownerHash: owner.hash,
                                     fallbackPolicy: policy, estateCreatedAt: t0)
        t.equal(s.silenceAnchor, leftAt, "the entry is the owner's last sign of life")
        t.equal(DepartureRules.earliestClaim(s), leftAt.addingTimeInterval(90 * 86_400), "a claim can start 90 days after")
        t.equal(DepartureRules.earliestOpening(s), leftAt.addingTimeInterval((90 + 21 + 14) * 86_400),
                "and they could open after the warnings and the grace")
        t.equal(ReleaseMachine.state(s, now: leftAt.addingTimeInterval(86_400)), .active,
                "the day after, nothing has changed in the machine")
        t.equal(ReleaseMachine.state(s, now: leftAt.addingTimeInterval(91 * 86_400)), .overdue,
                "after the silence, it is overdue like any other silence")
    }
}
