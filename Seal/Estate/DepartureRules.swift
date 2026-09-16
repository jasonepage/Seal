// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  DepartureRules.swift
//  Seal
//
//  WHEN THE OWNER DELETES THEIR SEAL ACCOUNT.
//
//  The delete screen asks one question: keep the envelopes for the family,
//  or cancel them. The answer goes into the owner's record as a signed
//  `ownerDeparted` entry, written by the owner's own phone just before it
//  wipes itself. Every key holder and recipient sees it in "What has
//  happened".
//
//  KEEP. Nothing about the rule changes. The owner can never check in
//  again, so the countdown can only run out: the entry itself is the last
//  sign of life (ReleaseFeed counts any owner entry), and a key holder may
//  start a claim once the silence period has passed from it. The warnings,
//  the grace and the M key taps all still apply.
//
//  CANCEL. The owner's phone removes every sealed blob it uploaded (key
//  material, key tables, contents), so there is nothing left to open, and
//  EstateEngine refuses every claim, tap and release on the key holders'
//  phones. If any removal failed (a blob another iCloud account saved),
//  the engine's refusal still stands for every honest copy of the app.
//
//  A signed cancel wins over a signed keep, whatever the order: when in
//  doubt, nothing opens. A check-in AFTER the entry voids it: the delete
//  did not finish and the owner is still here. (If they had cancelled, the
//  sealed material is gone, and their next seal rotates to fresh keys, the
//  same repair EstateEngine already makes for missing material.)
//  ReleaseMachine is not changed by any of this.

enum DepartureRules {

    struct Departure: Hashable {
        let at: Date
        let keepEnvelopes: Bool
    }

    /// The owner's departure, from ADMITTED events (EstateLogVerifier has
    /// already checked the owner signed them). Nil if the owner is still here.
    static func departure(events: [EstateEvent], ownerHash: String) -> Departure? {
        let mine = events.filter { $0.kind == .ownerDeparted && $0.actorHash == ownerHash }
        guard let latest = mine.max(by: { ($0.occurredAtEpoch, $0.id) < ($1.occurredAtEpoch, $1.id) }) else {
            return nil
        }
        // The owner checked in after writing it: the delete never finished
        // (the entry landed, the tombstone did not), and they are still here.
        let leftAt = ReleaseFeed.effectiveTime(latest)
        if events.contains(where: { $0.kind == .heartbeat && $0.actorHash == ownerHash
                                    && ReleaseFeed.effectiveTime($0) > leftAt }) {
            return nil
        }
        // An entry whose body does not parse is treated as a cancel.
        let anyCancel = mine.contains { ($0.body(DepartureBody.self)?.keepEnvelopes ?? false) == false }
        return Departure(at: leftAt, keepEnvelopes: !anyCancel)
    }

    /// False once the owner cancelled.
    static func openingAllowed(events: [EstateEvent], ownerHash: String) -> Bool {
        departure(events: events, ownerHash: ownerHash)?.keepEnvelopes ?? true
    }

    /// When a key holder may first start a claim.
    static func earliestClaim(_ s: ReleaseSnapshot) -> Date {
        s.silenceAnchor.addingTimeInterval(s.policy.silence)
    }

    /// When the envelopes could first open, if a claim starts on the first
    /// possible day and nobody objects.
    static func earliestOpening(_ s: ReleaseSnapshot) -> Date {
        earliestClaim(s).addingTimeInterval(s.policy.warning + s.policy.grace)
    }

    /// The line for "What has happened".
    static func historyLine(name: String, keep: Bool) -> String {
        keep
            ? "\(name) deleted their Seal account and kept the envelopes for their family."
            : "\(name) deleted their Seal account and cancelled the envelopes."
    }
}
