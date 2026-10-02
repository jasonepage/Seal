// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  EstateLogTests.swift
//  Seal
//
//  The signed log: digests, links, who may write what, and the feed that
//  turns events into a state machine snapshot.

enum EstateLogTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "estatelog.signing") { try signing($0) },
        .init(name: "estatelog.admission") { try admission($0) },
        .init(name: "estatelog.feed") { try feed($0) },
        .init(name: "estatelog.releaseAdmission") { try releaseAdmission($0) },
    ] }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    struct Actor {
        let root: TestAuthenticator
        let device: P256.Signing.PrivateKey
        let endorsement: DeviceEndorsement
        var hash: String { root.credentialIDHash }

        init() {
            root = TestAuthenticator()
            device = P256.Signing.PrivateKey()
            let kem = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            endorsement = root.endorse(deviceKey: device, kem: kem)
        }

        func event(_ kind: EstateEvent.Kind, estate: String, prev: Data, payload: Data = Data(), at: Date) throws -> EstateEvent {
            try EstateEventBuilder.makeWithSoftwareKey(kind: kind, estateID: estate, actorHash: hash,
                                                       deviceKey: device, previousDigest: prev,
                                                       payload: payload, now: at)
        }
    }

    static func signing(_ t: SelfTest.Context) throws {
        let owner = Actor()
        let first = try owner.event(.heartbeat, estate: "E", prev: Data(), at: t0)
        t.check(first.signatureIsValid(), "a freshly built event verifies")
        t.check(first.previousDigest.isEmpty, "first event links to nothing")
        let second = try owner.event(.heartbeat, estate: "E", prev: first.digest, at: t0.addingTimeInterval(60))
        t.equal(second.previousDigest, first.digest, "second links to first")
        // Tamper with a field: the digest changes and the signature fails.
        let tampered = EstateEvent(id: second.id, estateID: second.estateID, kind: second.kind,
                                   actorHash: second.actorHash, actorDevicePublicKey: second.actorDevicePublicKey,
                                   occurredAtEpoch: second.occurredAtEpoch + 86_400,
                                   previousDigest: second.previousDigest, payload: second.payload,
                                   signature: second.signature, timestampToken: nil)
        t.check(!tampered.signatureIsValid(), "moving the time by a day breaks the signature")
        var withToken = second
        withToken.timestampToken = Data([1, 2, 3])
        t.equal(withToken.digest, second.digest, "a token does not change the digest")
        t.check(withToken.signatureIsValid(), "a token does not break the signature")
        t.equal(EstateLogVerifier.danglingLinks([first, second]).count, 0, "no dangling links")
        t.equal(EstateLogVerifier.danglingLinks([second]), [second.id], "a missing predecessor is reported")
        let merged = EstateLogStore.merged([first, second], [withToken])
        t.equal(merged.count, 2, "merge dedupes by id")
        t.check(merged.first { $0.id == second.id }?.timestampToken != nil, "merge keeps the token")
        t.equal(EstateLogStore.headDigest(merged), second.digest, "head is the newest event")
    }

    static func admission(_ t: SelfTest.Context) throws {
        let owner = Actor(), wife = Actor(), stranger = Actor()
        let directory = EstateLogVerifier.Directory(identities: [
            owner.hash: (owner.root.rootIdentity, [owner.endorsement]),
            wife.hash: (wife.root.rootIdentity, [wife.endorsement]),
            stranger.hash: (stranger.root.rootIdentity, [stranger.endorsement]),
        ])
        let custodians: Set<String> = [wife.hash]
        let hb = try owner.event(.heartbeat, estate: "E", prev: Data(), at: t0)
        let claimBody = try EstateEvent.encodeBody(ClaimBody(claimID: "c1", epoch: 1, lastHeartbeatAtEpoch: nil, reason: ""))
        let claim = try wife.event(.releaseClaimed, estate: "E", prev: hb.digest, payload: claimBody, at: t0)
        let ownerClaims = try owner.event(.releaseClaimed, estate: "E", prev: hb.digest, payload: claimBody, at: t0)
        let wifeHeartbeats = try wife.event(.heartbeat, estate: "E", prev: hb.digest, at: t0)
        let strangerClaims = try stranger.event(.releaseClaimed, estate: "E", prev: hb.digest, payload: claimBody, at: t0)
        let admitted = EstateLogVerifier.admitted([hb, claim, ownerClaims, wifeHeartbeats, strangerClaims],
                                                  ownerHash: owner.hash, custodianHashes: custodians, directory: directory)
        t.equal(admitted.map(\.id), [hb.id, claim.id], "owner heartbeat and custodian claim admitted; owner claiming, custodian heartbeating, and a stranger are all dropped")

        // A device the root never endorsed is dropped even with a valid signature.
        let rogue = P256.Signing.PrivateKey()
        let rogueEvent = try EstateEventBuilder.makeWithSoftwareKey(kind: .heartbeat, estateID: "E", actorHash: owner.hash,
                                                                     deviceKey: rogue, previousDigest: Data(), payload: Data(), now: t0)
        t.check(rogueEvent.signatureIsValid(), "rogue event is self-consistent")
        t.equal(EstateLogVerifier.admitted([rogueEvent], ownerHash: owner.hash, custodianHashes: custodians, directory: directory).count, 0,
                "an unendorsed device cannot speak for the owner")
        // A revoked device is dropped by the caller filtering endorsements (fetchIdentity), so an empty endorsement list drops it.
        let revokedDirectory = EstateLogVerifier.Directory(identities: [owner.hash: (owner.root.rootIdentity, [])])
        t.equal(EstateLogVerifier.admitted([hb], ownerHash: owner.hash, custodianHashes: [], directory: revokedDirectory).count, 0,
                "no live endorsements, no admission")

        // Audit C1: a tap is admitted only with its physical-key signature
        // over the very claim it names. The device signature is not enough.
        func tapEvent(signedBy key: TestAuthenticator, claimID: String, challengeFor signedClaimID: String) throws -> EstateEvent {
            let challenge = ReleaseChallenge.challenge(estateID: "E", epoch: 1, claimID: signedClaimID, recordHeadDigest: hb.digest)
            let body = AuthorizationBody(claimID: claimID, epoch: 1, recordHeadDigest: hb.digest,
                                         assertion: key.assertion(challenge: challenge), shareForClaimant: [])
            return try wife.event(.authorization, estate: "E", prev: hb.digest, payload: try EstateEvent.encodeBody(body), at: t0)
        }
        let realTap = try tapEvent(signedBy: wife.root, claimID: "c1", challengeFor: "c1")
        let replayedTap = try tapEvent(signedBy: wife.root, claimID: "c1", challengeFor: "c0")
        let borrowedTap = try tapEvent(signedBy: stranger.root, claimID: "c1", challengeFor: "c1")
        let taps = EstateLogVerifier.admitted([realTap, replayedTap, borrowedTap], ownerHash: owner.hash,
                                              custodianHashes: custodians, directory: directory)
        t.equal(taps.map(\.id), [realTap.id], "only a tap signed by the key holder's own key over this claim is admitted")
    }

    static func feed(_ t: SelfTest.Context) throws {
        let owner = Actor(), wife = Actor(), brother = Actor(), attorney = Actor()
        let day: TimeInterval = 86_400
        var events: [EstateEvent] = []
        var prev = Data()
        func add(_ e: EstateEvent) { events.append(e); prev = e.digest }
        let policy = ReleasePolicy(threshold: 2)
        add(try owner.event(.estateCreated, estate: "E", prev: prev,
                            payload: try EstateEvent.encodeBody(EstateCreatedBody(policy: policy, createdAtEpoch: RecordEvent.epochSeconds(t0))), at: t0))
        add(try owner.event(.heartbeat, estate: "E", prev: prev, at: t0.addingTimeInterval(7 * day)))
        add(try owner.event(.heartbeat, estate: "E", prev: prev, at: t0.addingTimeInterval(14 * day)))
        let claimAt = t0.addingTimeInterval(14 * day + 100 * day)
        add(try brother.event(.releaseClaimed, estate: "E", prev: prev,
                              payload: try EstateEvent.encodeBody(ClaimBody(claimID: "c1", epoch: 1, lastHeartbeatAtEpoch: nil, reason: "no word")), at: claimAt))
        add(try attorney.event(.objection, estate: "E", prev: prev,
                               payload: try EstateEvent.encodeBody(ObjectionBody(claimID: "c1", withdrawn: false, note: "wait")), at: claimAt.addingTimeInterval(2 * day)))
        add(try attorney.event(.objectionWithdrawn, estate: "E", prev: prev,
                               payload: try EstateEvent.encodeBody(ObjectionBody(claimID: "c1", withdrawn: true, note: "")), at: claimAt.addingTimeInterval(4 * day)))
        let openAt = claimAt.addingTimeInterval(37 * day)
        add(try wife.event(.authorization, estate: "E", prev: prev,
                           payload: try EstateEvent.encodeBody(AuthorizationBody(claimID: "c1", epoch: 1, recordHeadDigest: prev,
                                                                                assertion: wife.root.assertion(challenge: Data(repeating: 1, count: 32)),
                                                                                shareForClaimant: [])), at: openAt))
        add(try brother.event(.authorization, estate: "E", prev: prev,
                              payload: try EstateEvent.encodeBody(AuthorizationBody(claimID: "c1", epoch: 1, recordHeadDigest: prev,
                                                                                   assertion: brother.root.assertion(challenge: Data(repeating: 1, count: 32)),
                                                                                   shareForClaimant: [])), at: openAt.addingTimeInterval(day)))

        let s = ReleaseFeed.snapshot(events: events, ownerHash: owner.hash, fallbackPolicy: ReleasePolicy(threshold: 1),
                                     estateCreatedAt: t0, timeOf: { $0.occurredAt })
        t.equal(s.policy.threshold, 2, "policy comes from the estateCreated event")
        t.equal(s.lastHeartbeatAt, t0.addingTimeInterval(14 * day), "newest heartbeat wins")
        t.equal(s.claim?.id, "c1", "the claim is found")
        t.equal(s.claim?.claimantHash, brother.hash, "the claimant is the event's actor")
        t.equal(s.objections.count, 1, "one objection")
        t.equal(s.objections.first?.withdrawnAt, claimAt.addingTimeInterval(4 * day), "the withdrawal is matched to it")
        t.equal(s.authorizations.count, 2, "two authorizations")
        t.check(s.releasedAt == nil, "not released")
        // Pause of 2 days slides open from +35 to +37, so both taps count.
        t.equal(ReleaseMachine.state(s, now: openAt.addingTimeInterval(2 * day)), .authorized, "the feed and the machine agree: authorized")
        // The owner shows up.
        var withHeartbeat = events
        withHeartbeat.append(try owner.event(.heartbeat, estate: "E", prev: prev, at: openAt.addingTimeInterval(2 * day)))
        let s2 = ReleaseFeed.snapshot(events: withHeartbeat, ownerHash: owner.hash, fallbackPolicy: policy, estateCreatedAt: t0, timeOf: { $0.occurredAt })
        t.equal(ReleaseMachine.state(s2, now: openAt.addingTimeInterval(3 * day)), .cancelled, "a heartbeat after two taps still cancels")
        // Events are consumed in time order regardless of array order.
        let s3 = ReleaseFeed.snapshot(events: withHeartbeat.reversed(), ownerHash: owner.hash, fallbackPolicy: policy, estateCreatedAt: t0, timeOf: { $0.occurredAt })
        t.equal(s3, s2, "array order does not matter")
    }

    // MARK: - Audit C1: a release counts only when it was earned

    /// A `released` event is honored only when its key matches the owner's
    /// signed commitment, the claimant sent it, and the claim stood
    /// authorized. Mostly at a rule of one, the sharpest case.
    static func releaseAdmission(_ t: SelfTest.Context) throws {
        let owner = Actor(), brother = Actor(), wife = Actor()
        let day: TimeInterval = 86_400
        let realKey = Data(repeating: 7, count: 32)
        let garbage = Data(repeating: 9, count: 32)
        let policy = ReleasePolicy(threshold: 1)

        func start(threshold: Int) throws -> [EstateEvent] {
            let epoch = EpochBody(epoch: 1, threshold: threshold, custodianHashes: [brother.hash, wife.hash],
                                  custodianPublicKeys: [Data(), Data()], shareCommitments: [Data(), Data()],
                                  estateKeyCommitment: Data(SHA256.hash(data: realKey)), materialDigest: Data())
            return [
                try owner.event(.estateCreated, estate: "E", prev: Data(),
                                payload: try EstateEvent.encodeBody(EstateCreatedBody(policy: policy, createdAtEpoch: RecordEvent.epochSeconds(t0))), at: t0),
                try owner.event(.epochPublished, estate: "E", prev: Data(), payload: try EstateEvent.encodeBody(epoch), at: t0.addingTimeInterval(60)),
                try owner.event(.heartbeat, estate: "E", prev: Data(), at: t0.addingTimeInterval(7 * day)),
            ]
        }
        func claim(_ who: Actor, at: Date) throws -> EstateEvent {
            try who.event(.releaseClaimed, estate: "E", prev: Data(),
                          payload: try EstateEvent.encodeBody(ClaimBody(claimID: "c1", epoch: 1, lastHeartbeatAtEpoch: nil, reason: "")), at: at)
        }
        func tap(_ who: Actor, at: Date) throws -> EstateEvent {
            try who.event(.authorization, estate: "E", prev: Data(),
                          payload: try EstateEvent.encodeBody(AuthorizationBody(claimID: "c1", epoch: 1, recordHeadDigest: Data(),
                                                                               assertion: who.root.assertion(challenge: Data(repeating: 1, count: 32)),
                                                                               shareForClaimant: [])), at: at)
        }
        func release(_ who: Actor, key: Data, at: Date) throws -> EstateEvent {
            try who.event(.released, estate: "E", prev: Data(),
                          payload: try EstateEvent.encodeBody(ReleasedBody(claimID: "c1", epoch: 1, shareIndexes: [1], estateKey: key)), at: at)
        }
        func heartbeat(at: Date) throws -> EstateEvent {
            try owner.event(.heartbeat, estate: "E", prev: Data(), at: at)
        }
        /// With `phone`, times are that phone's FirstSeen view, as in the app.
        func snap(_ events: [EstateEvent], seenBy phone: FirstSeen? = nil) -> ReleaseSnapshot {
            ReleaseFeed.snapshot(events: events, ownerHash: owner.hash, fallbackPolicy: policy,
                                 estateCreatedAt: t0, timeOf: { phone?.timeOf($0) ?? $0.occurredAt })
        }

        let base = try start(threshold: 1)
        // The honest timeline: last heartbeat day 7, claim after 91 days of
        // silence, the tap after 21 days of warnings and 14 of grace.
        let claimAt = t0.addingTimeInterval((7 + 91) * day)
        let tapAt = claimAt.addingTimeInterval(35 * day + 3_600)
        let releaseAt = tapAt.addingTimeInterval(3_600)
        let honest = try base + [claim(brother, at: claimAt), tap(brother, at: tapAt)]

        // 1. The attack: claim, tap and release in one go while the owner is
        //    checking in. Nothing opens; the key is on record for the owner.
        let early = t0.addingTimeInterval(8 * day)
        let forged = try snap(base + [claim(brother, at: early), tap(brother, at: early),
                                  release(brother, key: realKey, at: early.addingTimeInterval(60))])
        t.check(forged.releasedAt == nil, "a key holder cannot release while the owner is checking in")
        t.check(ReleaseMachine.state(forged, now: early.addingTimeInterval(day)) != .released, "and no phone reads released")
        t.equal(forged.keyPublishedAt, early.addingTimeInterval(60), "but the published key is on record, so the owner can re-seal")

        // 2. The honest release is honored, with that exact event.
        let good = try release(brother, key: realKey, at: releaseAt)
        let s = snap(honest + [good])
        t.equal(s.releasedAt, releaseAt, "an earned release is honored at its own time")
        t.equal(s.releaseEventID, good.id, "and names the event the phone will open with")
        t.equal(ReleaseMachine.state(s, now: releaseAt), .released, "the machine agrees")

        // 3. A garbage key bricks nothing: ignored, and the claimant can still release.
        let junk = try snap(honest + [release(brother, key: garbage, at: releaseAt)])
        t.check(junk.releasedAt == nil, "a key that misses the commitment is ignored")
        t.check(junk.keyPublishedAt == nil, "and is not a published key")
        t.equal(ReleaseMachine.state(junk, now: releaseAt), .authorized, "the estate is still authorized, not bricked")

        // 4. Only the claimant may publish. Another key holder's release,
        //    even with the right key, does not count; the claimant's does.
        let wifeFirst = try snap(honest + [release(wife, key: realKey, at: releaseAt)])
        t.check(wifeFirst.releasedAt == nil, "a release from someone other than the claimant is ignored")
        let both = try snap(honest + [release(wife, key: realKey, at: releaseAt), good])
        t.equal(both.releaseEventID, good.id, "the claimant's own release is the one used")

        // 5. A heartbeat after the claim opened kills it, release and all.
        let alive = try snap(base + [claim(brother, at: claimAt), heartbeat(at: claimAt.addingTimeInterval(day)),
                                 tap(brother, at: tapAt), good])
        t.check(alive.releasedAt == nil, "an owner who checked in after the claim cannot be released")

        // 6. A heartbeat AFTER an earned release changes nothing: the key is out.
        let late = try snap(honest + [good, heartbeat(at: releaseAt.addingTimeInterval(day))])
        t.equal(late.releasedAt, releaseAt, "a heartbeat after an earned release does not undo it")
        t.equal(ReleaseMachine.state(late, now: releaseAt.addingTimeInterval(2 * day)), .released, "released stays terminal")

        // 7. A release dated before the tap (or a tap this phone saw late)
        //    takes effect at the tap that authorized the claim, not before.
        let premature = try snap(honest + [release(brother, key: realKey, at: claimAt.addingTimeInterval(day))])
        t.equal(premature.releasedAt, tapAt, "judged at the moment the claim became authorized")

        // 8. Dated in the future: not believed now, and the owner's normal
        //    check-ins void it before that future arrives.
        let future = t0.addingTimeInterval(200 * day)
        let ahead = try base + [claim(brother, at: future), tap(brother, at: future.addingTimeInterval(35 * day + 60)),
                            release(brother, key: realKey, at: future.addingTimeInterval(35 * day + 120))]
        t.check(ReleaseMachine.state(snap(ahead), now: early) != .released, "a release dated in the future is not believed today")
        let checkedIn = try snap(ahead + [heartbeat(at: future.addingTimeInterval(-10 * day))])
        t.check(checkedIn.releasedAt == nil, "and once the owner checks in, it never will be")

        // 9. Rule of two: one key holder alone cannot release, right key or not.
        let two = try start(threshold: 2)
        let alone = try snap(two + [claim(brother, at: claimAt), tap(brother, at: tapAt), good])
        t.check(alone.releasedAt == nil, "at a rule of two, one tap and a release are not enough")
        t.equal(ReleaseMachine.state(alone, now: releaseAt), .claimOpen, "the claim is simply still open")
        let pair = try snap(two + [claim(brother, at: claimAt), tap(brother, at: tapAt),
                               tap(wife, at: tapAt.addingTimeInterval(60)), good])
        t.equal(pair.releasedAt, releaseAt, "with both taps the same release is honored")

        // 10. A phone that was offline for the whole claim hears of the
        //     claim, the tap and the release all at once. It does not open
        //     at once: its own view of the claim runs the full 35 days first.
        //     Before the review fix it never opened at all.
        var latePhone = FirstSeen()
        latePhone.seed(base)
        let heardAt = releaseAt.addingTimeInterval(10 * day)
        latePhone.note(honest + [good], at: heardAt)
        let offline = snap(honest + [good], seenBy: latePhone)
        t.equal(offline.releasedAt, heardAt.addingTimeInterval(35 * day), "a late phone opens once its own view of the claim has run its course")
        t.check(ReleaseMachine.state(offline, now: heardAt.addingTimeInterval(day)) != .released, "and not before")
        t.equal(ReleaseMachine.state(offline, now: heardAt.addingTimeInterval(35 * day)), .released, "then it is released")

        // 11. A release dated back to just after the tap, but only published
        //     after the owner checked in, is dated by when this phone saw it.
        var watchingPhone = FirstSeen()
        let checkIn = try heartbeat(at: tapAt.addingTimeInterval(5 * day))
        let seenLive = honest + [checkIn]
        watchingPhone.seed(seenLive)
        let backdated = try release(brother, key: realKey, at: tapAt.addingTimeInterval(60))
        watchingPhone.note([backdated], at: tapAt.addingTimeInterval(6 * day))
        let overruled = snap(seenLive + [backdated], seenBy: watchingPhone)
        t.check(overruled.releasedAt == nil, "a backdated release cannot outrun the owner's check-in")

        // 12. A claim id used twice is no claim. Here the wife tapped for the
        //     first claim, the owner came back, and much later the brother
        //     reopens the SAME id and taps alone, hoping her old tap still
        //     counts. A phone that hears of all of it at once cannot tell
        //     the two apart by time, so the reused id itself is refused.
        let firstTry = try two + [claim(brother, at: claimAt), tap(wife, at: tapAt),
                                  heartbeat(at: tapAt.addingTimeInterval(day))]
        let secondClaimAt = tapAt.addingTimeInterval(200 * day)
        let reuse = try firstTry + [claim(brother, at: secondClaimAt),
                                    tap(brother, at: secondClaimAt.addingTimeInterval(35 * day + 60)),
                                    release(brother, key: realKey, at: secondClaimAt.addingTimeInterval(35 * day + 120))]
        var farPhone = FirstSeen()
        farPhone.seed(two)
        farPhone.note(reuse, at: secondClaimAt.addingTimeInterval(40 * day))
        let reused = snap(reuse, seenBy: farPhone)
        t.check(reused.claim == nil, "a reused claim id is not a live claim")
        t.check(reused.releasedAt == nil, "and cannot borrow the first claim's taps")

        // 13. Another key holder reusing the claimant's id after an earned
        //     release cannot hide it, even from a phone that hears of
        //     everything at once.
        let copycat = try claim(wife, at: releaseAt.addingTimeInterval(day))
        var offlinePhone = FirstSeen()
        offlinePhone.seed(base)
        let heardLate = releaseAt.addingTimeInterval(10 * day)
        offlinePhone.note(honest + [good, copycat], at: heardLate)
        let unhidden = snap(honest + [good, copycat], seenBy: offlinePhone)
        t.equal(unhidden.releasedAt, heardLate.addingTimeInterval(35 * day), "a copied claim id does not hide an earned release")
        t.equal(unhidden.releaseEventID, good.id, "and it is the claimant's release")

        // 14. Only the owner's newest key set can be released. A claim and a
        //     release on an older set, even with that set's real key, would
        //     read "released" with nothing to open. Refused, but the key is
        //     still on record as published.
        let newKey = Data(repeating: 8, count: 32)
        let epoch2 = EpochBody(epoch: 2, threshold: 1, custodianHashes: [brother.hash, wife.hash],
                               custodianPublicKeys: [Data(), Data()], shareCommitments: [Data(), Data()],
                               estateKeyCommitment: Data(SHA256.hash(data: newKey)), materialDigest: Data())
        let resealed = try owner.event(.epochPublished, estate: "E", prev: Data(),
                                       payload: try EstateEvent.encodeBody(epoch2), at: t0.addingTimeInterval(120))
        let stale = try snap(base + [resealed, claim(brother, at: claimAt), tap(brother, at: tapAt), good])
        t.check(stale.releasedAt == nil, "a release of an older key set is not honored")
        t.equal(stale.keyPublishedAt, releaseAt, "but its key is on record as published")
    }
}
