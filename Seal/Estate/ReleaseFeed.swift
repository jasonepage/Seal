import Foundation

//  ReleaseFeed.swift
//  Seal
//
//  FROM EVENTS TO A SNAPSHOT.
//
//  The state machine wants facts (last heartbeat, the current claim, who
//  objected, who tapped). The log has signed events. This file is the pure
//  function between them. It also decides what an event's TIME is:
//
//    - if the event carries an RFC 3161 token whose genTime can be read,
//      that is the time, because it is the one nobody's phone clock chose;
//    - otherwise the actor's own claim.
//
//  For a heartbeat this makes "the last heartbeat really was 100 days ago"
//  a statement about an authority's clock rather than a claim from the
//  owner's phone. It cannot prove a heartbeat did NOT happen; nothing can.
//  What it does is stop a custodian's phone from being the sole witness to
//  when a claim opened or when a key was tapped.

enum ReleaseFeed {

    static func effectiveTime(_ event: EstateEvent) -> Date {
        if let token = event.timestampToken,
           let stamped = TimestampDER.genTime(of: token, digest: event.digest) {
            return stamped
        }
        return event.occurredAt
    }

    /// Builds the snapshot from ADMITTED events (EstateLogVerifier ran first).
    static func snapshot(events: [EstateEvent],
                         ownerHash: String,
                         fallbackPolicy: ReleasePolicy,
                         estateCreatedAt: Date,
                         timeOf: ((EstateEvent) -> Date)? = nil) -> ReleaseSnapshot {
        let timeOf = timeOf ?? effectiveTime
        var policy = fallbackPolicy
        var createdAt = estateCreatedAt
        var lastHeartbeat: Date? = nil
        var cancellations: [Date] = []
        var claims: [ReleaseSnapshot.Claim] = []
        var objections: [(claimID: String, ReleaseSnapshot.Objection)] = []
        var withdrawals: [(claimID: String, custodianHash: String, at: Date)] = []
        var authorizations: [(claimID: String, ReleaseSnapshot.Authorization)] = []
        var releases: [(claimID: String, at: Date)] = []

        for e in events.sorted(by: { ($0.occurredAtEpoch, $0.id) < ($1.occurredAtEpoch, $1.id) }) {
            let at = timeOf(e)
            switch e.kind {
            case .estateCreated:
                if let body = e.body(EstateCreatedBody.self) {
                    policy = body.policy
                    createdAt = Date(timeIntervalSince1970: TimeInterval(body.createdAtEpoch))
                }
            case .policyChanged:
                if let body = e.body(PolicyBody.self) { policy = body.policy }
            case .heartbeat:
                lastHeartbeat = max(lastHeartbeat ?? at, at)
            case .cancellation:
                cancellations.append(at)
            case .releaseClaimed:
                if let body = e.body(ClaimBody.self) {
                    claims.append(.init(id: body.claimID, epoch: body.epoch, claimantHash: e.actorHash, openedAt: at))
                }
            case .objection:
                if let body = e.body(ObjectionBody.self), !body.withdrawn {
                    objections.append((body.claimID, .init(custodianHash: e.actorHash, at: at, withdrawnAt: nil)))
                }
            case .objectionWithdrawn:
                if let body = e.body(ObjectionBody.self) {
                    withdrawals.append((body.claimID, e.actorHash, at))
                }
            case .authorization:
                if let body = e.body(AuthorizationBody.self) {
                    authorizations.append((body.claimID, .init(custodianHash: e.actorHash, at: at)))
                }
            case .released:
                if let body = e.body(ReleasedBody.self) { releases.append((body.claimID, at)) }
            case .epochPublished:
                // The threshold travels with the shares; the days do not.
                if let body = e.body(EpochBody.self) { policy.threshold = body.threshold }
            case .vaultUpdated, .silenceObserved:
                break
            }
        }

        var snapshot = ReleaseSnapshot(policy: policy, estateCreatedAt: createdAt,
                                       lastHeartbeatAt: lastHeartbeat, claim: nil,
                                       cancellations: cancellations)
        guard let current = claims.max(by: { $0.openedAt < $1.openedAt }) else { return snapshot }
        snapshot.claim = current
        var objs = objections.filter { $0.claimID == current.id }.map(\.1)
        for w in withdrawals where w.claimID == current.id {
            // The earliest open objection by that custodian is the one withdrawn.
            if let i = objs.indices.first(where: { objs[$0].custodianHash == w.custodianHash && objs[$0].withdrawnAt == nil && objs[$0].at <= w.at }) {
                objs[i].withdrawnAt = w.at
            }
        }
        snapshot.objections = objs
        snapshot.authorizations = authorizations.filter { $0.claimID == current.id }.map(\.1)
        snapshot.releasedAt = releases.first { $0.claimID == current.id }?.at
        return snapshot
    }
}
