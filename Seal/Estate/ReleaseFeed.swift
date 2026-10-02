// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  ReleaseFeed.swift
//  Seal
//
//  FROM EVENTS TO A SNAPSHOT.
//
//  The state machine wants facts (last heartbeat, the current claim, who
//  objected, who tapped). The log has signed events. This file is the pure
//  function between them. It also decides what an event's TIME is:
//
//    - if the event carries an RFC 3161 token whose signature verifies on
//      this phone under the pinned authority (TimestampVerifier.swift),
//      its genTime is the time, because it is the one nobody's phone clock
//      chose;
//    - otherwise the actor's own claim.
//
//  For a heartbeat this makes "the last heartbeat really was 100 days ago"
//  a statement about an authority's clock rather than a claim from the
//  owner's phone. It cannot prove a heartbeat did NOT happen; nothing can.
//  What it does is stop a custodian's phone from being the sole witness to
//  when a claim opened or when a key was tapped.

enum ReleaseFeed {

    /// Pure, so it can be handed around as a plain function value (the
    /// `timeOf` parameter below) without an actor hop.
    nonisolated static func effectiveTime(_ event: EstateEvent) -> Date {
        // The authority's time only when its signature checks out on this
        // phone (audit H2, TimestampVerifier.swift). An unverified token is
        // treated as no token: the actor's own signed clock.
        if let token = event.timestampToken,
           let stamped = TimestampVerifier.verifiedGenTime(token: token, digest: event.digest) {
            return stamped
        }
        return event.occurredAt
    }

    /// What this file needs from an event's payload, decoded ONCE per
    /// snapshot. Judging a release replays the log several times, and
    /// decoding JSON on every replay is what let a flooded log stall a
    /// phone (audit C1 review, B1).
    private enum Body {
        /// Nothing this file reads, or a payload that did not decode.
        case other
        case created(EstateCreatedBody)
        case policy(ReleasePolicy)
        case claim(ClaimBody)
        case objection(ObjectionBody)
        case authorization(claimID: String)
        case released(ReleasedBody)
        case epoch(EpochBody)
    }

    /// One admitted event, the time this phone gives it, and its payload.
    private struct Timed {
        let event: EstateEvent
        let at: Date
        let body: Body
    }

    private static func decode(_ e: EstateEvent) -> Body {
        switch e.kind {
        case .estateCreated:
            return e.body(EstateCreatedBody.self).map { Body.created($0) } ?? .other
        case .policyChanged:
            return e.body(PolicyBody.self).map { Body.policy($0.policy) } ?? .other
        case .releaseClaimed:
            return e.body(ClaimBody.self).map { Body.claim($0) } ?? .other
        case .objection, .objectionWithdrawn:
            return e.body(ObjectionBody.self).map { Body.objection($0) } ?? .other
        case .authorization:
            return e.body(AuthorizationBody.self).map { Body.authorization(claimID: $0.claimID) } ?? .other
        case .released:
            return e.body(ReleasedBody.self).map { Body.released($0) } ?? .other
        case .epochPublished:
            return e.body(EpochBody.self).map { Body.epoch($0) } ?? .other
        default:
            return .other
        }
    }

