// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CloudKit
import os

//  OwnedSets.swift
//  Seal
//
//  CHECK-INS FOLLOW THE OWNER TO A NEW PHONE (1.3).
//
//  The danger. `EstateEngine.heartbeat` writes "I am here" only into the
//  envelope sets this phone holds. Sign out, or move to a new iPhone, and the
//  sets sealed before are still in iCloud with their key holders, but no
//  check-in reaches them. To everyone else that owner has gone quiet, so a
//  "When I go quiet" set could open while they are alive and well. Elders
//  replace phones often, usually with somebody else doing the setup.
//
//  The fix, and its limit. This phone keeps checking in on every set this
//  owner sealed, wherever it was sealed. It does NOT bring the contents
//  back: those were locked to the old phone's keys and stay sealed exactly as
//  they were, and they still open for the people they were written for under
//  their rule. Only the "I am here" line moves.
//
//  Finding the sets.
//    1. A short list of set ids in the owner's PRIVATE iCloud database,
//       record "owned.<hash>", written on every foreground. Private: only
//       this Apple ID can read or write it. It reuses the GroupInvite record
//       type (recipient, payload), so no schema change and no Production
//       deploy is needed.
//    2. For sets sealed before this existed: the invites addressed to the
//       people under People (record names "estinv.<person>.<set id>").
//       Once a launch.
//  A set counts as the owner's only if its log has an epochPublished or
//  estateCreated line by this owner. Released sets and sets with a
//  departure line are left alone.
//
//  The check-in is the ordinary owner heartbeat: signed by this phone's
//  device key, which the owner's key endorsed at sign-in, chained to the
//  set's newest line. Key holders' phones and the web page verify it the
//  way they verify every heartbeat. Foreground only, like the main one.

enum OwnedSets {
    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "estate.owned")
    private static var privateDB: CKDatabase {
        CKContainer(identifier: SyncEngine.containerID).privateCloudDatabase
    }
    private static func recordName(_ ownerHash: String) -> String { "owned.\(ownerHash)" }

    /// Discovery through invites runs once per launch.
    private static var discovered = false

    /// Adds these set ids to the owner's private list. Writes only when the
    /// list grows.
    static func remember(_ estateIDs: [String], ownerHash: String) async {
        guard !estateIDs.isEmpty, !DemoFixtures.isActive else { return }
        let id = CKRecord.ID(recordName: recordName(ownerHash))
        let record = (try? await privateDB.record(for: id)) ?? CKRecord(recordType: "GroupInvite", recordID: id)
        let known = (record["payload"] as? Data)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let merged = Set(known).union(estateIDs)
        guard merged.count > Set(known).count else { return }
        do {
            record["recipient"] = recordName(ownerHash)
            record["payload"] = try JSONEncoder().encode(merged.sorted())
            try await privateDB.save(record)
        } catch {
            log.error("owned: could not save the list: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func known(ownerHash: String) async -> [String] {
        let id = CKRecord.ID(recordName: recordName(ownerHash))
        guard let record = try? await privateDB.record(for: id),
              let data = record["payload"] as? Data,
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    /// Set ids from the invites addressed to these people. Unchecked: the
    /// caller keeps only the ones whose log says this owner made them.
    private static func viaInvites(people: [String], sync: SyncEngine) async -> Set<String> {
        var ids = Set<String>()
        for person in people {
            let prefix = "estinv.\(person)."
            let query = CKQuery(recordType: "GroupInvite", predicate: NSPredicate(format: "recipient == %@", person))
            guard let (results, _) = try? await sync.publicDB.records(matching: query) else { continue }
            for (recordID, _) in results where recordID.recordName.hasPrefix(prefix) {
                let setID = String(recordID.recordName.dropFirst(prefix.count))
                if !setID.isEmpty { ids.insert(setID) }
            }
        }
        return ids
    }

    /// Writes "I am here" into every set this owner sealed that this phone
    /// does not hold. Call from the foreground refresh only.
    static func checkIn(identity: IdentityManager, ownerHash: String, held: Set<String>,
                        people: [String], sync: SyncEngine) async {
        guard !DemoFixtures.isActive, let deviceKey = identity.deviceKey else { return }
        var candidates = Set(await known(ownerHash: ownerHash))
        if !discovered {
            discovered = true
            candidates.formUnion(await viaInvites(people: people, sync: sync))
        }
        candidates.subtract(held)
        guard !candidates.isEmpty else { return }

        var mine: [String] = []
        for setID in candidates.sorted() {
            guard let events = try? await sync.fetchEstateEvents(estateID: setID), !events.isEmpty else { continue }
            let made = events.contains {
                $0.actorHash == ownerHash && ($0.kind == .epochPublished || $0.kind == .estateCreated)
            }
            guard made else { continue }
            mine.append(setID)
            if events.contains(where: { $0.kind == .released || $0.kind == .ownerDeparted }) { continue }
            do {
                let line = try EstateEventBuilder.make(kind: .heartbeat, estateID: setID, actorHash: ownerHash,
                                                       deviceKey: deviceKey,
                                                       previousDigest: EstateLogStore.headDigest(events),
                                                       payload: Data(), now: Clocks.current.now)
                try await sync.publishEstateEvent(line)
                log.info("owned: checked in on \(setID, privacy: .public), sealed on another phone")
            } catch {
                log.error("owned: check-in on \(setID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await remember(mine, ownerHash: ownerHash)
    }
}
