// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  FirstSeen.swift
//  Seal
//
//  NO PHONE CAN BE TOLD A CLAIM IS OLDER THAN THE DAY IT LEARNED OF IT
//  (docs/REVIEW.md, finding 1).
//
//  The feed takes an event's time from its RFC 3161 token when it has one
//  and from the actor's own clock otherwise. A key holder who writes a
//  claim dated forty days ago, on a claim made today, would put every
//  phone straight past the warnings and the grace: "keys can be tapped
//  now" with no warning ever sent. So each phone keeps one small table,
//  the day it first saw each event, and for the two kinds a stranger's
//  clock must not shorten (the claim and the taps) the time used is never
//  earlier than that day. The owner's phone therefore runs the whole
//  warning period from the day it learned of the claim, and a key
//  holder's phone counts no tap before its own view of the claim has
//  aged. Heartbeats keep the token-or-claimed rule: the owner backdating
//  their own life is not a threat to anyone.
//
//  Events this phone signed are first seen at their own time, so nothing
//  changes for the writer. Events already on the phone when this table
//  was introduced are seeded at their own time too, once, so an upgrade
//  does not restart a claim that everyone had already been warned about.
//
//  ReleaseMachine and ReleaseFeed are untouched; this is only the `timeOf`
//  function the engine hands to the feed. Keychain JSON under the engine's
//  store hash, wiped with the estate.

struct FirstSeen: Codable, Hashable {
    /// Event id to the moment this phone first held it.
    var byEventID: [String: Date] = [:]

    /// The kinds whose time may not be earlier than this phone's own
    /// first sight of them.
    static let clampedKinds: Set<EstateEvent.Kind> = [.releaseClaimed, .authorization]

    /// Records ids not seen before. Returns true when anything was new.
    @discardableResult
    mutating func note(_ events: [EstateEvent], at seenAt: Date) -> Bool {
        var changed = false
        for e in events where byEventID[e.id] == nil {
            byEventID[e.id] = seenAt
            changed = true
        }
        return changed
    }

    /// Seeds every event at its own effective time: for the events that
    /// were already on the phone before the table existed.
    mutating func seed(_ events: [EstateEvent]) {
        for e in events where byEventID[e.id] == nil {
            byEventID[e.id] = ReleaseFeed.effectiveTime(e)
        }
    }

    /// The time the feed should use for this event on this phone.
    func timeOf(_ event: EstateEvent) -> Date {
        let claimed = ReleaseFeed.effectiveTime(event)
        guard Self.clampedKinds.contains(event.kind), let seen = byEventID[event.id] else { return claimed }
        return max(claimed, seen)
    }

    /// Drops ids that are no longer in any log, so the table cannot grow
    /// without bound.
    mutating func keep(only ids: Set<String>) {
        byEventID = byEventID.filter { ids.contains($0.key) }
    }
}

enum FirstSeenStore {
    private static func key(_ ownerHash: String) -> String { "seal.firstseen.\(ownerHash)" }

    /// Nil when the table has never been saved on this phone, so the
    /// caller can seed it once from what is already there.
    static func load(ownerHash: String) -> FirstSeen? {
        guard let data = KeychainStore.load(key(ownerHash)) else { return nil }
        return try? JSONDecoder().decode(FirstSeen.self, from: data)
    }

    static func save(_ table: FirstSeen, ownerHash: String) {
        if let data = try? JSONEncoder().encode(table) {
            KeychainStore.save(data, for: key(ownerHash))
        }
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete(key(ownerHash))
    }
}