    /// Builds the snapshot from ADMITTED events (EstateLogVerifier ran first).
    ///
    /// AUDIT C1. Admission only proves an event was signed by a key holder's
    /// endorsed phone. It says nothing about whether a `released` event was
    /// EARNED. Before this, the first `released` event naming the current
    /// claim set `releasedAt`, and the machine stops at `releasedAt` before
    /// it looks at heartbeats, cancellations or objections. So one key holder
    /// running their own code could publish a claim and a release together
    /// and every phone in the estate read "released" for good, with a
    /// garbage key (nothing ever opens) or, at a rule of one, the real one.
    ///
    /// A `released` event is honored now only when ALL of these hold:
    ///   1. its Estate Key hashes to the `estateKeyCommitment` in the
    ///      owner's signed epoch statement for the epoch it names, and that
    ///      epoch is the owner's newest;
    ///   2. its publisher opened the claim it names, once, for that same
    ///      epoch (the release is judged against that claim, not whatever
    ///      claim is newest, so a newer claim cannot hide it);
    ///   3. fed only the events up to that moment, the machine says the
    ///      release was earned then (`ReleaseMachine.releaseEarned`): the
    ///      claim ran its full course on this phone with no word from the
    ///      owner, and enough key holders tapped.
    /// The moment is the release's own time, or the first later moment (a
    /// tap, a withdrawn objection, the claim opening on this phone) at which
    /// it was earned. This phone may have heard of the claim, the taps and
    /// the release late, and FirstSeen dates each from then. Events
    /// after that moment cannot undo it: the key is out, and "released is
    /// terminal" still holds. `releasedAt` is that moment; the machine only
    /// believes it once the clock reaches it, so a release dated in the
    /// future proves nothing until the future arrives.
    ///
    /// Anything that fails is ignored for `releasedAt`. A key that matches
    /// the commitment is still recorded in `keyPublishedAt` however it got
    /// there, because the owner must never seal more into a set whose key
    /// is public.
    static func snapshot(events: [EstateEvent],
                         ownerHash: String,
                         fallbackPolicy: ReleasePolicy,
                         estateCreatedAt: Date,
                         timeOf: ((EstateEvent) -> Date)? = nil) -> ReleaseSnapshot {
        let timeOf = timeOf ?? effectiveTime
        let timed = events
            .sorted(by: { ($0.occurredAtEpoch, $0.id) < ($1.occurredAtEpoch, $1.id) })
            .map { Timed(event: $0, at: timeOf($0), body: decode($0)) }
        var snapshot = base(timed, ownerHash: ownerHash, fallbackPolicy: fallbackPolicy, estateCreatedAt: estateCreatedAt)

        // One pass for everything judging needs: the owner's signed Estate
        // Key commitments and thresholds per epoch (a seal retried after a
        // lost reply can leave two statements under one number, both
        // signed), who opened which claim, who tapped which claim, and the
        // moments at which the answer about a claim can change.
        var commitments: [UInt64: Set<Data>] = [:]
        var thresholds: [UInt64: Int] = [:]
        var opened: [String: (count: Int, epoch: UInt64)] = [:]    // "claimID|claimant"
        var tappers: [String: Set<String>] = [:]                     // claimID: key holders
        var claimMoments: [String: [Date]] = [:]                     // claimID: taps, withdrawals
        var releases: [(timed: Timed, body: ReleasedBody)] = []
        for t in timed {
            switch t.body {
            case .epoch(let body):
                guard t.event.actorHash == ownerHash else { break }
                commitments[body.epoch, default: []].insert(body.estateKeyCommitment)
                thresholds[body.epoch] = min(thresholds[body.epoch] ?? body.threshold, body.threshold)
            case .claim(let body):
                let key = body.claimID + "|" + t.event.actorHash
                opened[key] = (count: (opened[key]?.count ?? 0) + 1, epoch: body.epoch)
            case .authorization(let claimID):
                tappers[claimID, default: []].insert(t.event.actorHash)
                claimMoments[claimID, default: []].append(t.at)
            case .objection(let body):
                if t.event.kind == .objectionWithdrawn { claimMoments[body.claimID, default: []].append(t.at) }
            case .released(let body):
                releases.append((timed: t, body: body))
            case .other, .created, .policy:
                break
            }
        }

        // Only the owner's newest key set can be released. Every owner event
        // restarts the silence clock, so an honest claim always names the
        // newest epoch. A release of an older set would publish a key the
        // envelopes are no longer wrapped under, and every phone would read
        // "released" with nothing to open. Its key still counts as published
        // below, because a phone that kept an old wrap could use it.
        let newestEpoch = commitments.keys.max()

        // Rule 1 for every release, whoever sent it and whenever.
        let genuine = releases.filter {
            commitments[$0.body.epoch]?.contains(Data(SHA256.hash(data: $0.body.estateKey))) == true
        }
        snapshot.keyPublishedAt = genuine.map(\.timed.at).min()

        // Rules 2 and 3. Necessary conditions first, so a flood of releases
        // costs one look each and not a replay each: the newest key set, a
        // sender who opened the claim it names exactly once and for that
        // same set, and at least as many key holders who ever tapped that
        // claim as the rule needs. Then the earliest such release per sender
        // and claim, those naming the current claim first, then by time.
        var earliest: [String: (timed: Timed, body: ReleasedBody)] = [:]
        for g in genuine {
            let sender = g.timed.event.actorHash
            guard g.body.epoch == newestEpoch,
                  let open = opened[g.body.claimID + "|" + sender], open.count == 1, open.epoch == g.body.epoch,
                  (tappers[g.body.claimID]?.count ?? 0) >= max(1, thresholds[g.body.epoch] ?? snapshot.policy.threshold)
            else { continue }
            let key = sender + "|" + g.body.claimID
            if let have = earliest[key], (have.timed.at, have.timed.event.id) <= (g.timed.at, g.timed.event.id) { continue }
            earliest[key] = g
        }
        let currentClaimID = snapshot.claim?.id
        let ordered = earliest.values.sorted { a, b in
            let aCurrent = a.body.claimID == currentClaimID, bCurrent = b.body.claimID == currentClaimID
            if aCurrent != bCurrent { return aCurrent }
            return (a.timed.at, a.timed.event.id) < (b.timed.at, b.timed.event.id)
        }

        // Each sender has their own allowance of replays, so one key holder's
        // junk can never use up what an honest claimant's release needs
        // (audit C1 review, B1). The whole snapshot has a ceiling as well.
        var budget = maxJudgements
        var left: [String: Int] = [:]
        for (candidate, body) in ordered {
            guard budget > 0 else { break }
            let sender = candidate.event.actorHash
            var senderLeft = left[sender] ?? maxJudgementsPerSender
            guard senderLeft > 0 else { continue }
            var ownBudget = maxJudgementsPerRelease
            // The moments at which the answer can change: the release itself,
            // and every later tap or withdrawn objection on its claim. The
            // moment the claim opens on THIS phone is added when it is found.
            var moments = Set((claimMoments[body.claimID] ?? []).filter { $0 > candidate.at })
            moments.insert(candidate.at)
            var tried = Set<Date>()
            while budget > 0, senderLeft > 0, ownBudget > 0, let moment = moments.subtracting(tried).min() {
                tried.insert(moment)
                budget -= 1
                senderLeft -= 1
                ownBudget -= 1
                let then = base(timed.filter { $0.at <= moment }, ownerHash: ownerHash,
                                fallbackPolicy: fallbackPolicy, estateCreatedAt: estateCreatedAt,
                                focus: (claimID: body.claimID, claimantHash: sender))
                guard let claim = then.claim,
                      claim.id == body.claimID,
                      claim.epoch == body.epoch,
                      claim.claimantHash == sender else { continue }
                if ReleaseMachine.releaseEarned(then, at: moment) {
                    snapshot.releasedAt = moment
                    snapshot.releaseEventID = candidate.event.id
                    return snapshot
                }
                // Not open yet on this phone: judge again the moment it opens.
                // While an objection stands the opening keeps sliding, so
                // wait for its withdrawal instead (already a moment above).
                if !ReleaseMachine.hasOpenObjection(then, now: moment),
                   let opens = ReleaseMachine.timeline(then, now: moment)?.claimOpensAt, opens > moment {
                    moments.insert(opens)
                }
            }
            left[sender] = senderLeft
        }
        return snapshot
    }

