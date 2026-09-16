// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  RuleBookTests.swift
//  Seal
//
//  One rule is one box of keys (RELEASE.md section 13). What matters here
//  is that nothing on a phone moves: the default rule and the old Bills
//  and medical set keep the store keys they always had; the cap holds; a
//  rule with envelopes or shares out in the world cannot be deleted; and a
//  key holder's phone reads the default rule as the bare owner name.
//
//  Pure: the keychain is never touched. The one keychain reader
//  (RuleBook.load) is covered by `migrated`, its pure half.

enum RuleBookTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "rules.storeHashesUnchanged") { try storeHashesUnchanged($0) },
        .init(name: "rules.migration") { try migration($0) },
        .init(name: "rules.capAndIDs") { try capAndIDs($0) },
        .init(name: "rules.normalized") { try normalized($0) },
        .init(name: "rules.ownerLabel") { try ownerLabel($0) },
        .init(name: "rules.removeRefusal") { try removeRefusal($0) },
        .init(name: "rules.codable") { try codable($0) },
    ] }

    static let hash = "abc123"
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// The two ids that existed before rules must file exactly where the
    /// old code filed them, or a phone loses its estate on upgrade.
    static func storeHashesUnchanged(_ t: SelfTest.Context) throws {
        t.equal(RuleSlot.main.storeHash(ownerHash: hash), hash, "the default rule files under the identity hash")
        t.equal(RuleSlot(id: "urgent", name: "x").storeHash(ownerHash: hash), "urgent.\(hash)",
                "the old Bills and medical set files under urgent.<hash>, as before")
        t.equal(RuleSlot(id: "r2", name: "Sooner").storeHash(ownerHash: hash), "r2.\(hash)", "a new rule gets its own prefix")
        t.check(RuleBook.allStoreHashes(ownerHash: hash).contains(hash), "a wipe covers the default store")
        t.check(RuleBook.allStoreHashes(ownerHash: hash).contains("urgent.\(hash)"), "a wipe covers the legacy urgent store")
        t.check(RuleBook.allStoreHashes(ownerHash: hash).contains("r2.\(hash)"), "a wipe covers r2 whether or not the book lists it")
    }

    static func migration(_ t: SelfTest.Context) throws {
        let fresh = RuleBook.migrated(ownerHash: hash, urgentExists: false)
        t.equal(fresh.count, 1, "a phone with no Bills and medical set has one rule")
        t.check(fresh[0].isDefault, "and it is the default")
        t.equal(fresh[0].name, RuleSlot.defaultName, "named the default name")

        let upgraded = RuleBook.migrated(ownerHash: hash, urgentExists: true)
        t.equal(upgraded.count, 2, "a phone with a Bills and medical set has two rules")
        t.equal(upgraded[1].id, RuleSlot.legacyUrgentID, "the second is the urgent set")
        t.equal(upgraded[1].name, RuleSlot.legacyUrgentName, "under its old name")
        t.check(upgraded[1].startsShort, "a rule that is not the default starts short")
        t.check(!upgraded[0].startsShort, "the default does not")
    }

    static func capAndIDs(_ t: SelfTest.Context) throws {
        var rules = [RuleSlot.main]
        let second = RuleBook.nextID(after: rules)
        t.equal(second, "r2", "the second rule is r2")
        rules.append(RuleSlot(id: second ?? "", name: "Sooner"))
        let third = RuleBook.nextID(after: rules)
        t.equal(third, "r3", "the third rule is r3")
        rules.append(RuleSlot(id: third ?? "", name: "Later"))
        t.check(RuleBook.nextID(after: rules) == nil, "no fourth rule")
        // Remove r2 and the next id is r2 again, never r4.
        rules.removeAll { $0.id == "r2" }
        t.equal(RuleBook.nextID(after: rules), "r2", "a freed id is reused")
        // The legacy urgent id counts toward the cap like any other.
        let withUrgent = RuleBook.migrated(ownerHash: hash, urgentExists: true)
        t.equal(RuleBook.nextID(after: withUrgent), "r2", "urgent plus the default leaves room for one more")
    }

    static func normalized(_ t: SelfTest.Context) throws {
        let messy = [RuleSlot(id: "r2", name: "Sooner"), RuleSlot(id: "r2", name: "Dup"),
                     RuleSlot.main, RuleSlot(id: "r3", name: "Later"), RuleSlot(id: "r4", name: "Too many")]
        let clean = RuleBook.normalized(messy)
        t.check(clean.first?.isDefault == true, "the default comes first")
        t.equal(clean.map(\.id), ["", "r2", "r3"], "duplicates dropped, cap applied, order kept")
        t.equal(clean[1].name, "Sooner", "the first of two duplicates wins")
        let none = RuleBook.normalized([RuleSlot(id: "r2", name: "Sooner")])
        t.check(none.first?.isDefault == true, "a list without the default gets it back")
        t.check(RuleBook.normalized([]).count == 1, "an empty list becomes the default alone")
    }

    /// What a key holder's phone shows.
    static func ownerLabel(_ t: SelfTest.Context) throws {
        t.equal(RuleSlot.main.ownerLabel("Karen"), "Karen", "the default rule is the bare name")
        t.equal(RuleSlot(id: "r2", name: "Sooner").ownerLabel("Karen"), "Karen (Sooner)", "another rule is named in brackets")
        t.equal(RuleSlot(id: "r2", name: "  ").ownerLabel("Karen"), "Karen", "a blank name falls back to the bare name")
        t.equal(RuleSlot(id: "urgent", name: RuleSlot.legacyUrgentName).ownerLabel("Nathan"),
                "Nathan (Bills and medical)", "the migrated set reads like the old label")
    }

    static func removeRefusal(_ t: SelfTest.Context) throws {
        let second = RuleSlot(id: "r2", name: "Sooner")
        t.check(EstateEngines.removeRefusal(slot: .main, estate: nil) != nil, "the default rule never goes")
        t.check(EstateEngines.removeRefusal(slot: second, estate: nil) == nil, "a rule with no estate can go")
        var estate = Estate.new(ownerHash: hash, now: t0)
        t.check(EstateEngines.removeRefusal(slot: second, estate: estate) == nil, "an empty estate can go")
        estate.envelopes.append(Envelope.new(recipientHash: "R", title: "For Karen", now: t0, revealOrder: 0))
        t.check(EstateEngines.removeRefusal(slot: second, estate: estate) != nil, "a rule with an envelope stays")
        var sealed = Estate.new(ownerHash: hash, now: t0)
        sealed.epochPublished = true
        t.check(EstateEngines.removeRefusal(slot: second, estate: sealed) != nil, "a rule that was sealed stays")
        for r in [EstateEngines.RemoveRefusal.isDefault, .hasEnvelopes, .sealed] {
            t.check(!r.line.isEmpty && !r.line.contains("\u{2014}"), "every refusal has a plain line")
        }
    }

    static func codable(_ t: SelfTest.Context) throws {
        let rules = [RuleSlot.main, RuleSlot(id: "r2", name: "Sooner")]
        let data = try JSONEncoder().encode(rules)
        let back = try JSONDecoder().decode([RuleSlot].self, from: data)
        t.equal(back, rules, "the book round trips through JSON")
    }
}
