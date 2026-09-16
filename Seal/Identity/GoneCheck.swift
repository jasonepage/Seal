// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CloudKit

//  GoneCheck.swift
//  Seal
//
//  PEOPLE WHO DELETED THEIR SEAL ACCOUNT.
//
//  When someone deletes their identity on their own phone,
//  SyncEngine.deleteIdentity writes a write-once "tomb.<hash>" record and,
//  when it is allowed to, flips their live Identity record to the deleted
//  tier. Nothing tells the people who met them. Their People list kept the
//  row with a verified badge, their envelopes kept an address nobody can
//  open, and a key holder who no longer exists still counted as one.
//
//  So this phone asks. On pull to refresh in People, and once a day on
//  its own, it looks up every person it knows (friends, and every key
//  holder and recipient in both envelope sets) and marks the ones that
//  are gone. The mark is local, dated, and never removed: a tombstone is
//  forever. Nothing is removed automatically either; the owner decides.
//
//  Nothing here touches the release machine, the feed or the log.

extension SyncEngine {

    enum AccountState: Equatable {
        case alive
        case gone
    }

    /// Fast path first: the live record's tier flag, one direct fetch.
    /// Then the tombstone marker, which is the authority (the flag is
    /// best effort and missing when another iCloud account created the
    /// record). Throws when the directory cannot be read, so a network
    /// blip never marks anybody gone and never clears anything.
    func accountState(credentialIDHash hash: String) async throws -> AccountState {
        do {
            let record = try await publicDB.record(for: CKRecord.ID(recordName: hash))
            if record["tier"] as? String == Self.deletedTier { return .gone }
        } catch let error as CKError where error.code == .unknownItem {
            // No live record. Only the marker can say why.
        }
        return try await isTombstoned(credentialIDHash: hash) ? .gone : .alive
    }
}

extension FriendStore {

    static let goneCheckInterval: TimeInterval = 86_400

    /// Whether the daily check is due.
    func goneCheckDue(now: Date) -> Bool {
        guard let last = lastGoneCheck else { return true }
        return now.timeIntervalSince(last) > Self.goneCheckInterval || now < last
    }

    /// Look everybody up and mark the gone. `force` is the pull to
    /// refresh; without it this runs at most once a day. `alsoCheck` is
    /// the key holders and recipients of both envelope sets, so a person
    /// with no friendship on this phone is still found.
    /// Returns how many people were newly marked.
    @discardableResult
    func refreshGone(sync: SyncEngine, alsoCheck: [String] = [], force: Bool,
                     now: Date = Clocks.current.now) async -> Int {
        guard !DemoFixtures.isActive else { return 0 }
        guard force || goneCheckDue(now: now) else { return 0 }
        var hashes: [String] = []
        for h in friends.map(\.id) + alsoCheck where h != ownerHash && !hashes.contains(h) {
            hashes.append(h)
        }
        var marked = 0
        var reachedAll = true
        for hash in hashes where goneDate(hash) == nil {
            do {
                if try await sync.accountState(credentialIDHash: hash) == .gone {
                    markGone(hash, at: now)
                    marked += 1
                }
            } catch {
                reachedAll = false
            }
        }
        // Only a complete pass resets the daily clock, so an offline
        // launch tries again next time instead of waiting a day.
        if reachedAll { noteGoneCheck(at: now) }
        return marked
    }

    /// The same, for every person in the given engines. Both envelope
    /// sets (EstateEngine.Slot) are passed by the callers.
    @discardableResult
    func refreshGone(sync: SyncEngine, engines: [EstateEngine], force: Bool) async -> Int {
        let extra = engines.flatMap { engine -> [String] in
            guard let e = engine.estate else { return [] }
            return e.custodians.map(\.rootHash) + e.recipients.map(\.rootHash)
        }
        return await refreshGone(sync: sync, alsoCheck: extra, force: force)
    }
}

// MARK: - What a gone person means for an estate. Pure.

extension Envelope {
    /// Addressed to somebody who deleted their Seal account. It can never
    /// be wrapped to them again, and a seal that tries will fail.
    func isUndeliverable(gone: [String: Date]) -> Bool {
        isAddressed && gone[recipientHash] != nil
    }
}

extension Estate {
    func undeliverableEnvelopes(gone: [String: Date]) -> [Envelope] {
        envelopes.filter { $0.isUndeliverable(gone: gone) }
    }

    func goneCustodians(gone: [String: Date]) -> [Custodian] {
        custodians.filter { gone[$0.rootHash] != nil }
    }
}

extension CustodyConfirmation {
    /// What the owner's screen says under a key holder who is gone. Counted
    /// as unresponsive, exactly like a key holder who stopped confirming.
    static func goneStanding(name: String, deletedFoundAt: Date) -> Standing {
        let day = deletedFoundAt.formatted(date: .abbreviated, time: .omitted)
        return Standing(line: "\(name) deleted their Seal account (found \(day)). Their key can no longer help open your envelopes. Choose another key holder, then seal again.",
                        overdue: true)
    }

    /// Key holders who cannot be counted on: gone, or overdue on their
    /// yearly confirmation. The rule's threshold is NOT changed here.
    static func unresponsive(custodians: [Custodian], gone: [String: Date],
                             standing: (Custodian) -> Standing?) -> [Custodian] {
        custodians.filter { gone[$0.rootHash] != nil || standing($0)?.overdue == true }
    }
}

extension EstateEngine {
    /// `custodyStanding(for:)`, with a gone key holder said plainly.
    func custodyStanding(for custodian: Custodian, gone: [String: Date]) -> CustodyConfirmation.Standing? {
        if let at = gone[custodian.rootHash] {
            return CustodyConfirmation.goneStanding(name: custodian.displayName, deletedFoundAt: at)
        }
        return custodyStanding(for: custodian)
    }

    func unresponsiveKeyHolders(gone: [String: Date]) -> [Custodian] {
        CustodyConfirmation.unresponsive(custodians: estate?.custodians ?? [], gone: gone,
                                         standing: { custodyStanding(for: $0) })
    }

    /// Give an envelope to somebody else. The same move as addressing a
    /// draft: the words stay, it becomes unsealed, the next seal wraps it
    /// to the new person.
    func reassignEnvelope(_ envelopeID: String, to friend: RootIdentity) {
        bindEnvelope(envelopeID, to: friend)
    }
}