    /// Ceilings on how many replays one snapshot may run: per release, per
    /// sender, and in all. An honest estate needs a handful. A key holder who
    /// floods the log spends only their own allowance.
    private static let maxJudgementsPerRelease = 32
    private static let maxJudgementsPerSender = 128
    private static let maxJudgements = 1_024

    /// Everything but the release: policy, silence, the current claim and
    /// what has been said about it. `timed` is already in log order.
    ///
    /// With `focus`, the claim is that claimant's claim with that id rather
    /// than the newest claim. A release is judged against the claim it
    /// names, so another key holder opening a newer claim, or reusing the
    /// id, cannot hide an earned release (audit C1 review).
    private static func base(_ timed: [Timed],
                             ownerHash: String,
                             fallbackPolicy: ReleasePolicy,
                             estateCreatedAt: Date,
                             focus: (claimID: String, claimantHash: String)? = nil) -> ReleaseSnapshot {
        var policy = fallbackPolicy
        var createdAt = estateCreatedAt
        var lastHeartbeat: Date? = nil
        var cancellations: [Date] = []
        var claims: [ReleaseSnapshot.Claim] = []
        var objections: [(claimID: String, ReleaseSnapshot.Objection)] = []
        var withdrawals: [(claimID: String, custodianHash: String, at: Date)] = []
        var authorizations: [(claimID: String, ReleaseSnapshot.Authorization)] = []
        var claimEvents: [String: Set<String>] = [:]

        for t in timed {
            let e = t.event
            let at = t.at
            // ANY event the owner's phone signed is proof the owner was alive
            // at that moment, so every one of them moves the silence clock,
            // not just the heartbeat. Before this, a key holder's phone that
            // saw an epoch and a vault statement but no heartbeat (the first
            // minutes after a seal, or a log whose estateCreated went to the
            // other CloudKit environment) anchored silence at the beginning
            // of time and reported the owner ninety days overdue on day one.
            // A key holder's first notification from Seal was a false alarm.
            if e.actorHash == ownerHash {
                lastHeartbeat = max(lastHeartbeat ?? at, at)
            }
            switch e.kind {
            case .estateCreated:
                if case .created(let body) = t.body {
                    policy = body.policy
                    createdAt = Date(timeIntervalSince1970: TimeInterval(body.createdAtEpoch))
                }
            case .policyChanged:
                if case .policy(let changed) = t.body { policy = changed }
            case .heartbeat:
                lastHeartbeat = max(lastHeartbeat ?? at, at)
            case .cancellation:
                cancellations.append(at)
            case .releaseClaimed:
                if case .claim(let body) = t.body {
                    claims.append(.init(id: body.claimID, epoch: body.epoch, claimantHash: e.actorHash, openedAt: at))
                    claimEvents[body.claimID + "|" + e.actorHash, default: []].insert(e.id)
                }
            case .objection:
                if case .objection(let body) = t.body, !body.withdrawn {
                    objections.append((body.claimID, .init(custodianHash: e.actorHash, at: at, withdrawnAt: nil)))
                }
            case .objectionWithdrawn:
                if case .objection(let body) = t.body {
                    withdrawals.append((body.claimID, e.actorHash, at))
                }
            case .authorization:
                if case .authorization(let claimID) = t.body {
                    authorizations.append((claimID, .init(custodianHash: e.actorHash, at: at)))
                }
            case .released:
                // Judged in `snapshot`, never taken on its word (audit C1).
                break
            case .epochPublished:
                // The threshold travels with the shares; the days do not.
                if case .epoch(let body) = t.body { policy.threshold = body.threshold }
            case .vaultUpdated, .silenceObserved:
                break
            case .ownerDeparted:
                // The owner deleted their account (DepartureRules.swift).
                // Counted above as the owner's last sign of life, like any
                // owner event, and nothing more here. Whether the envelopes
                // may still open is the engine's decision, not the machine's.
                break
            case .custodyConfirmed:
                // A key holder saying "I still have my key". Evidence for
                // the owner's screen (CustodyConfirmation.swift), never a
                // tap toward a release. Listed here on purpose so the
                // compiler makes the next person read this line.
                break
            }
        }

        var snapshot = ReleaseSnapshot(policy: policy, estateCreatedAt: createdAt,
                                       lastHeartbeatAt: lastHeartbeat, claim: nil,
                                       cancellations: cancellations)
        let chosen: ReleaseSnapshot.Claim?
        if let focus = focus {
            chosen = claims.first { $0.id == focus.claimID && $0.claimantHash == focus.claimantHash }
        } else {
            chosen = claims.max(by: { $0.openedAt < $1.openedAt })
        }
        // A claimant who opens the same claim id twice gets no claim from it.
        // The app makes a fresh UUID for every claim, and a reused id would
        // carry the taps made for the first claim, and the shares wrapped to
        // that claimant for it, over to the second (audit C1 review). They
        // may simply open a new claim.
        guard let current = chosen,
              claimEvents[current.id + "|" + current.claimantHash]?.count == 1 else { return snapshot }
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
        return snapshot
    }
}
