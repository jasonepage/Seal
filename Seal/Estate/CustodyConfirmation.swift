// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  CustodyConfirmation.swift
//  Seal
//
//  KEY HOLDERS WHO REMEMBER THEY ARE KEY HOLDERS.
//
//  A key handed over at a kitchen table in 2026 is in a drawer somewhere
//  by 2030, or was lost in a move, and nobody finds out until the day it
//  is needed. So once a year (the owner sets the interval in the rule),
//  each key holder's phone asks them to tap their key. The tap is a
//  WebAuthn assertion by their root credential and goes into the record
//  as a signed line: a custody receipt. The owner's home screen shows
//  each key holder's last confirmation, and names the one who is overdue
//  with a plain next step.
//
//  WHAT THIS IS NOT. It is not a tap toward a release, and it cannot be
//  mistaken for one:
//
//    1. It is its own event kind (`custodyConfirmed`). ReleaseFeed lists
//       it under the kinds it ignores, so ReleaseSnapshot never sees it
//       and ReleaseMachine cannot count it. Tests prove M confirmations
//       during an open claim leave the state exactly where it was.
//    2. The challenge lives in a different domain string,
//       `seal.custody.confirm.v1`, and names no claim. An authorization's
//       challenge is `seal.release.authorize.v1` over the claim id. The
//       same key tapping over the same estate produces different bytes,
//       so a confirmation can never be replayed as an authorization, and
//       `verifiedAuthorizations` would reject it anyway because it checks
//       the release challenge.
//    3. It carries no share. An authorization carries the custodian's
//       Shamir share re-wrapped to the claimant. A confirmation carries a
//       signature and nothing else, so even a bug that counted it could
//       not combine anything.
//
//  And it reveals nothing about the envelopes to the key holder, because
//  it reads nothing: it is signed over the estate id, the epoch and the
//  record head, all of which the key holder's phone already holds.

struct CustodyConfirmedBody: Codable, Hashable {
    let epoch: UInt64
    /// The record head the key holder's phone was at when they tapped.
    let recordHeadDigest: Data
    /// The key holder's ROOT credential assertion over
    /// `CustodyConfirmation.challenge(...)`. The physical tap.
    let assertion: WebAuthnAssertion
}

enum CustodyConfirmation {

    static let domain = "seal.custody.confirm.v1"

    /// Binds estate, epoch and record head. No claim id: there is no claim.
    static func challenge(estateID: String, epoch: UInt64, recordHeadDigest: Data) -> Data {
        var input = Data(domain.utf8)
        func field(_ data: Data) {
            var length = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(data)
        }
        field(Data(estateID.utf8))
        field(Data(String(epoch).utf8))
        field(recordHeadDigest)
        return Data(SHA256.hash(data: input))
    }

    /// Interval in seconds. A month is thirty days here, as in SecretReview.
    static func interval(months: Int) -> TimeInterval { TimeInterval(months) * 30 * 86_400 }

    /// The newest confirmation per custodian, from ADMITTED events, using
    /// the feed's notion of time. Pure.
    static func latest(events: [EstateEvent], timeOf: (EstateEvent) -> Date = ReleaseFeed.effectiveTime) -> [String: Date] {
        var out: [String: Date] = [:]
        for e in events where e.kind == .custodyConfirmed {
            let at = timeOf(e)
            out[e.actorHash] = max(out[e.actorHash] ?? at, at)
        }
        return out
    }

    /// The newest confirmation by one custodian whose tap really verifies
    /// under the given root public key over the challenge it claims. The
    /// owner's screen uses this, so a line that says "confirmed" means a
    /// key was physically tapped, not only that a phone signed something.
    static func latestVerified(events: [EstateEvent], estateID: String, custodianHash: String,
                               rootPublicKey: Data, timeOf: (EstateEvent) -> Date = ReleaseFeed.effectiveTime) -> Date? {
        guard let key = try? P256.Signing.PublicKey(rawRepresentation: rootPublicKey) else { return nil }
        var newest: Date?
        for e in events where e.kind == .custodyConfirmed && e.actorHash == custodianHash {
            guard let body = e.body(CustodyConfirmedBody.self) else { continue }
            let expected = challenge(estateID: estateID, epoch: body.epoch, recordHeadDigest: body.recordHeadDigest)
            guard body.assertion.verify(with: key),
                  CeremonyManager.clientDataChallengeMatches(body.assertion.clientDataJSON, expected: expected) else { continue }
            let at = timeOf(e)
            newest = max(newest ?? at, at)
        }
        return newest
    }

    /// What the owner's screen says about one key holder. `since` is the
    /// last verified confirmation, or the handover date when there has
    /// never been one. Nil means nothing to say (checked recently).
    struct Standing: Hashable {
        let line: String
        let overdue: Bool
    }

    static func standing(name: String, lastConfirmed: Date?, handedOverAt: Date, months: Int, now: Date) -> Standing {
        let since = lastConfirmed ?? handedOverAt
        let overdue = now.timeIntervalSince(since) > interval(months: months)
        if let lastConfirmed {
            let ago = SecretAge.ago(since: lastConfirmed, now: now)
            return overdue
                ? Standing(line: "Last confirmed their key \(ago). Ask \(name) if they still have it.", overdue: true)
                : Standing(line: "Confirmed they still have their key \(ago).", overdue: false)
        }
        let ago = SecretAge.ago(since: handedOverAt, now: now)
        return overdue
            ? Standing(line: "Has never confirmed their key since you handed it over \(ago). Ask \(name) if they still have it.", overdue: true)
            : Standing(line: "Handed the key \(ago). Their phone will ask them to confirm it every \(months == 12 ? "year" : "\(months) months").", overdue: false)
    }

    /// Whether a key holder's phone should be asking now.
    static func isDue(lastConfirmed: Date?, since fallback: Date, months: Int, now: Date) -> Bool {
        now.timeIntervalSince(lastConfirmed ?? fallback) > interval(months: months)
    }
}
