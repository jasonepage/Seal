import Foundation

//  RecordStub.swift
//  Seal
//
//  A RECORD LINE THAT OUTLIVES THE THING IT DESCRIBES (docs/RECORD.md §11).
//
//  RecordEvent.swift is a projection and adds no store, on purpose: two stores
//  that can disagree are worse than one. This file is the single, deliberate
//  exception, and the reason it is defensible is narrow.
//
//  Disappearing messages are enforced by `ChatEngine.purgeExpired()`, which
//  drops expired messages from the store outright. So a sealed card sent in a
//  chat with a TTL used to take its record line with it, and the record quietly
//  forgot that anything had ever been sent. That is the exact moment somebody
//  would reach for the record.
//
//  A stub is not a second copy of live data that can drift out of step with the
//  original, because THE ORIGINAL IS GONE BY DESIGN. It is a tombstone. While
//  the message still exists the projection wins and the stub is ignored; once
//  the message burns the stub is all that is left.
//
//  WHAT IT KEEPS, AND WHAT IT MUST NEVER KEEP
//  ------------------------------------------
//  Kept: the kind of event, the moment, who it was with, the card's TITLE, and
//  the card's digest.
//
//  NEVER the card's `value`. The value burning is the entire point of the TTL,
//  and a stub that carried it would quietly turn disappearing messages into a
//  lie. If anyone is ever tempted to add it here for a nicer detail sheet: no.
//
//  The title surviving is a real disclosure and a deliberate one. A record line
//  reading "a card was sent" with no label is close to useless, the stub lives
//  only in this phone's keychain, and nobody but its owner ever sees it. The
//  TTL copy in CardComposeSheet says so before the card is sealed, so it is a
//  choice the sender makes rather than a surprise they discover.
//
//  The digest is computed from the same fields either way, so an event's id is
//  IDENTICAL before and after the burn. The line does not become a different
//  line when the content goes.

struct RecordStub: Codable, Hashable {
    /// `RecordEvent.Kind.rawValue`. Stored as a string so an unknown future
    /// kind decodes rather than throwing and taking every stub with it.
    let kindRaw: String
    /// Whole seconds, for the reason CustodyReceipt gives: an integer
    /// round-trips exactly, and it keeps the digest identical to the one the
    /// live projection computes.
    let occurredAtEpoch: Int64
    let counterpartHash: String?
    let counterpartName: String?
    let title: String
    let contentDigestHex: String?
    let sourceRef: String

    var occurredAt: Date { Date(timeIntervalSince1970: TimeInterval(occurredAtEpoch)) }
    var kind: RecordEvent.Kind? { RecordEvent.Kind(rawValue: kindRaw) }
}

/// Static, keychain-backed, and namespaced per identity like every other local
/// store. Wiped by sign-out and by delete (ContentView.wipeLocalAndEngines).
enum RecordStubStore {

    private static func storageKey(_ ownerHash: String) -> String {
        "seal.recordstubs.\(ownerHash)"
    }

    static func load(ownerHash: String) -> [RecordStub] {
        guard let data = KeychainStore.load(storageKey(ownerHash)),
              let decoded = try? JSONDecoder().decode([RecordStub].self, from: data)
        else { return [] }
        return decoded
    }

    /// Adds stubs that are not already stored. Keyed by `sourceRef`, so calling
    /// this twice for the same card is harmless, which matters because
    /// `purgeExpired` runs on every sync pass.
    ///
    /// A decode failure is treated as an empty store rather than as a reason to
    /// refuse: unlike receipts, a stub can be regenerated for any message still
    /// alive, so writing is the recoverable direction here.
    static func upsert(_ new: [RecordStub], ownerHash: String) {
        guard !new.isEmpty else { return }
        var all = load(ownerHash: ownerHash)
        let known = Set(all.map(\.sourceRef))
        let additions = new.filter { !known.contains($0.sourceRef) }
        guard !additions.isEmpty else { return }
        all.append(contentsOf: additions)
        if let data = try? JSONEncoder().encode(all) {
            KeychainStore.save(data, for: storageKey(ownerHash))
        }
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete(storageKey(ownerHash))
    }
}
