import Foundation

//  ReleaseMachine.swift
//  Seal
//
//  THE RELEASE STATE MACHINE (conversion brief, section 5).
//
//  A pure value computation: given what the log says (a `ReleaseSnapshot`)
//  and a `now`, what state is the estate in, and when does that change next.
//  No clock, no store, no network, no side effects. Everything else in the
//  product hangs off this file, and it is tested against every path in
//  SelfTest/ReleaseMachineTests.swift.
//
//  States: active, overdue, warning, grace, claimOpen, authorized, released,
//  cancelled, objected.
//
//  THE ASYMMETRY, WHICH IS THE POINT.
//  Stopping a release is easy: one heartbeat from the owner's phone beats
//  everything, and so does a signed cancellation. Neither needs the hardware
//  key, because a living person who lost their key must never be declared
//  dead by their own product. Starting a release is hard: a claim can only
//  open after `silenceDays`, it then runs through `warningDays` of daily
//  warnings and `graceDays` of quiet, and only then can M distinct
//  custodians tap M physical keys.
//
//  TIME. Every `Date` in a snapshot is whatever the feed layer decided the
//  event's time is: the RFC 3161 token's time when the event has one, the
//  actor's own clock otherwise. This file does not know or care which.

enum ReleaseState: String, Codable, Hashable, CaseIterable {
    case active
    case overdue
    case warning
    case grace
    case claimOpen
    case authorized
    case released
    case cancelled
    case objected

    /// True while a claim exists and has not been stopped.
    var claimIsLive: Bool {
        switch self {
        case .warning, .grace, .claimOpen, .authorized, .objected: true
        default: false
        }
    }
}

struct ReleaseSnapshot: Hashable {

    struct Claim: Hashable {
        let id: String
        let epoch: UInt64
        let claimantHash: String
        let openedAt: Date
    }

    struct Objection: Hashable {
        let custodianHash: String
        let at: Date
        var withdrawnAt: Date?
    }

    struct Authorization: Hashable {
        let custodianHash: String
        let at: Date
    }

    var policy: ReleasePolicy
    var estateCreatedAt: Date
    /// The newest owner heartbeat, or nil if the owner never sent one.
    var lastHeartbeatAt: Date?
    /// The most recently opened claim. Older claims are history.
    var claim: Claim?
    /// Owner cancellations, any time.
    var cancellations: [Date] = []
    /// Objections that name the current claim.
    var objections: [Objection] = []
    /// Authorizations that name the current claim.
    var authorizations: [Authorization] = []
    var releasedAt: Date?

    /// The moment silence started counting: the last heartbeat, or the
    /// estate's creation if there has never been one.
    var silenceAnchor: Date { lastHeartbeatAt ?? estateCreatedAt }
}

/// The dates a countdown screen shows. All nil when there is no live claim.
struct ReleaseTimeline: Hashable {
    let claimOpenedAt: Date
    /// Warnings run from `claimOpenedAt` until here.
    let warningEndsAt: Date
    /// Grace runs until here; keys can be tapped from here.
    let claimOpensAt: Date
    /// Total time the countdown has been paused by objections so far.
    let pausedTotal: TimeInterval
}

enum ReleaseMachine {

    // MARK: - Why a claim is not live

    enum ClaimVoidReason: Hashable {
        case notVoid
        case heartbeatAfterClaim
        case cancelledByOwner
        case vetoed(by: String)
        case openedTooEarly
    }

    static func voidReason(_ s: ReleaseSnapshot) -> ClaimVoidReason {
        guard let claim = s.claim else { return .notVoid }
        if let hb = s.lastHeartbeatAt, hb >= claim.openedAt { return .heartbeatAfterClaim }
        if s.cancellations.contains(where: { $0 >= claim.openedAt }) { return .cancelledByOwner }
        if s.policy.objectionBehavior == .veto,
           let veto = s.objections.first(where: { $0.at >= claim.openedAt }) {
            return .vetoed(by: veto.custodianHash)
        }
        // A claim may only open once the owner has been silent for the full
        // period. One opened early is ignored outright rather than honoured
        // with a shorter countdown.
        if claim.openedAt < s.silenceAnchor.addingTimeInterval(s.policy.silence) { return .openedTooEarly }
        return .notVoid
    }

    // MARK: - Pauses

    /// Time the countdown has been paused by objections up to `until`.
    /// Only meaningful for the `.pause` behaviour; zero for `.veto`.
    static func pausedTotal(_ s: ReleaseSnapshot, until: Date) -> TimeInterval {
        guard s.policy.objectionBehavior == .pause, let claim = s.claim else { return 0 }
        var total: TimeInterval = 0
        for o in s.objections where o.at >= claim.openedAt && o.at < until {
            let end = min(o.withdrawnAt ?? until, until)
            total += max(0, end.timeIntervalSince(o.at))
        }
        return total
    }

