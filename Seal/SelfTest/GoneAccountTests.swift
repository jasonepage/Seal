// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  GoneAccountTests.swift
//  Seal
//
//  A person who deleted their Seal account (GoneCheck.swift): old
//  friendships still load and are not gone, the mark survives a reload,
//  an envelope to a gone person says it cannot be delivered, and a gone
//  key holder is counted with the unresponsive ones.

enum GoneAccountTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "gone.oldFriendDecodesAndIsNotGone") { try oldFriendDecodesAndIsNotGone($0) },
        .init(name: "gone.markSurvivesReload") { try markSurvivesReload($0) },
        .init(name: "gone.recipientMakesEnvelopeUndeliverable") { try recipientMakesEnvelopeUndeliverable($0) },
        .init(name: "gone.keyHolderIsCounted") { try keyHolderIsCounted($0) },
    ] }

    /// A keychain entry written before `tombstonedAt` existed. Data is
    /// base64 and Date is seconds since 2001, the JSONEncoder defaults.
    static let oldJSON = """
    [{"identity":{"credentialIDHash":"karen","publicKey":"AQID","tier":"passkey","displayName":"Karen"},
      "friendship":{"friendRootID":"karen","attestation":"AQID","forgedAt":800000000,"autoReciprocated":true}}]
    """

    static func oldFriendDecodesAndIsNotGone(_ t: SelfTest.Context) throws {
        let friends = try JSONDecoder().decode([FriendStore.StoredFriend].self, from: Data(oldJSON.utf8))
        t.equal(friends.count, 1, "the old entry loads")
        t.check(friends.first?.friendship.tombstonedAt == nil, "an old friend has no gone date")
        t.check(friends.first?.friendship.isGone == false, "an old friend is not gone")
        t.equal(friends.first?.friendship.autoReciprocated, true, "older optional fields still read")
        // And the round trip keeps working with the new field present.
        var f = try JSONDecoder().decode(Friendship.self, from: Data(#"{"friendRootID":"k","attestation":"AQID","forgedAt":1}"#.utf8))
        f.tombstonedAt = Date(timeIntervalSinceReferenceDate: 5)
        let back = try JSONDecoder().decode(Friendship.self, from: try JSONEncoder().encode(f))
        t.equal(back.tombstonedAt, Date(timeIntervalSinceReferenceDate: 5), "the gone date round trips")
    }

    static func markSurvivesReload(_ t: SelfTest.Context) throws {
        // A namespaced test owner, seeded straight into the keychain so no
        // key pin is written, and wiped at the end.
        let owner = "selftest.gone.\(UUID().uuidString)"
        defer { FriendStore.wipe(ownerHash: owner) }
        KeychainStore.save(Data(oldJSON.utf8), for: "seal.friends.\(owner)")

        let found = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let store = FriendStore(ownerHash: owner)
        t.equal(store.friends.count, 1, "seeded friend loads")
        t.check(store.goneDate("karen") == nil, "not gone before the mark")
        store.markGone("karen", at: found)
        store.markGone("stranger", at: found)       // a key holder with no friendship
        store.markGone("karen", at: found.addingTimeInterval(99))   // the first date is kept
        store.noteGoneCheck(at: found)

        let reloaded = FriendStore(ownerHash: owner)
        t.equal(reloaded.friends.first?.friendship.tombstonedAt, found, "the friend's mark survives a reload")
        t.equal(reloaded.goneDate("stranger"), found, "a non-friend's mark survives a reload")
        t.equal(reloaded.lastGoneCheck, found, "the last check date survives a reload")
        t.check(!reloaded.goneCheckDue(now: found.addingTimeInterval(3_600)), "not due again within the day")
        t.check(reloaded.goneCheckDue(now: found.addingTimeInterval(90_000)), "due again after a day")

        reloaded.remove("karen")
        t.check(reloaded.friends.isEmpty, "Remove from People removes the friendship")
        t.equal(FriendStore(ownerHash: owner).goneDate("karen"), found, "the mark outlives the friendship")
    }

    static func recipientMakesEnvelopeUndeliverable(_ t: SelfTest.Context) throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let toKaren = Envelope.new(recipientHash: "karen", title: "For Karen", now: t0, revealOrder: 1)
        let toEmma = Envelope.new(recipientHash: "emma", title: "For Emma", now: t0, revealOrder: 1)
        let gone = ["karen": t0]
        t.check(toKaren.isUndeliverable(gone: gone), "an envelope to a gone person is undeliverable")
        t.check(!toEmma.isUndeliverable(gone: gone), "an envelope to a live person is fine")
        t.check(!toKaren.isUndeliverable(gone: [:]), "nothing is undeliverable when nobody is gone")
        let draft = Envelope.unbound(name: "Karen", title: "For Karen", now: t0)
        t.check(!draft.isUndeliverable(gone: [draft.recipientHash: t0]), "a draft to a typed name is never undeliverable")

        var estate = Estate.new(ownerHash: "me", now: t0)
        estate.envelopes = [toKaren, toEmma]
        t.equal(estate.undeliverableEnvelopes(gone: gone).map(\.id), [toKaren.id], "the estate finds exactly that envelope")
    }

    static func keyHolderIsCounted(_ t: SelfTest.Context) throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let karen = Custodian(rootHash: "karen", displayName: "Karen", addedAt: t0, handoverReceiptID: nil)
        let bob = Custodian(rootHash: "bob", displayName: "Bob", addedAt: t0, handoverReceiptID: nil)
        let fresh: (Custodian) -> CustodyConfirmation.Standing? = {
            CustodyConfirmation.standing(name: $0.displayName, lastConfirmed: nil, handedOverAt: t0,
                                         months: 12, now: t0.addingTimeInterval(86_400))
        }
        t.equal(CustodyConfirmation.unresponsive(custodians: [karen, bob], gone: [:], standing: fresh).count, 0,
                "two fresh key holders: nobody unresponsive")
        let counted = CustodyConfirmation.unresponsive(custodians: [karen, bob], gone: ["karen": t0], standing: fresh)
        t.equal(counted.map(\.rootHash), ["karen"], "the gone key holder is counted")
        t.check(CustodyConfirmation.goneStanding(name: "Karen", deletedFoundAt: t0).overdue,
                "the gone line is shown the way an overdue one is")
        let noStanding = CustodyConfirmation.unresponsive(custodians: [karen], gone: ["karen": t0], standing: { _ in nil })
        t.equal(noStanding.count, 1, "counted even before the estate is sealed")
        var estate = Estate.new(ownerHash: "me", now: t0)
        estate.custodians = [karen, bob]
        t.equal(estate.goneCustodians(gone: ["karen": t0]).map(\.rootHash), ["karen"], "the estate lists the gone key holder")
        t.equal(estate.policy.threshold, Estate.new(ownerHash: "me", now: t0).policy.threshold, "the rule is untouched")
    }
}
