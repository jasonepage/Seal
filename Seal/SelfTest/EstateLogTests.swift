import Foundation
import CryptoKit

//  EstateLogTests.swift
//  Seal
//
//  The signed log: digests, links, who may write what, and the feed that
//  turns events into a state machine snapshot.

enum EstateLogTests {

    static let suites: [SelfTest.Suite] = [
        .init(name: "estatelog.signing", run: signing),
        .init(name: "estatelog.admission", run: admission),
        .init(name: "estatelog.feed", run: feed),
        .init(name: "estatelog.genTime", run: genTime),
    ]

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
                                                                                assertion: wife.root.assertion(challenge: Data(repeating: 1, count: 32)))), at: openAt))
        add(try brother.event(.authorization, estate: "E", prev: prev,
                              payload: try EstateEvent.encodeBody(AuthorizationBody(claimID: "c1", epoch: 1, recordHeadDigest: prev,
                                                                                   assertion: brother.root.assertion(challenge: Data(repeating: 1, count: 32)))), at: openAt.addingTimeInterval(day)))

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

    static func genTime(_ t: SelfTest.Context) throws {
        // A minimal TSTInfo tail: ... messageImprint ends with the digest,
        // then INTEGER serial, then GeneralizedTime. The parser walks from
        // the digest, so the bytes before it can be anything.
        let digest = Data(SHA256.hash(data: Data("x".utf8)))
        let serial: [UInt8] = [0x02, 0x01, 0x07]
        let time = Array("20260915120000Z".utf8)
        let token = Data([0x30, 0x10, 0x04, 0x20]) + digest + Data(serial) + Data([0x18, UInt8(time.count)]) + Data(time)
        let parsed = TimestampDER.genTime(of: token, digest: digest)
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 15; c.hour = 12
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        t.equal(parsed, cal.date(from: c), "genTime parses YYYYMMDDHHMMSSZ after the serial")
        t.check(TimestampDER.genTime(of: token, digest: Data(repeating: 9, count: 32)) == nil, "wrong digest: nil")
        let noTime = Data([0x04, 0x20]) + digest + Data(serial) + Data([0x02, 0x01, 0x01])
        t.check(TimestampDER.genTime(of: noTime, digest: digest) == nil, "no GeneralizedTime: nil")
        let fractional = Data([0x04, 0x20]) + digest + Data(serial) + Data([0x18, 19]) + Data("20260915120000.123Z".utf8)
        t.equal(TimestampDER.genTime(of: fractional, digest: digest), cal.date(from: c), "fractional seconds are ignored")
        // The feed prefers the token time.
        let actor = Actor()
        var e = try actor.event(.heartbeat, estate: "E", prev: Data(), at: t0)
        let stamped = Data([0x04, 0x20]) + e.digest + Data(serial) + Data([0x18, UInt8(time.count)]) + Data(time)
        e.timestampToken = stamped
        t.equal(ReleaseFeed.effectiveTime(e), cal.date(from: c), "effective time is the authority's when a token is present")
    }
}