    static func hasOpenObjection(_ s: ReleaseSnapshot, now: Date) -> Bool {
        guard s.policy.objectionBehavior == .pause, let claim = s.claim else { return false }
        return s.objections.contains { o in
            guard o.at >= claim.openedAt, o.at <= now else { return false }
            if let withdrawn = o.withdrawnAt { return withdrawn > now }
            return true
        }
    }

    // MARK: - Timeline

    static func timeline(_ s: ReleaseSnapshot, now: Date) -> ReleaseTimeline? {
        guard let claim = s.claim, voidReason(s) == .notVoid else { return nil }
        let paused = pausedTotal(s, until: now)
        let warningEnds = claim.openedAt.addingTimeInterval(s.policy.warning + paused)
        let claimOpens = warningEnds.addingTimeInterval(s.policy.grace)
        return ReleaseTimeline(claimOpenedAt: claim.openedAt, warningEndsAt: warningEnds,
                               claimOpensAt: claimOpens, pausedTotal: paused)
    }

    /// The authorizations that count: distinct custodians, each tapped once
    /// the claim was actually open at the moment they tapped.
    static func validAuthorizations(_ s: ReleaseSnapshot, now: Date) -> [ReleaseSnapshot.Authorization] {
        guard let claim = s.claim, voidReason(s) == .notVoid else { return [] }
        var seen = Set<String>()
        var out: [ReleaseSnapshot.Authorization] = []
        for a in s.authorizations.sorted(by: { $0.at < $1.at }) where a.at <= now {
            let pausedBefore = pausedTotal(s, until: a.at)
            let openAt = claim.openedAt.addingTimeInterval(s.policy.warning + s.policy.grace + pausedBefore)
            // A tap made while an objection was open does not count: the
            // countdown was paused, so the claim was not open at that moment.
            guard a.at >= openAt, !hasOpenObjection(s, now: a.at),
                  seen.insert(a.custodianHash).inserted else { continue }
            out.append(a)
        }
        return out
    }

    // MARK: - The state

    static func state(_ s: ReleaseSnapshot, now: Date) -> ReleaseState {
        if s.releasedAt != nil { return .released }

        let silentFor = now.timeIntervalSince(s.silenceAnchor)
        let overdue = silentFor > s.policy.silence

        guard let claim = s.claim else { return overdue ? .overdue : .active }

        switch voidReason(s) {
        case .heartbeatAfterClaim, .cancelledByOwner:
            // The owner stopped it. Show that until silence starts again.
            return overdue ? .overdue : .cancelled
        case .vetoed:
            return .objected
        case .openedTooEarly:
            return overdue ? .overdue : .active
        case .notVoid:
            break
        }

        if now < claim.openedAt { return overdue ? .overdue : .active }
        if hasOpenObjection(s, now: now) { return .objected }
        guard let t = timeline(s, now: now) else { return .overdue }
        if now < t.warningEndsAt { return .warning }
        if now < t.claimOpensAt { return .grace }
        return validAuthorizations(s, now: now).count >= s.policy.threshold ? .authorized : .claimOpen
    }

    /// When the state next changes with nobody doing anything, or nil if it
    /// will not (a stopped claim, a release, an open objection).
    static func nextTransition(_ s: ReleaseSnapshot, now: Date) -> Date? {
        switch state(s, now: now) {
        case .active, .cancelled:
            return s.silenceAnchor.addingTimeInterval(s.policy.silence)
        case .warning:
            return timeline(s, now: now)?.warningEndsAt
        case .grace:
            return timeline(s, now: now)?.claimOpensAt
        case .overdue, .claimOpen, .authorized, .released, .objected:
            return nil
        }
    }

    // MARK: - What each party may do now

    static func ownerCanCancel(_ s: ReleaseSnapshot, now: Date) -> Bool {
        state(s, now: now).claimIsLive
    }

    static func custodianCanClaim(_ s: ReleaseSnapshot, now: Date) -> Bool {
        state(s, now: now) == .overdue
    }

    static func custodianCanAuthorize(_ s: ReleaseSnapshot, now: Date, custodianHash: String) -> Bool {
        let st = state(s, now: now)
        guard st == .claimOpen || st == .authorized else { return false }
        return !validAuthorizations(s, now: now).contains { $0.custodianHash == custodianHash }
    }

    static func claimantCanRelease(_ s: ReleaseSnapshot, now: Date) -> Bool {
        state(s, now: now) == .authorized
    }

    /// Days the owner has been silent, for the overdue screens. Whole days,
    /// rounded down, never negative.
    static func silentDays(_ s: ReleaseSnapshot, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(s.silenceAnchor) / 86_400))
    }
}
